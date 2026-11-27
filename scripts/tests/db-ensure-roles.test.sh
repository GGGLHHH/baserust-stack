#!/usr/bin/env bash
# 总仓库 `just db-ensure-roles` 的测试:在一个临时目录里放 justfile + .env.compose + 建库脚本,docker 换成桩 ——
# `docker compose exec … pg …` 转给一个现成的 PG 容器(TEST_PG_CONTAINER,改连临时库 ensure_verify),
# 看 00 / 10 两个脚本跑完之后账号、属主、密码对不对。会建临时库 ensure_verify 和 sv_* 账号,结束时删掉。
#   TEST_PG_CONTAINER=mt-test-pg bash scripts/tests/db-ensure-roles.test.sh      (要 just、docker;Git Bash 也行)
#
# 覆盖:命令从总仓库根目录执行、打 compose 的 pg 服务、两个脚本都跑;账号名 / 密码取自 .env.compose
# (CRLF、引号、行内注释、首尾空白照 compose 的读法处理,值里 / 末尾的 '=' 保留),同名环境变量优先;容器自己的环境变量(老容器没有 / 是旧值)不起作用。
# 没配的账号名 / 密码 = baserust/docker-compose.yml 里写的缺省(逐个变量对照 compose 文件;owner / system 按 schema 名写死,
# 不跟 *_DB_USER 走);值里有 $(不带引号或双引号:compose 会插值)当场报错、一个 compose exec 都不跑,单引号里的 $ 原样放行。
# 后两项只看传给 docker 的 -e(桩在 DRY=1 时不连 PG),不在测试 PG 上建 app_owner 这类真名账号。
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK="$(cd "$HERE/../.." && pwd)"
PG="${TEST_PG_CONTAINER:?要一个 postgres 容器名(超级用户取容器的 POSTGRES_USER)}"
REAL_DOCKER="$(command -v docker)"
DB=ensure_verify
ROLES=(sv_app sv_app_owner sv_app_system sv_idm sv_content sv_content_owner sv_content_system
       sv_srch sv_srch_owner sv_srch_system sv_ops)

sql() { "$REAL_DOCKER" exec -i "$PG" sh -c 'psql -X -v ON_ERROR_STOP=1 -qAt -U "$POSTGRES_USER" -d "$1" -c "$2"' sh "$@"; }
cleanup() {
  sql postgres "drop database if exists $DB with (force)" >/dev/null 2>&1 || true
  for r in "${ROLES[@]}"; do sql postgres "drop role if exists $r" >/dev/null 2>&1 || true; done
  if [ -n "${WORK:-}" ]; then rm -rf "$WORK"; fi
}
trap cleanup EXIT
cleanup
WORK="$(mktemp -d)"
sql postgres "create database $DB"

# 临时「总仓库」:justfile 原样、建库脚本原样,.env.compose 是测试的
mkdir -p "$WORK/stack/baserust/scripts" "$WORK/bin"
cp "$STACK/justfile" "$WORK/stack/"
cp -R "$STACK/baserust/scripts/initdb" "$WORK/stack/baserust/scripts/"
printf '%s\r\n' \
  '# 注释行不读' \
  'APP_DB_USER=sv_app' \
  'IDM_DB_USER=sv_idm' \
  'CONTENT_DB_USER=sv_content' \
  'SEARCH_DB_USER=sv_srch' \
  'OPS_DB_USER=sv_ops' \
  'APP_DB_OWNER_USER=sv_app_owner' \
  'APP_DB_SYSTEM_USER=sv_app_system' \
  'CONTENT_DB_OWNER_USER=sv_content_owner' \
  'CONTENT_DB_SYSTEM_USER=sv_content_system' \
  'SEARCH_DB_OWNER_USER=sv_srch_owner' \
  'SEARCH_DB_SYSTEM_USER=sv_srch_system' \
  'SEARCH_DB_SYSTEM_PASSWORD="from-file"' \
  "APP_DB_OWNER_PASSWORD='from-\$file-too'" \
  'CONTENT_DB_OWNER_PASSWORD=overridden-by-env' \
  'APP_DB_SYSTEM_PASSWORD=ends-with-eq=' \
  'IDM_DB_PASSWORD=plain # 行内注释' \
  'OPS_DB_PASSWORD=a#b' \
  'CONTENT_DB_SYSTEM_PASSWORD="quoted # not comment" # 收尾引号之后是注释' \
  'SEARCH_DB_OWNER_PASSWORD=  spaced	' \
  'SEARCH_DB_PASSWORD="esc\"q\\b"' >"$WORK/stack/.env.compose"

# docker 桩:记下调用,compose exec 转给测试 PG 容器(改连临时库)
cat >"$WORK/bin/docker" <<STUB
#!/usr/bin/env bash
echo "docker \$*" >>"$WORK/calls"
[ "\$1 \$2" = "compose exec" ] || exit 1
# DRY=1:只记下传了哪些 -e,不连 PG(检查缺省值 / 报错的用例用)
if [ "\${DRY:-}" = 1 ]; then cat >/dev/null; exit 0; fi
shift 2
envs=()
while [ \$# -gt 0 ]; do
  case "\$1" in -T) shift ;; -e) envs+=(-e "\$2"); shift 2 ;; *) break ;; esac
done
[ "\$1" = pg ] || { echo "不是 pg 服务:\$1" >&2; exit 1; }
shift
exec "$REAL_DOCKER" exec -i "\${envs[@]}" -e POSTGRES_DB=$DB "$PG" "\$@"
STUB
chmod +x "$WORK/bin/docker"

fails=0
check() { if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1:期望 $2,实际 $3"; fails=$((fails + 1)); fi; }

# 在临时总仓库根目录跑 just db-ensure-roles;先清掉当前 shell 里同名的 *_DB_* 变量(测试只认 .env.compose 和这里显式给的)。
run_just() { # 参数 = 额外的环境变量 K=V
  ( cd "$WORK/stack"
    for v in $(compgen -v | grep -E '^(APP|IDM|CONTENT|SEARCH|OPS)_DB_'); do unset "$v"; done
    env PATH="$WORK/bin:$PATH" "$@" just db-ensure-roles ) >"$WORK/out" 2>&1
}

echo "▶ just db-ensure-roles(在总仓库根目录)"
run_just CONTENT_DB_OWNER_PASSWORD=from-env \
  || { cat "$WORK/out"; echo "FAIL just db-ensure-roles 失败"; exit 1; }
check "跑了两次 compose exec pg" 2 "$(grep -c '^docker compose exec -T .* pg bash -s$' "$WORK/calls")"
check "两个脚本都跑完了" yes "$(grep -q '账号拆分就绪' "$WORK/out" && grep -q 'roles/schemas 就绪' "$WORK/out" && echo yes || echo no)"
check "app schema 归 sv_app_owner" sv_app_owner "$(sql $DB "select pg_get_userbyid(nspowner) from pg_namespace where nspname = 'sv_app'")"
check "search schema 归 sv_srch_owner" sv_srch_owner "$(sql $DB "select pg_get_userbyid(nspowner) from pg_namespace where nspname = 'sv_srch'")"
check "idm schema 归 sv_idm" sv_idm "$(sql $DB "select pg_get_userbyid(nspowner) from pg_namespace where nspname = 'sv_idm'")"
check "ops schema 归 sv_ops" sv_ops "$(sql $DB "select pg_get_userbyid(nspowner) from pg_namespace where nspname = 'sv_ops'")"
check "system 账号 BYPASSRLS" t "$(sql postgres "select rolbypassrls from pg_roles where rolname = 'sv_srch_system'")"
pw_ok() { # $1=账号 $2=密码:用这个密码能连上?
  # 连容器自己的网卡地址,不连 127.0.0.1:postgres 镜像的 pg_hba 对 127.0.0.1 是 trust,什么密码都能连,验不出东西。
  if "$REAL_DOCKER" exec -e PGPASSWORD="$2" "$PG" sh -c \
    'psql -X -h "$(hostname -i | cut -d" " -f1)" -U "$1" -d "$2" -qAt -c "select 1"' sh "$1" "$DB" >/dev/null 2>&1
  then echo yes; else echo no; fi
}
check "密码校验是真的(错的密码连不上)" no "$(pw_ok sv_app not-the-password)"
check "密码取自 .env.compose(双引号、CRLF 去掉)" yes "$(pw_ok sv_srch_system from-file)"
check "密码取自 .env.compose(单引号,里面的 \$ 原样、不插值)" yes "$(pw_ok sv_app_owner 'from-$file-too')"
check "环境变量优先于 .env.compose" yes "$(pw_ok sv_content_owner from-env)"
check "没配的密码用默认 pwd" yes "$(pw_ok sv_app pwd)"
check "以 '=' 结尾的值原样保留" yes "$(pw_ok sv_app_system 'ends-with-eq=')"
check "不带引号的值:' #' 之后是行内注释" yes "$(pw_ok sv_idm plain)"
check "不带引号的值:前面没空白的 '#' 是值的一部分" yes "$(pw_ok sv_ops 'a#b')"
check "双引号里的 ' #' 不是注释,收尾引号之后是" yes "$(pw_ok sv_content_system 'quoted # not comment')"
check "不带引号的值去掉首尾空白" yes "$(pw_ok sv_srch_owner spaced)"
check "双引号里的 \\\" \\\\ 转义" yes "$(pw_ok sv_srch 'esc"q\b')"

# ── 下面只看传给 docker 的 -e(DRY=1,不连 PG)──
env_file() { printf '%s\n' '# 测试' "$@" >"$WORK/stack/.env.compose"; }
passed() { # 第一次 compose exec 传的 -e,一行一个 K=V(DRY 用例的值都不带空白)
  head -n1 "$WORK/calls" | grep -oE -- '-e [A-Z_]+=[^ ]*' | sed 's/^-e //'
}
passed_value() { passed | sed -n "s/^$1=//p"; }
compose_default() { # baserust/docker-compose.yml 里 K: ${K:-缺省} 的缺省值(各处写法必须一致,不一致就输出多行)
  sed -nE 's/^[[:space:]]+'"$1"': \$\{'"$1"':-([^}]*)\}.*/\1/p' "$STACK/baserust/docker-compose.yml" | sort -u
}

echo "▶ 没配的账号名 / 密码 = compose 的缺省"
env_file
: >"$WORK/calls"
run_just DRY=1 || { cat "$WORK/out"; echo "FAIL DRY 跑失败"; exit 1; }
n=0
while IFS='=' read -r k v; do
  n=$((n + 1))
  check "$k 缺省同 compose" "$(compose_default "$k")" "$v"
done < <(passed)
check "传了 22 个账号 / 密码变量(5 个运行时账号 + 3×2 个 owner / system,各带密码)" 22 "$n"

echo "▶ 改了运行时账号名,owner / system 的缺省也不跟着变(同 compose)"
env_file 'APP_DB_USER=sv_app' 'CONTENT_DB_USER=sv_content' 'SEARCH_DB_USER=sv_srch'
: >"$WORK/calls"
run_just DRY=1 || { cat "$WORK/out"; echo "FAIL DRY 跑失败"; exit 1; }
check "运行时账号取 .env.compose" sv_app "$(passed_value APP_DB_USER)"
for k in APP_DB_OWNER_USER APP_DB_SYSTEM_USER CONTENT_DB_OWNER_USER CONTENT_DB_SYSTEM_USER \
         SEARCH_DB_OWNER_USER SEARCH_DB_SYSTEM_USER; do
  check "$k 仍是 compose 的缺省" "$(compose_default "$k")" "$(passed_value "$k")"
done

echo "▶ 值里有 \$:不带引号 / 双引号报错(compose 会插值),单引号放行"
for line in 'APP_DB_PASSWORD=pa$word' 'APP_DB_PASSWORD=${HOME}' 'APP_DB_PASSWORD="pa$word"' \
            'APP_DB_PASSWORD="pa\$word"'; do
  env_file "$line"
  : >"$WORK/calls"
  if run_just DRY=1; then rc=0; else rc=$?; fi
  check "$line → 失败" yes "$([ "$rc" -ne 0 ] && echo yes || echo no)"
  check "$line → 提示用单引号或去掉 \$" yes "$(grep -q 'APP_DB_PASSWORD' "$WORK/out" && grep -q '单引号' "$WORK/out" && echo yes || echo no)"
  check "$line → 一个 compose exec 都没跑" 0 "$(grep -c 'compose exec' "$WORK/calls" || true)"
done
env_file "APP_DB_PASSWORD='pa\$word'"
: >"$WORK/calls"
run_just DRY=1 || { cat "$WORK/out"; echo "FAIL 单引号里的 \$ 应放行"; fails=$((fails + 1)); }
check "单引号里的 \$ 原样传给容器" 'pa$word' "$(passed_value APP_DB_PASSWORD)"
: >"$WORK/calls"
run_just DRY=1 'APP_DB_PASSWORD=x$y' || true
check "环境变量里的 \$ 不受限(不是从 .env.compose 解析的)" 'x$y' "$(passed_value APP_DB_PASSWORD)"

echo
if [ "$fails" -gt 0 ]; then cat "$WORK/out"; echo "❌ $fails 项不通过"; exit 1; fi
echo "✅ 全部通过"
