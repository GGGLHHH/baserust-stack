#!/usr/bin/env bash
# 旧服务器:导出全部数据,准备搬到新服务器。
#
#   bash migrate-export.sh                    项目目录取 /opt/*/prod 里唯一的那个
#   bash migrate-export.sh /opt/shop/prod     指定项目目录
#
# ⚠️ 会停掉 app / idm / web / nginx 并保持停止(网站从这时起不可用),保证导出的是一致的数据。
#    搬迁失败要回滚:进项目目录执行 docker compose -p <项目名> -f docker-compose.prod.yml -f compose.web.yml up -d
# 产出:/opt/<项目名>-migrate/<项目名>-data.tar(数据库整库 + 各表行数 + MinIO 文件)。
# 不导出 NATS:里面只有已经落库的事件的副本,发件箱表才是源头。
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"
set -euo pipefail

die() { echo "❌ $*" >&2; exit 1; }
step() { echo; echo "▶ $*"; }

DIR="${1:-}"
if [ -z "$DIR" ]; then
  shopt -s nullglob
  found=(/opt/*/prod/compose.web.yml)
  shopt -u nullglob
  [ "${#found[@]}" -eq 1 ] || die "找到 ${#found[@]} 个项目目录,请把目录作为参数传进来(如 /opt/baserust/prod)"
  DIR="$(dirname "${found[0]}")"
fi
cd "$DIR" || die "进不去 $DIR"
[ -f .env ] && [ -f compose.web.yml ] || die "$DIR 不像项目目录(缺 .env / compose.web.yml)"
env_of() { sed -n "s/^$1=//p" .env | tail -n 1 | tr -d '\r' | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/"; }
NAME="$(env_of COMPOSE_PROJECT_NAME)"
[ -n "$NAME" ] || die "$DIR/.env 里没有 COMPOSE_PROJECT_NAME"
PGU="$(env_of POSTGRES_USER)"; PGD="$(env_of POSTGRES_DB)"
COMPOSE=(docker compose -p "$NAME" -f docker-compose.prod.yml -f compose.web.yml)
OUT_DIR="/opt/$NAME-migrate"
OUT="$OUT_DIR/$NAME-data.tar"

need_kb=$(( $(du -sk data/postgres data/minio | awk '{ s += $1 } END { print s }') * 2 ))
mkdir -p "$OUT_DIR"
free_kb=$(df -Pk "$OUT_DIR" | awk 'NR == 2 { print $4 }')
[ "$free_kb" -gt "$need_kb" ] || die "$OUT_DIR 所在分区空间不够:要约 $((need_kb / 1024)) MB,只有 $((free_kb / 1024)) MB"

step "停掉 app / idm / web / nginx(保持停止)"
"${COMPOSE[@]}" stop nginx web app idm

WORK="$(mktemp -d "$OUT_DIR/.export.XXXX")"
trap 'rm -rf "$WORK"' EXIT

step "导出数据库 $PGD"
"${COMPOSE[@]}" up -d --wait pg
"${COMPOSE[@]}" exec -T pg pg_dump -U "$PGU" -d "$PGD" -Fc > "$WORK/db.dump"
# 各表精确行数:导入后逐表核对。
"${COMPOSE[@]}" exec -T pg psql -U "$PGU" -d "$PGD" -At -v ON_ERROR_STOP=1 > "$WORK/counts.txt" <<'SQL'
select format('select %L, count(*) from %I.%I', table_schema || '.' || table_name, table_schema, table_name)
from information_schema.tables
where table_type = 'BASE TABLE' and table_schema not in ('pg_catalog', 'information_schema')
order by 1 \gexec
SQL
echo "  $(wc -l < "$WORK/counts.txt") 张表,$(du -h "$WORK/db.dump" | cut -f1)"

step "导出 MinIO 文件"
"${COMPOSE[@]}" stop minio
tar -C data -cf "$WORK/minio.tar" minio
"${COMPOSE[@]}" start minio
echo "  $(du -h "$WORK/minio.tar" | cut -f1)"

cp VERSION "$WORK/VERSION" 2>/dev/null || true
date '+%Y-%m-%d %H:%M:%S %z' > "$WORK/exported_at"
tar -C "$WORK" -cf "$OUT.tmp" .
mv -f "$OUT.tmp" "$OUT"

echo
echo "✅ 导出完成:$OUT($(du -h "$OUT" | cut -f1))"
echo "  把它传到新服务器的 $OUT_DIR/(文件名不能改),在新服务器执行 bash migrate-import.sh"
echo "  app 仍是停止状态;回滚:cd $DIR && ${COMPOSE[*]} up -d"
