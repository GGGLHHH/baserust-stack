#!/usr/bin/env bash
# baserust 按 git 提交(tag / rev)依赖 rust-idm / rust-content;本仓库检出的子模块必须正好是
# baserust/Cargo.lock 锁的那个提交 —— 否则「这组版本能一起跑」不成立,
# scripts/prod/build.sh 用子模块源码构建出来的也不是锁定的版本。
set -euo pipefail
cd "$(dirname "$0")/.."

for dep in idm:rust-idm content:rust-content; do
  crate="${dep%%:*}"; sub="${dep#*:}"
  locked="$(awk -v n="$crate" -v q='"' '$0 == "name = " q n q { f = 1; next } f && /^\[\[package\]\]/ { exit } f && /^source = "git\+/ { sub(/.*#/, ""); sub(q "$", ""); print; exit }' baserust/Cargo.lock)"
  if [ -z "$locked" ]; then
    echo "❌ baserust/Cargo.lock 里 $crate 不是 git 依赖(改成 path 依赖了?打包要按 git tag / rev 引用)" >&2; exit 1
  fi
  if ! head="$(git -C "$sub" rev-parse HEAD 2>/dev/null)"; then
    echo "❌ 子模块 $sub 没检出(git submodule update --init)" >&2; exit 1
  fi
  if [ "$head" != "$locked" ]; then
    echo "❌ 子模块 $sub 在 ${head:0:8},baserust/Cargo.lock 锁的是 ${locked:0:8}:先对齐(git submodule update)" >&2
    exit 1
  fi
  echo "✓ $sub = ${locked:0:8}"
done
