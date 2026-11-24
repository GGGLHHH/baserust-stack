#!/usr/bin/env bash
# 一次性生成生产配置(本机执行,生成的文件都在 .gitignore 里,绝不入库):
#   .env.prod                       生产环境变量,所有密码随机生成;部署时整份覆盖服务器上的 .env
#   prod-secrets/keys/prod-ed25519.pem / .pub.pem   JWT 签发 / 验签密钥对
#   prod-secrets/seed.prod.toml     首个超管账号(随机密码,只在这里打印一次)
#
#   ./scripts/prod/init.sh                         项目名 baserust,nginx 监听 80
#   ./scripts/prod/init.sh --name shop --port 8080 --domain admin.example.com
#   ./scripts/prod/init.sh --force                 覆盖已有的(⚠️ 换了密码 / 密钥,已部署的服务器要重新部署)
#
#   --name    项目名:compose 项目名、服务器目录 /opt/<名字>/prod、部署包文件名都用它。
#             同一台服务器部署多个项目时,项目名和端口都要不同。
#   --port    服务器上 nginx 对外的端口(前面一般还有 1Panel / LB 负责 HTTPS 和域名)
#   --domain  前端域名,写进 CORS 白名单(前后端同源时可不填)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

die() { echo "❌ $*" >&2; exit 1; }

NAME=baserust
PORT=80
DOMAIN=
FORCE=
while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME="${2:?--name 后面要跟项目名}"; shift 2 ;;
    --port) PORT="${2:?--port 后面要跟端口}"; shift 2 ;;
    --domain) DOMAIN="${2:?--domain 后面要跟域名}"; shift 2 ;;
    --force) FORCE=1; shift ;;
    -h|--help) awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit 0 ;;
    *) die "不认识的参数 $1(用 --help 看用法)" ;;
  esac
done
[[ "$NAME" =~ ^[a-z][a-z0-9-]*$ ]] || die "项目名只能用小写字母、数字和横线,且以字母开头:$NAME"
[[ "$PORT" =~ ^[0-9]+$ ]] || die "端口不是数字:$PORT"

ENV_OUT="${ENV_PROD:-.env.prod}"
SECRETS="${PROD_SECRETS:-prod-secrets}"
TEMPLATE=baserust/.env.prod
SEED_TEMPLATE=baserust/seed.prod.toml.example
[ -f "$TEMPLATE" ] || die "缺 $TEMPLATE(先 git submodule update --init)"
command -v openssl >/dev/null || die "需要 openssl"
if [ -z "$FORCE" ]; then
  for f in "$ENV_OUT" "$SECRETS/keys/prod-ed25519.pem" "$SECRETS/seed.prod.toml"; do
    [ -e "$f" ] && die "$f 已存在。要重新生成就加 --force(⚠️ 会换掉全部密码和密钥)"
  done
fi

rand() { openssl rand -hex "${1:-24}"; }
MINIO_KEY="minio$(rand 8)"
MINIO_SECRET="$(rand 24)"

# 模板里每个 CHANGE-ME 换成随机值;MinIO 的 root 账号和 app 用的 S3 凭据必须是同一对。
echo "▶ 生成 $ENV_OUT"
{
  echo "# 由 scripts/prod/init.sh 于 $(date '+%Y-%m-%d %H:%M:%S') 生成。改配置就改这份,重新打包部署;不要在服务器上直接改。"
  echo "# ── 部署 ──"
  echo "COMPOSE_PROJECT_NAME=$NAME"
  echo "DEPLOY_DIR=/opt/$NAME/prod"
  echo
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"   # Windows 上模板可能是 CRLF 检出,值里不能带回车
    key="${line%%=*}"
    case "$line" in
      NGINX_PORT=*) echo "NGINX_PORT=$PORT" ;;
      CORS_ALLOWED_ORIGINS=*) [ -n "$DOMAIN" ] && echo "CORS_ALLOWED_ORIGINS=https://$DOMAIN" || echo "$line" ;;
      MINIO_USER=*|S3_ACCESS_KEY=*) echo "$key=$MINIO_KEY" ;;
      MINIO_PASSWORD=*|S3_SECRET_KEY=*) echo "$key=$MINIO_SECRET" ;;
      *=CHANGE-ME*) echo "$key=$(rand 24)" ;;
      *) echo "$line" ;;
    esac
  done < "$TEMPLATE"
} > "$ENV_OUT.tmp"
grep -Eq '^[A-Za-z_][A-Za-z0-9_]*=.*CHANGE-ME' "$ENV_OUT.tmp" && die "生成后仍有 CHANGE-ME,模板格式变了?($ENV_OUT.tmp)"
mv -f "$ENV_OUT.tmp" "$ENV_OUT"
chmod 600 "$ENV_OUT"

echo "▶ 生成 JWT 密钥对 $SECRETS/keys/"
mkdir -p "$SECRETS/keys"
openssl genpkey -algorithm ed25519 -out "$SECRETS/keys/prod-ed25519.pem" 2>/dev/null
openssl pkey -in "$SECRETS/keys/prod-ed25519.pem" -pubout -out "$SECRETS/keys/prod-ed25519.pub.pem"
chmod 600 "$SECRETS/keys/prod-ed25519.pem"

echo "▶ 生成超管账号 $SECRETS/seed.prod.toml"
ADMIN_PW="$(rand 12)"
EMAIL_DOMAIN="${DOMAIN:-example.com}"
sed -e "s|CHANGE_ME_strong_random_password|$ADMIN_PW|" \
    -e "s|superadmin@your-domain.example|superadmin@$EMAIL_DOMAIN|" \
    "$SEED_TEMPLATE" > "$SECRETS/seed.prod.toml"
grep -q "$ADMIN_PW" "$SECRETS/seed.prod.toml" || die "seed 模板格式变了,没替换到密码"
chmod 600 "$SECRETS/seed.prod.toml"

echo
echo "✅ 生产配置已生成(都在 .gitignore 里)"
echo "  项目名 $NAME,服务器目录 /opt/$NAME/prod,nginx 端口 $PORT"
echo "  超管账号:superadmin / $ADMIN_PW   ← 只显示这一次,记下来;首次登录后在后台改掉"
echo "  ⚠️ 备份 .env.prod 和 prod-secrets/:丢了 MinIO 凭据就读不出已存的文件,换了 JWT 密钥所有人要重新登录"
echo "  下一步:./scripts/prod/build.sh --all"
