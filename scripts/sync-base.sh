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
#      库(rust-idm / rust-content / cadenza 等)跟底座走;.gitmodules 取底座的,后端 / 前端的地址保留项目自己的
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
  git -C "$1" diff --quiet ${ign[@]+"${ign[@]}"} && git -C "$1" diff --cached --quiet ${ign[@]+"${ign[@]}"}
}
in_merge() { git -C "$1" rev-parse -q --verify MERGE_HEAD >/dev/null; }
conflicts() { git -C "$1" diff --name-only --diff-filter=U; }
# 新开同步分支;同名分支已存在(之前没做完的同步)就停下,别悄悄接着用一个旧分支
new_branch() {   # $1=目录
  if git -C "$1" rev-parse -q --verify "refs/heads/$BRANCH" >/dev/null; then
    die "$1 已有分支 $BRANCH(之前没做完的同步?):要接着做就切过去再运行;确认没用了就 git -C $1 branch -D $BRANCH"
  fi
  git -C "$1" -c submodule.recurse=false switch -q -c "$BRANCH"
}
# 库子模块(除后端 / 前端以外的):每行「名字 路径」
libs() {
  git config -f .gitmodules --get-regexp '^submodule\..*\.path$' | while read -r key path; do
    key="${key#submodule.}"
    case "$path" in baserust|basereact) ;; *) echo "${key%.path} $path" ;; esac
  done
}

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
  local d="$1" here
  git -C "$d" fetch -q upstream "$2"
  git -C "$d" cat-file -e "$3^{commit}" 2>/dev/null \
    || die "底座钉住的 $d 提交 ${3:0:8} 在 upstream/$2 上取不到:底座那边还没推送?"
  if git -C "$d" merge-base --is-ancestor "$3" HEAD; then
    echo "  = $d 已包含底座 ${3:0:8}"
    return 0
  fi
  if [ "$(git -C "$d" rev-parse --abbrev-ref HEAD)" != "$BRANCH" ]; then
    # 子模块停在别的分支(比如没做完的功能)上时,不能把它一起合进同步分支、钉进总仓库
    here="$(git ls-tree HEAD "$d" | awk '{ print $3 }')"
    [ "$(git -C "$d" rev-parse HEAD)" = "$here" ] \
      || die "$d 不在总仓库钉住的提交 ${here:0:8} 上:先 git submodule update $d(或把它切回去)再运行"
    new_branch "$d"
  fi
  if ! git -C "$d" merge -q --no-edit -m "chore: merge base ${3:0:8}" "$3"; then
    in_merge "$d" || die "$d 的合并没开始(见上面 git 的报错,比如未跟踪的文件会被覆盖)"
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
  [ "$(git rev-parse --abbrev-ref HEAD)" = "$BRANCH" ] || new_branch .
  # 子模块指针冲突是预期的(下面统一设);合并根本没开始(比如未跟踪的文件会被覆盖)就停下
  if ! G -c advice.submoduleMergeConflict=false merge -q --no-commit --no-ff "$BASE_STACK_SHA" >/dev/null; then
    in_merge . || die "总仓库的合并没开始(见上面 git 的报错)"
  fi
  # .gitmodules:取底座的(底座可能加了库),后端 / 前端换回项目自己的地址,库的相对地址换成底座的绝对地址
  backend_url="$(git config --blob HEAD:.gitmodules submodule.baserust.url)"
  frontend_url="$(git config --blob HEAD:.gitmodules submodule.basereact.url)"
  git show "$BASE_STACK_SHA:.gitmodules" > .gitmodules
  git config -f .gitmodules submodule.baserust.url "$backend_url"
  git config -f .gitmodules submodule.basereact.url "$frontend_url"
  while read -r name path; do
    url="$(git config -f .gitmodules "submodule.$name.url")"
    case "$url" in ../*) git config -f .gitmodules "submodule.$name.url" "${BASE_STACK_URL%/*}/${url#../}" ;; esac
    # 库跟底座走(要和后端 Cargo.lock 锁的版本一致,下面会核对)
    git update-index --add --cacheinfo "160000,$(pinned "$path"),$path"
  done < <(libs)
  git add .gitmodules
  STACK_MERGED=1
fi
# 子模块检出到要用的提交,再把后端 / 前端的指针设成合并出来的提交
git submodule sync -q
# shellcheck disable=SC2046  # 路径里没有空格
git submodule update -q --init $(libs | awk '{ print $2 }')
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
