#!/usr/bin/env bash
# scripts/prod/deploy.sh 的回归测试:search 读模型回填(rebuild_search)和「从多租户之前的版本升级」时先停 app / idm。
#
# docker 换成桩(记录调用;`compose exec pg …` 在本机执行、连真 PG;整栈 `up` 时执行一段 SQL 模拟迁移 + 投影器),
# 建库脚本(00 / 10)是真的,在真 PG 上跑。会建临时库 deploy_verify 和 dv_* 账号,结束时(含失败)删掉。
# 要 root(deploy.sh 要求)、bash、psql 和一个能建库建账号的 PG 超级用户,所以在 postgres 镜像里跑:
#   docker run --rm --network container:<pg 容器> -v "$PWD:/w" -w /w \
#     -e PGHOST=127.0.0.1 -e PGUSER=baserust -e PGPASSWORD=baserust postgres:17-alpine \
#     bash scripts/tests/deploy-rebuild-search.test.sh
# DEPLOY_SH=<路径> 换成别的版本的 deploy.sh(验证旧版确实不过)。
#
# 覆盖:
#   1. 从多租户之前的版本升级(idm.users 在、idm.tenant_members 不在):拆账号 / 迁移之前先停 app / idm;
#      服务起来后投影器已经往成员索引写了行(不再是空表)也照样回填。
#   2. 已经是多租户的库再部署:不停服务、不回填。
#   3. 全新库(还没有 idm.users):不停、不回填。
#   4. 回填失败 → 部署失败、标记留着;下次部署(库已经是新结构)照样回填,成功后清掉标记。
#   5. DEPLOY_REBUILD_SEARCH=1 强制回填。
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK="$(cd "$HERE/../.." && pwd)"
DEPLOY_SH="${DEPLOY_SH:-$STACK/scripts/prod/deploy.sh}"
INITDB="$STACK/baserust/scripts/initdb"
: "${PGUSER:?要 PG 超级用户(PGUSER / PGPASSWORD / PGHOST / PGPORT)}"
[ "$(id -u)" -eq 0 ] || { echo "要 root(deploy.sh 要求):在容器里跑"; exit 1; }

DB=deploy_verify
ROLES=(dv_app dv_app_owner dv_app_system dv_idm dv_content dv_content_owner dv_content_system
       dv_srch dv_srch_owner dv_srch_system dv_ops)
# 「pg 容器」里的环境变量:桩把 compose exec pg 的命令直接在本机跑,建库脚本和 deploy.sh 的查询读这些。
export POSTGRES_USER="$PGUSER" POSTGRES_DB="$DB" PGOPTIONS="-c client_min_messages=warning"
export APP_DB_USER=dv_app IDM_DB_USER=dv_idm CONTENT_DB_USER=dv_content SEARCH_DB_USER=dv_srch OPS_DB_USER=dv_ops
export APP_DB_PASSWORD=pwd IDM_DB_PASSWORD=pwd CONTENT_DB_PASSWORD=pwd SEARCH_DB_PASSWORD=pwd OPS_DB_PASSWORD=pwd
export APP_DB_OWNER_PASSWORD=pwd APP_DB_SYSTEM_PASSWORD=pwd CONTENT_DB_OWNER_PASSWORD=pwd
export CONTENT_DB_SYSTEM_PASSWORD=pwd SEARCH_DB_OWNER_PASSWORD=pwd SEARCH_DB_SYSTEM_PASSWORD=pwd

WORK="$(mktemp -d)"
psql_q() { psql -X -v ON_ERROR_STOP=1 -qAt "$@"; }
drop_all() {
  psql_q -d postgres -c "drop database if exists $DB with (force)" 2>/dev/null || true
  for r in "${ROLES[@]}"; do psql_q -d postgres -c "drop role if exists $r" 2>/dev/null || true; done
}
cleanup() { drop_all; rm -rf "$WORK"; }
trap cleanup EXIT
drop_all

# ── docker 桩 ──
mkdir -p "$WORK/bin"
cat >"$WORK/bin/docker" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  info) exit 0 ;;
  inspect) echo running; exit 0 ;;
  compose) shift ;;
  *) echo "docker $*" >>"$STUB_LOG"; exit 0 ;;
esac
[ "${1:-}" = version ] && { echo 2.29.0; exit 0; }
while [ $# -gt 0 ]; do case "$1" in -p | -f) shift 2 ;; *) break ;; esac; done
sub="$1"; shift
case "$sub" in
  exec)
    while [ "${1#-}" != "$1" ]; do shift; done   # -T
    shift                                          # 服务名 pg
    if [ "$*" = "bash -s" ]; then                  # 建库脚本从标准输入喂进来:记下是哪一个
      script="$(cat)"
      case "$script" in
        *10-tenancy-roles*) echo "exec 10-tenancy-roles" >>"$STUB_LOG" ;;
        *) echo "exec 00-roles-schemas" >>"$STUB_LOG" ;;
      esac
      printf '%s\n' "$script" | bash -s
    else
      echo "exec $1" >>"$STUB_LOG"
      "$@"
    fi
    ;;
  up)
    services=(); prev=
    for a in "$@"; do
      case "$a" in -*) ;; *) [ "$prev" = --wait-timeout ] || services+=("$a") ;; esac
      prev="$a"
    done
    if [ "${#services[@]}" -eq 0 ]; then
      echo "up (整栈)" >>"$STUB_LOG"
      # 整栈 up:迁移把库升到多租户结构,服务起来后投影器往成员索引写了一行
      psql -X -v ON_ERROR_STOP=1 -q -d "$POSTGRES_DB" -f "$STUB_ON_UP" >/dev/null
    else
      echo "up ${services[*]}" >>"$STUB_LOG"
    fi
    ;;
  run)
    echo "run $*" >>"$STUB_LOG"
    [ -z "${STUB_RUN_FAIL:-}" ]
    ;;
  stop) echo "stop $*" >>"$STUB_LOG" ;;
  *) ;;
esac
STUB
chmod +x "$WORK/bin/docker"
export PATH="$WORK/bin:$PATH" STUB_ON_UP="$WORK/on-up.sql"
cat >"$STUB_ON_UP" <<'SQL'
create table if not exists dv_idm.users (id uuid primary key, deleted_at timestamptz);
create table if not exists dv_idm.tenant_members (tenant_id uuid not null, user_id uuid not null);
insert into dv_idm.tenant_members values (gen_random_uuid(), gen_random_uuid());
-- 同 search 迁移 0003:旧的 admin_user_index 改名成 account_index,再建新的成员索引
do $$ begin
  if to_regclass('dv_srch.account_index') is null then
    if to_regclass('dv_srch.admin_user_index') is not null then
      alter table dv_srch.admin_user_index rename to account_index;
    else
      create table dv_srch.account_index (user_id uuid);
    end if;
  end if;
end $$;
create table if not exists dv_srch.admin_user_index (tenant_id uuid, user_id uuid);
insert into dv_srch.account_index values (gen_random_uuid());
insert into dv_srch.admin_user_index values (gen_random_uuid(), gen_random_uuid());
SQL

# ── 部署包(结构同 build.sh 打出来的;镜像不需要)──
PKG="$WORK/pkg"
mkdir -p "$PKG/keys" "$PKG/scripts"
cp "$DEPLOY_SH" "$PKG/deploy.sh"
cp -R "$INITDB" "$PKG/scripts/initdb"
touch "$PKG/docker-compose.prod.yml" "$PKG/compose.web.yml" "$PKG/nginx.conf" "$PKG/seed.prod.toml" \
  "$PKG/keys/prod-ed25519.pem" "$PKG/keys/prod-ed25519.pub.pem"
echo "stack: test" >"$PKG/VERSION"
{
  echo "COMPOSE_PROJECT_NAME=dvtest"
  echo "NGINX_PORT=18080"
  for k in APP_DB_OWNER_PASSWORD APP_DB_SYSTEM_PASSWORD CONTENT_DB_OWNER_PASSWORD CONTENT_DB_SYSTEM_PASSWORD \
           SEARCH_DB_OWNER_PASSWORD SEARCH_DB_SYSTEM_PASSWORD; do echo "$k=pwd"; done
} >"$PKG/.env"
export DEPLOY_DIR="$WORK/deploy"

fails=0
check() { # $1=说明 $2=期望 $3=实际
  if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1:期望 $2,实际 $3"; fails=$((fails + 1)); fi
}
deploy() { # 跑一次部署,退出码写到 rc;调用日志在 $STUB_LOG
  export STUB_LOG="$WORK/calls.$1"; : >"$STUB_LOG"
  last="$1"
  rc=0
  bash "$PKG/deploy.sh" >"$WORK/out.$1" 2>&1 || rc=$?
}
line_of() { grep -n -m1 -e "$1" "$STUB_LOG" | cut -d: -f1; }        # 第一次出现的行号(没有 = 空)
has() { if grep -q -e "$1" "$STUB_LOG"; then echo yes; else echo no; fi; }
before() { # $1 在 $2 之前出现
  local a b; a="$(line_of "$1")"; b="$(line_of "$2")"
  if [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; then echo yes; else echo no; fi
}
new_db() { psql_q -d postgres -c "drop database if exists $DB with (force)" -c "create database $DB"; }
old_version_db() { # 多租户之前的结构:只跑过 00,idm.users 有账号,还没有 tenant_members
  new_db
  bash "$INITDB/00-roles-schemas.sh" >/dev/null 2>&1
  psql_q -d "$DB" -c "set role dv_idm; create table dv_idm.users (id uuid primary key, deleted_at timestamptz);
    insert into dv_idm.users values (gen_random_uuid(), null);
    set role dv_srch; create table dv_srch.admin_user_index (user_id uuid);"
}
MARK="$DEPLOY_DIR/.pending-rebuild-search"

echo "▶ 1. 从多租户之前的版本升级"
old_version_db
deploy 1
check "部署成功" 0 "$rc"
check "拆账号之前先停 app / idm" yes "$(before 'stop app idm' 'exec 10-tenancy-roles')"
check "迁移(整栈 up)之前先停 app / idm" yes "$(before 'stop app idm' 'up (整栈)')"
check "投影器写过行也照样回填" yes "$(before 'up (整栈)' 'run .*rebuild_search')"
check "回填完清掉标记" no "$([ -e "$MARK" ] && echo yes || echo no)"

echo "▶ 2. 已经是多租户的库再部署"
deploy 2
check "部署成功" 0 "$rc"
check "不停 app / idm" no "$(has 'stop app idm')"
check "不回填" no "$(has 'rebuild_search')"

echo "▶ 3. 全新库"
new_db
deploy 3
check "部署成功" 0 "$rc"
check "不停 app / idm" no "$(has 'stop app idm')"
check "不回填" no "$(has 'rebuild_search')"

echo "▶ 4. 回填失败 → 下次部署补上"
old_version_db
STUB_RUN_FAIL=1 deploy 4a
check "回填失败 → 部署失败" 1 "$rc"
check "标记留着" yes "$([ -e "$MARK" ] && echo yes || echo no)"
deploy 4b
check "再部署成功" 0 "$rc"
check "库已是新结构:不再停 app / idm" no "$(has 'stop app idm')"
check "按标记补跑回填" yes "$(has 'run .*rebuild_search')"
check "回填完清掉标记" no "$([ -e "$MARK" ] && echo yes || echo no)"

echo "▶ 5. DEPLOY_REBUILD_SEARCH=1"
DEPLOY_REBUILD_SEARCH=1 deploy 5
check "部署成功" 0 "$rc"
check "强制回填" yes "$(has 'run .*rebuild_search')"

echo
if [ "$fails" -gt 0 ]; then
  echo "❌ $fails 项不通过(最后一次部署的输出:)"; cat "$WORK/out.$last"; exit 1
fi
echo "✅ 全部通过"
