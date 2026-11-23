#!/usr/bin/env bash
# deploy/nginx.conf 应当 = baserust/nginx.conf + 「location / → web」。
# 去掉两边各自的 location / 块(和 deploy 版的头注释)后逐行比较,不一致就退出 1。
set -euo pipefail
cd "$(dirname "$0")/.."

strip_root_location() {
  # 从「# / 」开头的注释行起,到它后面第一个缩进 8 格的 } 为止,整段删掉
  awk '/^        # \/ /{skip=1} skip && /^        }/{skip=0; next} !skip' | tr -d '\r'
}

if diff -u \
  <(strip_root_location < baserust/nginx.conf) \
  <(tail -n +4 deploy/nginx.conf | strip_root_location); then
  echo "nginx.conf 与 baserust 一致(除 location /)"
else
  echo "deploy/nginx.conf 与 baserust/nginx.conf 有出入,按上面的 diff 同步" >&2
  exit 1
fi
