#!/usr/bin/env bash
# 把底座(baserust-stack)的更新合并进本项目。在项目的总仓库里运行(有 project.env 的那个)。
#
#   ./scripts/sync-base.sh             合并 + 跑检查(后端 lint / test,前端 lint / tsc / test)
#   ./scripts/sync-base.sh --no-test   只合并,不跑测试(只跑版本、配置一致性检查)
#
# 做什么:
#   1. 取底座总仓库的最新提交,看它钉住的后端 / 前端版本(底座每个提交 = 一组能一起跑的版本)
#   2. 后端、前端:各开一个 sync/base-<日期> 分支,合并底座的那个版本
#   3. 总仓库:开同名分支合并底座;子模块指针 —— 后端 / 前端用刚合并出来的提交,
#      rust-idm / rust-content / cadenza 跟底座走;.gitmodules 保留项目自己的
#   4. 检查:子模块和 Cargo.lock 一致、nginx 配置没漂移,再跑测试
# 有冲突就停下,列出文件。解决完提交(后端 / 前端在各自目录里,总仓库在这里),再运行一次本脚本,
# 已经合并好的会跳过。
# 不推送:看过没问题后,按最后打印的命令推后端、前端,再推总仓库。
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

die() { echo "❌ $*" >&2; exit 1; }
step() { echo; echo "▶ $*"; }

RUN_TESTS=1
for arg in "$@"; do
  case "$arg" in
    --no-test) RUN_TESTS="" ;;
    -h|--help) awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit 0 ;;
    *) die "不认识的参数 $arg(用 --help 看用法)" ;;
  esac
done

[ -f project.env ] || die "没有 project.env:这里是底座本身,或者不是用 scripts/new-project.sh 起的项目"
# shellcheck disable=SC1091
. ./project.env
BRANCH="sync/base-$(date +%Y%m%d)"

# 总仓库这一层不看子模块指针:同步中途(后端解决完冲突)指针本来就会变,脚本最后会统一设好。
is_clean() {
  local ign=(); [ "$1" = . ] && ign=(--ignore-submodules=all)
  git -C "$1" diff --quiet "${ign[@]}" && git -C "$1" diff --cached --quiet "${ign[@]}"
}
in_merge() { git -C "$1" rev-parse -q --verify MERGE_HEAD >/dev/null; }
conflicts() { git -C "$1" diff --name-only --diff-filter=U; }

for d in . baserust basereact; do
  in_merge "$d" && die "$d 有没完成的合并:解决冲突并提交后再运行"
  is_clean "$d" || die "$d 有没提交的改动:先提交或收起"
done

ensure_upstream() {   # $1=目录 $2=底座地址
  if git -C "$1" remote get-url upstream >/dev/null 2>&1; then
    git -C "$1" remote set-url upstream "$2"
  else
    git -C "$1" remote add upstream "$2"
  fi
}
ensure_upstream . "$BASE_STACK_URL"
ensure_upstream baserust "$BASE_BACKEND_URL"
ensure_upstream basereact "$BASE_FRONTEND_URL"

step "取底座更新"
# 总仓库这一层的 git 命令都不连带子模块:底座钉住的后端 / 前端提交在项目仓库里没有,
# 让 git 顺带去子模块里取只会报错;子模块下面单独从各自的 upstream 取。
G() { git -c submodule.recurse=false "$@"; }
G fetch -q --no-recurse-submodules upstream "$BASE_STACK_BRANCH"
BASE_REF="upstream/$BASE_STACK_BRANCH"
BASE_STACK_SHA="$(git rev-parse "$BASE_REF")"
pinned() { git ls-tree "$BASE_REF" "$1" | awk '{ print $3 }'; }
BASE_BACKEND_SHA="$(pinned baserust)"
BASE_FRONTEND_SHA="$(pinned basereact)"
echo "  底座 ${BASE_STACK_SHA:0:8}:后端 ${BASE_BACKEND_SHA:0:8},前端 ${BASE_FRONTEND_SHA:0:8}"

# 子模块合并:从项目现在钉住的提交开分支,合并底座钉住的版本
merge_sub() {   # $1=目录 $2=底座分支 $3=底座提交
  local d="$1"
  git -C "$d" fetch -q upstream "$2"
  if git -C "$d" merge-base --is-ancestor "$3" HEAD; then
    echo "  = $d 已包含底座 ${3:0:8}"
    return 0
  fi
  if [ "$(git -C "$d" rev-parse --abbrev-ref HEAD)" != "$BRANCH" ]; then
    git -C "$d" switch -q -c "$BRANCH" 2>/dev/null || git -C "$d" switch -q "$BRANCH"
  fi
  if ! git -C "$d" merge -q --no-edit -m "chore: merge base ${3:0:8}" "$3"; then
    echo "❌ $d 合并有冲突:" >&2
    conflicts "$d" | sed 's/^/     /' >&2
    die "进 $d 解决冲突、git add、git commit,再运行 ./scripts/sync-base.sh"
  fi
  echo "  ✓ $d 合并了底座 ${3:0:8}"
}

step "合并后端、前端"
merge_sub baserust "$BASE_BACKEND_BRANCH" "$BASE_BACKEND_SHA"
merge_sub basereact "$BASE_FRONTEND_BRANCH" "$BASE_FRONTEND_SHA"

step "合并总仓库"
if git merge-base --is-ancestor "$BASE_STACK_SHA" HEAD; then
  echo "  = 总仓库已包含底座 ${BASE_STACK_SHA:0:8}"
  STACK_MERGED=""
else
  if [ "$(git rev-parse --abbrev-ref HEAD)" != "$BRANCH" ]; then
    G switch -q -c "$BRANCH" 2>/dev/null || G switch -q "$BRANCH"
  fi
  G merge -q --no-commit --no-ff "$BASE_STACK_SHA" >/dev/null 2>&1 || true
  # .gitmodules:项目的地址(后端 / 前端指向项目仓库)
  git checkout -q HEAD -- .gitmodules
  # 库跟底座走(要和后端 Cargo.lock 锁的版本一致,下面会核对)
  for lib in rust-idm rust-content cadenza; do
    git update-index --cacheinfo "160000,$(pinned "$lib"),$lib"
  done
  STACK_MERGED=1
fi
# 子模块检出到要用的提交,再把后端 / 前端的指针设成合并出来的提交
git submodule update -q --init rust-idm rust-content cadenza
git add baserust basereact
if [ -n "$STACK_MERGED" ]; then
  left="$(conflicts .)"
  if [ -n "$left" ]; then
    echo "❌ 总仓库合并有冲突:" >&2
    echo "$left" | sed 's/^/     /' >&2
    die "解决冲突、git add、git commit,再运行 ./scripts/sync-base.sh"
  fi
  G commit -q -m "chore: merge base ${BASE_STACK_SHA:0:8}"
  echo "  ✓ 总仓库合并了底座 ${BASE_STACK_SHA:0:8}"
elif ! git diff --cached --quiet; then
  G commit -q -m "chore: bump backend and frontend after base sync"
  echo "  ✓ 更新了后端 / 前端指针"
fi

step "检查"
bash scripts/check-git-deps.sh
bash scripts/check-nginx-drift.sh
if [ -n "$RUN_TESTS" ]; then
  (cd baserust && just lint && just test)
  (cd basereact && pnpm install --frozen-lockfile && pnpm lint && pnpm tsc && pnpm test)
fi

cat <<EOF

✅ 底座 ${BASE_STACK_SHA:0:8} 已合并(本地,还没推送)
  看一遍改动:git log --oneline -5;baserust、basereact 里同样
  没问题就推(先后端、前端,最后总仓库):
    git -C baserust push origin HEAD:$BASE_BACKEND_BRANCH
    git -C basereact push origin HEAD:$BASE_FRONTEND_BRANCH
    git push origin HEAD:$BASE_STACK_BRANCH
  然后照常打包部署:just prod-build
EOF
