#!/usr/bin/env bash
# 一键部署。由 build.sh 打出的 <项目名>-deploy_<时间>.run 解包后自动调用,不用手动执行。
#
# 检查 → 载入镜像(部署包旁边 images/ 下有的才载入,没有的沿用本机已有的)→ 把配置装到 DEPLOY_DIR
# → 起数据库并补齐各 schema 的 role、拆分多租户账号 → up -d 并等全部健康检查通过
# → search 读模型为空时回填(rebuild_search,多租户升级后第一次部署)。首次部署和升级都是这一条。
# 数据(DEPLOY_DIR/data 下的 postgres / minio / nats)不会被动。
# compose 项目名取 .env 的 COMPOSE_PROJECT_NAME:同一台服务器上多个项目各用各的名字、端口和目录。
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
PKG_DIR="$(pwd -P)"
IMAGES_DIR="${DEPLOY_IMAGES_DIR:-$PKG_DIR/images}"

die() { echo "❌ $*" >&2; exit 1; }
step() { echo; echo "▶ $*"; }
# 取 .env 里的值:去掉回车(Windows 上手改过)和成对的引号,和 compose 读到的一致
env_of() { sed -n "s/^$1=//p" .env | tail -n 1 | tr -d '\r' | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/"; }

# ── 检查 ───────────────────────────────────────────────
[ "$(id -u)" -eq 0 ] || die "要用 root 执行(sudo bash <包名>.run):私钥和超管账号文件要改属主给容器用户 10001"
docker info >/dev/null 2>&1 || die "用不了 docker:docker 服务在跑吗?"
compose_ver="$(docker compose version --short 2>/dev/null)" || die "需要 docker compose v2(docker compose 插件)"
IFS=. read -r cv_major cv_minor _ <<< "${compose_ver#v}"
if [ "${cv_major:-0}" -lt 2 ] || { [ "${cv_major:-0}" -eq 2 ] && [ "${cv_minor:-0}" -lt 20 ]; }; then
  die "docker compose 版本 $compose_ver 太旧,至少要 2.20(--wait 等一次性迁移任务)"
fi
for f in docker-compose.prod.yml compose.web.yml nginx.conf .env keys/prod-ed25519.pem keys/prod-ed25519.pub.pem seed.prod.toml scripts/initdb VERSION; do
  [ -e "$f" ] || die "包不完整:缺 $f"
done
grep -Eq '^[A-Za-z_][A-Za-z0-9_]*=.*CHANGE-ME' .env && die ".env 里还有 CHANGE-ME 没改(重新执行 init.sh 生成)"
# 多租户新加的数据库账号(owner 跑迁移 / system 跑后台任务)。老的 .env.prod 没有这几行。
for k in APP_DB_OWNER_PASSWORD APP_DB_SYSTEM_PASSWORD CONTENT_DB_OWNER_PASSWORD CONTENT_DB_SYSTEM_PASSWORD \
         SEARCH_DB_OWNER_PASSWORD SEARCH_DB_SYSTEM_PASSWORD; do
  [ -n "$(env_of "$k")" ] || die ".env 缺 $k:本机执行 ./scripts/prod/init.sh --add-missing 补上(不动已有密码),重新打包部署"
done

NAME="$(env_of COMPOSE_PROJECT_NAME)"
[ -n "$NAME" ] || die ".env 里没有 COMPOSE_PROJECT_NAME"
DEPLOY_DIR="${DEPLOY_DIR:-$(env_of DEPLOY_DIR)}"
DEPLOY_DIR="${DEPLOY_DIR:-/opt/$NAME/prod}"
COMPOSE=(docker compose -p "$NAME" -f docker-compose.prod.yml -f compose.web.yml)

echo "═══ 部署 $NAME → $DEPLOY_DIR ═══"
sed 's/^/  /' VERSION

# ── 载入镜像 ───────────────────────────────────────────
step "载入镜像($IMAGES_DIR)"
shopt -s nullglob
image_files=("$IMAGES_DIR"/*.tar.gz)
shopt -u nullglob
[ "${#image_files[@]}" -eq 0 ] && echo "  没有镜像文件,沿用本机已有的镜像"
for f in ${image_files[@]+"${image_files[@]}"}; do
  echo "  $(basename "$f")"
  docker load -q -i "$f" >/dev/null
done

# ── 安装部署文件 ───────────────────────────────────────
step "安装部署文件到 $DEPLOY_DIR"
mkdir -p "$DEPLOY_DIR"
if [ "$PKG_DIR" != "$(cd "$DEPLOY_DIR" && pwd -P)" ]; then
  cp docker-compose.prod.yml compose.web.yml nginx.conf VERSION "$DEPLOY_DIR/"
  cp .env "$DEPLOY_DIR/.env"
  cp seed.prod.toml "$DEPLOY_DIR/seed.prod.toml"
  mkdir -p "$DEPLOY_DIR/keys" "$DEPLOY_DIR/scripts"
  cp keys/prod-ed25519.pem keys/prod-ed25519.pub.pem "$DEPLOY_DIR/keys/"
  # 不能删了目录重建:pg 容器挂载的是这个目录本身,删掉后容器里看到的是已删除的旧目录(空的)。
  # 只换里面的文件。
  mkdir -p "$DEPLOY_DIR/scripts/initdb"
  find "$DEPLOY_DIR/scripts/initdb" -mindepth 1 -delete
  cp -R scripts/initdb/. "$DEPLOY_DIR/scripts/initdb/"
fi
cd "$DEPLOY_DIR"
mkdir -p data/postgres data/minio data/nats
chmod 600 .env
# app / idm 容器以 uid 10001 运行:私钥和超管账号文件只给它读,公钥谁都能读。
chown 10001:10001 keys/prod-ed25519.pem seed.prod.toml
chmod 600 keys/prod-ed25519.pem seed.prod.toml
chmod 644 keys/prod-ed25519.pub.pem
chmod -R a+rX scripts/initdb   # pg 容器的 initdb 要读
# 要可执行:不可执行的 .sh 会被 initdb 入口 source 进它自己的 shell(set -eu 会带进去),可执行的才单独跑。
chmod a+x scripts/initdb/*.sh

# ── 数据库 role ────────────────────────────────────────
# initdb 只在空卷首次启动时跑;老卷上后来新加的 schema(如 ops)靠这一步补上。可重复执行,
# 已有的跳过,密码按 .env 重设(.env 是密码的唯一来源)。
step "起数据库并补齐各 schema 的 role"
"${COMPOSE[@]}" up -d --wait --wait-timeout 120 pg || { "${COMPOSE[@]}" logs --tail=50 pg; die "数据库起不来"; }
# 脚本从标准输入喂进去,不依赖 pg 容器里的挂载(升级时挂载可能还是旧内容)。
"${COMPOSE[@]}" exec -T pg bash -s < scripts/initdb/00-roles-schemas.sh 2>&1 | grep -Ev '^(NOTICE|ALTER ROLE|CREATE SCHEMA)' | sed 's/^/  /' \
  || die "补齐 role 失败"
# 多租户账号拆分(**必须在迁移之前**):app / content / search 各拆成 owner(迁移、拥有表)/ 运行时(只有 DML,
# 受 RLS 约束)/ system(BYPASSRLS)。老库里表归运行时账号,这里转给 owner;数据不动,可重复执行。
"${COMPOSE[@]}" exec -T pg bash -s < scripts/initdb/10-tenancy-roles.sh 2>&1 \
  | grep -Ev '^(NOTICE|ALTER |CREATE (SCHEMA|ROLE|TABLE)|GRANT|REVOKE)' | sed 's/^/  /' \
  || die "拆分数据库账号失败"

# ── 启动 ───────────────────────────────────────────────
step "启动全部服务(迁移是一次性任务,app / idm 等它完成),等健康检查"
# nginx.conf 是单文件挂载:内容变了 compose 看不出来,不会重建容器、新配置就不生效。
# 所以自己比对:和上次部署成功时相比变了,或 nginx 部署前就不健康,就强制重建 nginx。
STAMP=.deployed-nginx-conf.sha256
recreate=()
if [ "$(sha256sum nginx.conf | cut -d' ' -f1)" != "$(cat "$STAMP" 2>/dev/null)" ]; then
  recreate+=(nginx)
fi
nginx_id="$("${COMPOSE[@]}" ps -q nginx 2>/dev/null || true)"
if [ -n "$nginx_id" ] && [ "$(docker inspect -f '{{.State.Status}}' "$nginx_id" 2>/dev/null)" != running ]; then
  recreate+=(nginx)
fi

up_or_die() {
  if ! "${COMPOSE[@]}" up -d --remove-orphans --wait --wait-timeout 300 "$@"; then
    "${COMPOSE[@]}" ps -a
    "${COMPOSE[@]}" logs --tail=80 migrate app idm web nginx || true
    die "启动失败(上面是状态和日志)"
  fi
}
up_or_die
if [ "${#recreate[@]}" -gt 0 ]; then
  echo "  nginx 配置有变化(或之前没在跑),重建 nginx"
  up_or_die --force-recreate --no-deps nginx
fi

# ── search 读模型回填 ──────────────────────────────────
# 从多租户之前的版本升级时,search 迁移 0003 建出的账号目录 / 租户成员索引是空的,投影器只处理之后的新事件:
# 要用 rebuild_search 从 idm + profile 的当前状态全量回填一次(幂等;投影漂移时也可以手动跑)。
# 自动判断:有存活账号但账号目录为空,或有成员关系但成员索引为空 → 跑;DEPLOY_REBUILD_SEARCH=1 强制跑。
# 查询用 pg 容器里的超级用户(不受 RLS 约束)。同一镜像覆盖 entrypoint,环境变量同 app 进程,另补 search 库地址。
step "检查 search 读模型"
need_rebuild="$("${COMPOSE[@]}" exec -T pg sh -c 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "
  select exists (select 1 from idm.users where deleted_at is null)
     and (not exists (select 1 from search.account_index)
          or (exists (select 1 from idm.tenant_members) and not exists (select 1 from search.admin_user_index)))"' | tr -d '[:space:]')" \
  || die "查询 search 读模型状态失败"
if [ "$need_rebuild" = t ] || [ "${DEPLOY_REBUILD_SEARCH:-}" = 1 ]; then
  echo "  回填账号目录 / 成员索引(rebuild_search)"
  "${COMPOSE[@]}" run --rm --no-deps -T --entrypoint rebuild_search \
    -e SEARCH_DB_HOST=pg -e SEARCH_DB_PORT=5432 app 2>&1 | sed 's/^/  /' \
    || die "rebuild_search 失败(服务已启动,但后台成员列表 / 账号列表可能是空的)。排查后在 $DEPLOY_DIR 重跑:
  docker compose -p $NAME -f docker-compose.prod.yml -f compose.web.yml run --rm --no-deps -T --entrypoint rebuild_search -e SEARCH_DB_HOST=pg -e SEARCH_DB_PORT=5432 app"
else
  echo "  已就绪,跳过(要强制回填:DEPLOY_REBUILD_SEARCH=1)"
fi
sha256sum nginx.conf | cut -d' ' -f1 > "$STAMP"

# 新镜像顶替了 latest 标签,旧的变成悬空镜像。
docker image prune -f >/dev/null

PORT="$(env_of NGINX_PORT)"
echo
"${COMPOSE[@]}" ps
echo
echo "✅ 部署完成($(sed -n 's/^stack: //p' VERSION))"
echo "  健康检查:curl -s http://127.0.0.1:${PORT:-80}/health"
echo "  后台:http://<服务器>:${PORT:-80}/admin(HTTPS 和域名由前面的 1Panel / LB 负责,cookie 带 Secure,必须走 HTTPS 才能登录)"
echo "  目录:$DEPLOY_DIR(数据在 data/;compose 命令:cd $DEPLOY_DIR && docker compose -p $NAME -f docker-compose.prod.yml -f compose.web.yml ps)"
