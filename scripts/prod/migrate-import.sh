#!/usr/bin/env bash
# 新服务器:导入 migrate-export.sh 导出的数据。前提:新服务器已经用部署包部署好(项目名相同)。
#
#   bash migrate-import.sh                    项目目录取 /opt/*/prod 里唯一的那个
#   bash migrate-import.sh /opt/shop/prod     指定项目目录
#
# 依次:校验文件 → 停 app 等 → 整库替换 → 逐表核对行数 → 替换 MinIO 文件 → 启动并等健康检查。
# 任何一步不通过就停下,app 保持停止,不会带着不完整的数据启动。可以重复执行。
# 数据包按顺序找:脚本所在目录、/opt/<项目名>-migrate/。
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"
set -euo pipefail

die() { echo "❌ $*" >&2; exit 1; }
step() { echo; echo "▶ $*"; }

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIR="${1:-}"
if [ -z "$DIR" ]; then
  shopt -s nullglob
  found=(/opt/*/prod/compose.web.yml)
  shopt -u nullglob
  [ "${#found[@]}" -eq 1 ] || die "找到 ${#found[@]} 个项目目录,请把目录作为参数传进来(如 /opt/baserust/prod)"
  DIR="$(dirname "${found[0]}")"
fi
cd "$DIR" || die "进不去 $DIR"
[ -f .env ] && [ -f compose.web.yml ] || die "$DIR 不像项目目录:先用部署包部署好"
env_of() { sed -n "s/^$1=//p" .env | tail -n 1; }
NAME="$(env_of COMPOSE_PROJECT_NAME)"
PGU="$(env_of POSTGRES_USER)"; PGD="$(env_of POSTGRES_DB)"
COMPOSE=(docker compose -p "$NAME" -f docker-compose.prod.yml -f compose.web.yml)

DATA=
for cand in "$SELF_DIR/$NAME-data.tar" "/opt/$NAME-migrate/$NAME-data.tar"; do
  [ -f "$cand" ] && { DATA="$cand"; break; }
done
[ -n "$DATA" ] || die "找不到 $NAME-data.tar(放在本脚本旁边或 /opt/$NAME-migrate/,文件名不能改)"

step "校验 $DATA"
WORK="$(mktemp -d "$(dirname "$DATA")/.import.XXXX")"
trap 'rm -rf "$WORK"' EXIT
need_kb=$(( $(du -sk "$DATA" | cut -f1) * 3 ))
free_kb=$(df -Pk "$WORK" | awk 'NR == 2 { print $4 }')
[ "$free_kb" -gt "$need_kb" ] || die "空间不够:要约 $((need_kb / 1024)) MB,只有 $((free_kb / 1024)) MB"
tar -C "$WORK" -xf "$DATA"
for f in db.dump counts.txt minio.tar; do [ -s "$WORK/$f" ] || die "数据包不完整:缺 $f"; done
[ -f "$WORK/exported_at" ] && echo "  导出于 $(cat "$WORK/exported_at")"

step "停掉 app / idm / web / nginx"
"${COMPOSE[@]}" stop nginx web app idm
"${COMPOSE[@]}" up -d --wait pg

step "整库替换 $PGD"
# 先清空各业务 schema 再恢复(--clean 只删 dump 里有的对象,新服务器迁移出来的多余对象会留下)。
# role 不在 dump 里:新服务器部署时已按 .env 建好,同名即可。
"${COMPOSE[@]}" exec -T pg psql -U "$PGU" -d "$PGD" -At -v ON_ERROR_STOP=1 <<'SQL' >/dev/null
select format('drop schema %I cascade', nspname) from pg_namespace
where nspname not in ('pg_catalog', 'information_schema', 'public', 'pg_toast') and nspname not like 'pg_%' \gexec
SQL
"${COMPOSE[@]}" exec -T pg pg_restore -U "$PGU" -d "$PGD" --exit-on-error < "$WORK/db.dump" \
  || die "恢复失败,app 保持停止"

step "逐表核对行数"
"${COMPOSE[@]}" exec -T pg psql -U "$PGU" -d "$PGD" -At -v ON_ERROR_STOP=1 > "$WORK/counts.new" <<'SQL'
select format('select %L, count(*) from %I.%I', table_schema || '.' || table_name, table_schema, table_name)
from information_schema.tables
where table_type = 'BASE TABLE' and table_schema not in ('pg_catalog', 'information_schema')
order by 1 \gexec
SQL
if ! diff <(sort "$WORK/counts.txt") <(sort "$WORK/counts.new") >/dev/null; then
  diff <(sort "$WORK/counts.txt") <(sort "$WORK/counts.new") || true
  die "行数对不上(左边导出,右边导入),app 保持停止"
fi
echo "  $(wc -l < "$WORK/counts.new") 张表全部一致"

step "替换 MinIO 文件"
"${COMPOSE[@]}" stop minio
rm -rf data/minio.old
[ -d data/minio ] && mv data/minio data/minio.old
tar -C data -xf "$WORK/minio.tar"
rm -rf data/minio.old

step "启动,等健康检查"
if ! "${COMPOSE[@]}" up -d --wait --wait-timeout 300; then
  "${COMPOSE[@]}" ps -a
  "${COMPOSE[@]}" logs --tail=80 app idm || true
  die "启动失败(上面是状态和日志)"
fi

echo
echo "✅ 导入完成"
echo "  验证:ssh -L <本机端口>:127.0.0.1:<NGINX_PORT> <服务器>,浏览器打开后台用旧账号登录"
echo "  JWT 密钥和旧服务器不同的话,所有人需要重新登录一次"
