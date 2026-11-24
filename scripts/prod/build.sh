#!/usr/bin/env bash
# 本机打离线部署包:构建自家镜像(linux/amd64),和第三方镜像一起导出;部署包和镜像分开放在 prod/ 下。
#
#   ./scripts/prod/build.sh              构建全部,只导出和上次导出相比有变化的镜像
#   ./scripts/prod/build.sh app web      只构建并导出指定的服务(服务名见下面的 SERVICES)
#   ./scripts/prod/build.sh --all        构建并导出全部(新服务器首次部署用)
#   BUILD_MIRROR=official ./scripts/prod/build.sh   不走国内源(默认走:Docker Hub / gcr.io / Debian / crates.io / npm)
#
# 产物(都在 prod/,已在 .gitignore):
#   <项目名>-deploy_<时间>.run   部署包:生产配置 + 密钥 + deploy.sh,不含镜像。每次都重新生成
#   images/<镜像>.tar.gz         每个镜像一个文件,文件名固定,新导出的覆盖旧的
#   images/<镜像>.id             上次导出时的镜像 ID,用来判断下次有没有变化
#   update/                      这次要传到服务器的全部东西:这次的 .run + 这次新导出的镜像(硬链接,不多占磁盘)
#   migrate-export.sh / migrate-import.sh   换服务器时的数据迁移脚本
# 升级时把 update/ 整个传到服务器的一个空目录,进去执行 bash <项目名>-deploy_<时间>.run。
# 第三方镜像(postgres / nginx / minio / nats)也一起导出:服务器不用连 Docker Hub。
# 包里的 .env 来自本机 .env.prod(含全部生产密钥),只在本机和服务器之间传,别外传。
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
ROOT="$(pwd)"

die() { echo "❌ $*" >&2; exit 1; }

# 服务名 → 镜像名 → 来源。build:<上下文目录>:<Dockerfile 的 target>;pull = 第三方镜像。
# 镜像名与 baserust/docker-compose.prod.yml、deploy/prod/compose.web.yml 里的 image: 一致。
SERVICES=(app migrate web postgres nginx minio mc nats)
IMAGES=(baserust-runtime:latest baserust-migrate:latest basereact-web:latest postgres:17-alpine nginx:alpine pgsty/minio:latest pgsty/mc:latest nats:alpine)
SOURCES=(build:baserust:runtime build:baserust:migrate build:basereact:runner pull pull pull pull pull)

index_of() {
  local i
  for i in "${!SERVICES[@]}"; do
    [ "${SERVICES[$i]}" = "$1" ] && { echo "$i"; return; }
  done
  die "没有服务 $1(可选:${SERVICES[*]})"
}

# ── 参数 ───────────────────────────────────────────────
MODE=changed   # changed:导出有变化的 / all:全部导出 / pick:导出指定的
PICKED=()
for arg in "$@"; do
  case "$arg" in
    --all) MODE=all ;;
    -h|--help) awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit 0 ;;
    -*) die "不认识的参数 $arg(用 --help 看用法)" ;;
    *) index_of "$arg" >/dev/null; PICKED+=("$arg") ;;
  esac
done
if [ "${#PICKED[@]}" -gt 0 ]; then
  [ "$MODE" = all ] && die "--all 和指定服务不能一起用"
  MODE=pick
  TARGETS=("${PICKED[@]}")
else
  TARGETS=("${SERVICES[@]}")
fi

ENV_PROD="${ENV_PROD:-.env.prod}"
SECRETS="${PROD_SECRETS:-prod-secrets}"
OUT_DIR="${PROD_OUT:-prod}"
[ -f "$ENV_PROD" ] || die "缺 $ENV_PROD:先执行 ./scripts/prod/init.sh 生成生产配置"
grep -Eq '^[A-Za-z_][A-Za-z0-9_]*=.*CHANGE-ME' "$ENV_PROD" && die "$ENV_PROD 里还有 CHANGE-ME 没改"
for f in "$SECRETS/keys/prod-ed25519.pem" "$SECRETS/keys/prod-ed25519.pub.pem" "$SECRETS/seed.prod.toml"; do
  [ -f "$f" ] || die "缺 $f:先执行 ./scripts/prod/init.sh"
done
NAME="$(sed -n 's/^COMPOSE_PROJECT_NAME=//p' "$ENV_PROD" | tail -n 1)"
[ -n "$NAME" ] || die "$ENV_PROD 里没有 COMPOSE_PROJECT_NAME"

IMG_DIR="$OUT_DIR/images"
UPD_DIR="$OUT_DIR/update"
mkdir -p "$IMG_DIR"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE" "$IMG_DIR"/*.tar.gz.tmp' EXIT

# ── 国内源 ─────────────────────────────────────────────
# 默认走国内源(Docker Hub、gcr.io、Debian、crates.io、npm 在国内都不稳)。BUILD_MIRROR=official 走官方源。
# Dockerfile 里这些都是可选 build arg,不传就是官方源;直接 docker build 不受影响。
BUILD_ARGS=()
CN=
if [ "${BUILD_MIRROR:-cn}" = cn ]; then
  CN=1
  BUILD_ARGS=(
    --build-arg APT_MIRROR=http://mirrors.aliyun.com
    --build-arg CARGO_MIRROR=sparse+https://rsproxy.cn/index/
    --build-arg NPM_REGISTRY=https://registry.npmmirror.com
  )
fi

# 镜像本地没有就拉:国内源模式下从镜像站拉下来再打上原名,FROM / compose 都用原名。
# 已经有的不重新拉,保持基础镜像稳定,构建缓存才命中得上。要升级就先 docker image rm 它。
ensure_image() {
  local ref="$1" src
  docker image inspect "$ref" >/dev/null 2>&1 && return 0
  if [ -z "$CN" ]; then
    docker pull -q --platform linux/amd64 "$ref" >/dev/null || die "拉不到 $ref"
    echo "  ↓ $ref"
    return 0
  fi
  local candidates=()
  case "$ref" in
    gcr.io/*) candidates=("m.daocloud.io/$ref") ;;
    */*)      candidates=("docker.m.daocloud.io/$ref" "docker.1ms.run/$ref") ;;
    *)        candidates=("docker.m.daocloud.io/library/$ref" "docker.1ms.run/library/$ref") ;;
  esac
  for src in "${candidates[@]}"; do
    if docker pull -q --platform linux/amd64 "$src" >/dev/null 2>&1; then
      docker tag "$src" "$ref" && docker image rm "$src" >/dev/null
      echo "  ↓ $ref(来自 ${src%%/*})"
      return 0
    fi
  done
  die "拉不到 $ref(试过:${candidates[*]})"
}

echo "═══ 打包 $NAME(模式:$MODE,源:$([ -n "$CN" ] && echo 国内 || echo 官方))═══"

# ── 基础镜像 + 第三方镜像 ──────────────────────────────
echo "▶ 准备基础镜像"
for df in baserust/Dockerfile basereact/Dockerfile; do
  for ref in $(sed -n 's/^FROM[[:space:]]\{1,\}\([^[:space:]]*\).*/\1/p' "$df" | sort -u); do
    [ "$ref" = scratch ] && continue   # 内置的空镜像,不用拉
    ensure_image "$ref"
  done
done

# ── git 依赖的本地源码 ─────────────────────────────────
# baserust 依赖的 idm / content 在 Cargo.toml 里按 GitHub tag 引用;构建时改用本地子模块
# (git archive 出当前提交的干净源码,不带 target/ 和未提交的改动),不用连 GitHub。
# 先核对:子模块的提交号必须等于 baserust/Cargo.lock 里记的,否则构建出来的不是锁定的版本。
GIT_DEP_ARGS=()
for dep in idm:rust-idm content:rust-content; do
  crate="${dep%%:*}"; sub="${dep#*:}"
  locked="$(awk -v n="$crate" -v q='"' '$0 == "name = " q n q { f = 1; next } f && /^source = / { sub(/.*#/, ""); sub(q "$", ""); print; exit }' baserust/Cargo.lock)"
  [ -n "$locked" ] || die "baserust/Cargo.lock 里找不到 $crate 的 git 来源"
  head="$(git -C "$sub" rev-parse HEAD 2>/dev/null)" || die "子模块 $sub 没检出(git submodule update --init)"
  [ "$head" = "$locked" ] || die "子模块 $sub 在 ${head:0:8},baserust/Cargo.lock 锁的是 ${locked:0:8}:先对齐(git submodule update)"
  mkdir -p "$STAGE/src-$crate"
  git -C "$sub" archive --format=tar HEAD | tar -x -C "$STAGE/src-$crate"
  GIT_DEP_ARGS+=(--build-context "$crate-src=$STAGE/src-$crate")
done

# ── 构建 / 拉取 ────────────────────────────────────────
for svc in "${TARGETS[@]}"; do
  i="$(index_of "$svc")"
  img="${IMAGES[$i]}"
  src="${SOURCES[$i]}"
  if [ "$src" = pull ]; then
    ensure_image "$img"
    continue
  fi
  IFS=: read -r _ ctx target <<< "$src"
  echo "▶ 构建 $svc → $img($ctx,target $target;Rust 首次编译要十几分钟)"
  extra=()
  [ "$ctx" = baserust ] && extra=("${GIT_DEP_ARGS[@]}")
  DOCKER_BUILDKIT=1 docker build --platform linux/amd64 ${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"} \
    ${extra[@]+"${extra[@]}"} --target "$target" -t "$img" "$ctx"
done

# ── 导出 ───────────────────────────────────────────────
EXPORTED=()
for svc in "${TARGETS[@]}"; do
  img="${IMAGES[$(index_of "$svc")]}"
  arch="$(docker image inspect -f '{{.Architecture}}' "$img")" || die "没找到镜像 $img"
  [ "$arch" = amd64 ] || die "$img 是 $arch,服务器要 amd64"

  file="$(echo "${img%%:*}" | tr '/' '_')"
  base="$IMG_DIR/$file"
  id="$(docker image inspect -f '{{.Id}}' "$img")"
  if [ "$MODE" = changed ] && [ -f "$base.tar.gz" ] && [ "$(cat "$base.id" 2>/dev/null)" = "$id" ]; then
    echo "  = $svc 没变化,跳过"
    continue
  fi
  echo "  ↓ 导出 $svc → $base.tar.gz"
  # gzip:docker load 原生能解,服务器不依赖额外工具。先写临时文件再改名:中途失败不留半截文件。
  docker save "$img" | gzip -1 > "$base.tar.gz.tmp"
  mv -f "$base.tar.gz.tmp" "$base.tar.gz"
  echo "$id" > "$base.id"
  EXPORTED+=("$base.tar.gz")
done

# ── 部署包(只有配置、密钥和脚本)──────────────────────
PKG_NAME="$NAME-deploy_$(date +%Y%m%d_%H%M%S)"
PKG="$STAGE/$PKG_NAME"
mkdir -p "$PKG/keys" "$PKG/scripts"
echo "▶ 收集部署文件"
cp baserust/docker-compose.prod.yml "$PKG/"
cp deploy/prod/compose.web.yml "$PKG/"
cp deploy/nginx.conf "$PKG/nginx.conf"
cp "$ENV_PROD" "$PKG/.env"
cp "$SECRETS/keys/prod-ed25519.pem" "$SECRETS/keys/prod-ed25519.pub.pem" "$PKG/keys/"
cp "$SECRETS/seed.prod.toml" "$PKG/seed.prod.toml"
cp -R baserust/scripts/initdb "$PKG/scripts/initdb"
cp scripts/prod/deploy.sh "$PKG/"
chmod 600 "$PKG/.env" "$PKG/keys/prod-ed25519.pem" "$PKG/seed.prod.toml"
chmod +x "$PKG/deploy.sh"
# 版本信息:总仓库与各子模块的提交号;有没提交的改动会标出来(这种包没法从仓库复现)。
{
  echo "package: $PKG_NAME"
  echo "built: $(date '+%Y-%m-%d %H:%M:%S %z')"
  echo "stack: $(git rev-parse --short HEAD)$(git diff --quiet HEAD -- . ':!prod' 2>/dev/null || echo ' (有未提交改动)')"
  git submodule status | while read -r sha path rest; do
    dirty=
    git -C "$path" diff --quiet HEAD 2>/dev/null || dirty=' (有未提交改动)'
    echo "$path: ${sha#[-+U ]}$dirty"
  done
} > "$PKG/VERSION"

# 自解压:一段 bash 头 + __PAYLOAD__ 标记行 + tar 原始字节。头部用 tail 从标记的下一行起原样取出 tar。
# 镜像不在包里:头部把包所在目录下的 images/ 交给 deploy.sh。
OUT="$OUT_DIR/$PKG_NAME.run"
cat > "$OUT" <<HEADER
#!/usr/bin/env bash
# $NAME 离线部署包(自解压)。在服务器上执行:bash $PKG_NAME.run
# 镜像文件放在本文件旁边的 images/ 目录下;没有的镜像沿用服务器上已有的。
[ -n "\${BASH_VERSION:-}" ] || exec bash "\$0" "\$@"
set -euo pipefail
SELF="\$(cd "\$(dirname "\$0")" && pwd)/\$(basename "\$0")"
WORK="\$(mktemp -d "\$(dirname "\$SELF")/.deploy.XXXX")"
trap 'rm -rf "\$WORK"' EXIT
echo "▶ 解包到 \$WORK"
tail -n +"\$(awk '/^__PAYLOAD__\$/ { print NR + 1; exit }' "\$SELF")" "\$SELF" | tar -x -C "\$WORK"
DEPLOY_IMAGES_DIR="\$(dirname "\$SELF")/images" bash "\$WORK/$PKG_NAME/deploy.sh" "\$@"
exit
__PAYLOAD__
HEADER
if tar --version 2>/dev/null | grep -qi 'gnu tar'; then
  tar_own=(--owner=0 --group=0 --numeric-owner --no-xattrs)
else
  tar_own=(--uid 0 --gid 0 --no-xattrs --no-mac-metadata)
fi
COPYFILE_DISABLE=1 tar "${tar_own[@]}" -cf - -C "$STAGE" "$PKG_NAME" >> "$OUT"
chmod 600 "$OUT"   # 含明文 .env 和私钥

find "$OUT_DIR" -maxdepth 1 -name "$NAME-deploy_*.run" ! -name "$PKG_NAME.run" -delete
cp scripts/prod/migrate-export.sh scripts/prod/migrate-import.sh "$OUT_DIR/"

# ── update/:这次要上传的东西 ───────────────────────────
rm -rf "$UPD_DIR"
mkdir -p "$UPD_DIR/images"
cp -p "$OUT" "$UPD_DIR/"
for f in ${EXPORTED[@]+"${EXPORTED[@]}"}; do
  ln "$f" "$UPD_DIR/images/" 2>/dev/null || cp -p "$f" "$UPD_DIR/images/"
done

echo
echo "✅ 打包完成($(sed -n 's/^stack: //p' "$PKG/VERSION"))"
echo "  要上传的:$UPD_DIR/ 整个目录($(du -sh "$UPD_DIR" | cut -f1)),服务器上进去执行 bash $PKG_NAME.run"
if [ "${#EXPORTED[@]}" -gt 0 ]; then
  for f in "${EXPORTED[@]}"; do echo "    images/$(basename "$f")($(du -h "$f" | cut -f1))"; done
else
  echo "    镜像都没变化,里面只有 .run"
fi
grep -q '有未提交改动' "$PKG/VERSION" && echo "  ⚠️ 有仓库带着未提交的改动打的包,见包里的 VERSION"
echo "  全部镜像仍在 $IMG_DIR/(下次比较的基准,别删)"
echo "  ⚠️ 部署包里有全部生产密钥和 JWT 私钥,别外传"
