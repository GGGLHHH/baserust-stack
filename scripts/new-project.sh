#!/usr/bin/env bash
# 以本底座(baserust-stack)起一个新项目:建 3 个新仓库,带着底座的完整历史,之后能用
# scripts/sync-base.sh 把底座的更新合并过去。说明见 docs/new-project.md。
#
#   ./scripts/new-project.sh shop                     在 GitHub 当前账号下建私有仓库
#   ./scripts/new-project.sh shop --owner my-org      建在组织 my-org 下
#   ./scripts/new-project.sh shop --public            建公开仓库
#   ./scripts/new-project.sh shop --remote-base <URL前缀>   不建 GitHub 仓库,推到 <URL前缀>/<仓库名>.git(事先建好的空仓库)
#   ./scripts/new-project.sh shop --dir ../shop-stack       项目的本地目录(默认和本仓库并排:../<项目名>-stack)
#
# 建出来的:
#   <项目名>-stack     总仓库(本仓库的副本):子模块 baserust/、basereact/ 改指向下面两个项目仓库,
#                      rust-idm / rust-content / cadenza 仍用底座的(它们是库,按版本引用,不用复制)
#   <项目名>-backend   后端(baserust 的副本)
#   <项目名>-frontend  前端(basereact 的副本)
# 目录名、crate 名等内部名字都不改:改了以后每次同步都会冲突。项目对外的名字靠项目名参数化
# (compose 项目名、部署目录、镜像名、品牌文件)。
#
# 不用 GitHub 的 fork:公开仓库的 fork 不能设成私有;这里新建仓库、推底座历史、把底座地址记进 project.env。
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
BASE_ROOT="$(pwd)"

die() { echo "❌ $*" >&2; exit 1; }
step() { echo; echo "▶ $*"; }

NAME=""; OWNER=""; VISIBILITY=--private; REMOTE_BASE=""; DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --owner) OWNER="$2"; shift 2 ;;
    --public) VISIBILITY=--public; shift ;;
    --remote-base) REMOTE_BASE="${2%/}"; shift 2 ;;
    --dir) DIR="$2"; shift 2 ;;
    -h|--help) awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit 0 ;;
    -*) die "不认识的参数 $1(用 --help 看用法)" ;;
    *) [ -z "$NAME" ] || die "只能给一个项目名"; NAME="$1"; shift ;;
  esac
done
[ -n "$NAME" ] || die "缺项目名:./scripts/new-project.sh <项目名>"
[[ "$NAME" =~ ^[a-z][a-z0-9-]*$ ]] || die "项目名只能用小写字母、数字、短横线,字母开头:$NAME"
[ -f project.env ] && die "这里已经是一个项目(有 project.env),请在底座 baserust-stack 里运行"
git diff --quiet && git diff --cached --quiet || die "底座有没提交的改动:先提交或收起,新项目要从干净的提交起"

DIR="${DIR:-../$NAME-stack}"
[ -e "$DIR" ] && die "$DIR 已存在"

# 底座各仓库的地址和分支(从本仓库的 remote 和 .gitmodules 推出来)
BASE_STACK_URL="$(git remote get-url origin)"
BASE_STACK_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
BASE_DIR_URL="${BASE_STACK_URL%/*}"
sub_url() {   # .gitmodules 里的相对地址 ../x.git → 底座所在位置的绝对地址
  local u; u="$(git -C "$BASE_ROOT" config -f .gitmodules "submodule.$1.url")"
  case "$u" in ../*) echo "$BASE_DIR_URL/${u#../}" ;; *) echo "$u" ;; esac
}
sub_branch() { git -C "$BASE_ROOT" config -f .gitmodules "submodule.$1.branch"; }
BASE_BACKEND_URL="$(sub_url baserust)";  BASE_BACKEND_BRANCH="$(sub_branch baserust)"
BASE_FRONTEND_URL="$(sub_url basereact)"; BASE_FRONTEND_BRANCH="$(sub_branch basereact)"

# 新仓库地址
if [ -n "$REMOTE_BASE" ]; then
  url_of() { echo "$REMOTE_BASE/$1.git"; }
else
  command -v gh >/dev/null || die "需要 gh(GitHub CLI)并已登录;或者用 --remote-base 指定事先建好的空仓库"
  OWNER="${OWNER:-$(gh api user --jq .login)}"
  url_of() { echo "https://github.com/$OWNER/$1.git"; }
fi
STACK_REPO="$NAME-stack"; BACKEND_REPO="$NAME-backend"; FRONTEND_REPO="$NAME-frontend"

echo "═══ 新项目 $NAME ═══"
echo "  底座:$BASE_STACK_URL($BASE_STACK_BRANCH)"
echo "  新仓库:$(url_of "$STACK_REPO")、$(url_of "$BACKEND_REPO")、$(url_of "$FRONTEND_REPO")"
echo "  本地目录:$DIR"

if [ -z "$REMOTE_BASE" ]; then
  step "在 GitHub 建仓库($OWNER,${VISIBILITY#--})"
  for repo in "$STACK_REPO" "$BACKEND_REPO" "$FRONTEND_REPO"; do
    gh repo create "$OWNER/$repo" "$VISIBILITY" >/dev/null
    echo "  ✓ $OWNER/$repo"
  done
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# 后端 / 前端:底座本地子模块的当前提交(= 底座总仓库钉住的版本)连同历史推到新仓库
step "推后端、前端的底座历史"
push_history() {   # $1=子模块目录 $2=分支 $3=新仓库地址
  local sha; sha="$(git -C "$1" rev-parse HEAD)"
  git clone -q --no-local "$BASE_ROOT/$1" "$STAGE/$1"
  git -C "$STAGE/$1" push -q "$3" "$sha:refs/heads/$2"
  echo "  ✓ $1 @ ${sha:0:8} → $3($2)"
}
push_history baserust "$BASE_BACKEND_BRANCH" "$(url_of "$BACKEND_REPO")"
push_history basereact "$BASE_FRONTEND_BRANCH" "$(url_of "$FRONTEND_REPO")"

# 总仓库:底座当前提交的历史 + 一个起项目的提交
step "建总仓库 $DIR"
git clone -q --no-local "$BASE_ROOT" "$DIR"
cd "$DIR"
git remote rename origin upstream
git remote set-url upstream "$BASE_STACK_URL"
git remote add origin "$(url_of "$STACK_REPO")"
# 子模块:后端 / 前端指向项目仓库(相对地址,跟着总仓库走 https / ssh);库仍用底座的(绝对地址)
git config -f .gitmodules submodule.baserust.url "../$BACKEND_REPO.git"
git config -f .gitmodules submodule.basereact.url "../$FRONTEND_REPO.git"
for lib in rust-idm rust-content cadenza; do
  git config -f .gitmodules "submodule.$lib.url" "$(sub_url "$lib")"
done
# 本机开发 compose 的项目名:和底座、别的项目同时跑也不撞容器和数据卷
sed -i.bak "s/^name: baserust-stack$/name: $NAME-stack/" compose.yaml && rm -f compose.yaml.bak
cat > project.env <<EOF
# 本项目由 baserust-stack 底座生成(scripts/new-project.sh,$(date '+%Y-%m-%d'))。
# scripts/sync-base.sh 按这里的地址合并底座的更新。这个文件只有项目里有,底座里没有。
PROJECT_NAME=$NAME
BASE_STACK_URL=$BASE_STACK_URL
BASE_STACK_BRANCH=$BASE_STACK_BRANCH
BASE_BACKEND_URL=$BASE_BACKEND_URL
BASE_BACKEND_BRANCH=$BASE_BACKEND_BRANCH
BASE_FRONTEND_URL=$BASE_FRONTEND_URL
BASE_FRONTEND_BRANCH=$BASE_FRONTEND_BRANCH
EOF
git add .gitmodules compose.yaml project.env
git commit -q -m "chore: start $NAME from baserust-stack" -m "base: $BASE_STACK_URL @ $(git rev-parse --short HEAD)"
git push -q -u origin "HEAD:refs/heads/$BASE_STACK_BRANCH"
echo "  ✓ $(url_of "$STACK_REPO")($BASE_STACK_BRANCH)"

step "检出子模块"
git submodule sync -q
git submodule update --init -q
git -C baserust remote add upstream "$BASE_BACKEND_URL"
git -C basereact remote add upstream "$BASE_FRONTEND_URL"
bash scripts/check-git-deps.sh

cat <<EOF

✅ 项目 $NAME 建好了:$DIR
  下一步:
    1. 改品牌:basereact/src/brand.tsx、basereact/src/i18n/locales/*/common.json 的 appTitle、basereact/public/ 下的图标
    2. 加业务:照 docs/new-project.md 的「怎么改才好同步」
    3. 部署:just prod-init --name $NAME --port <端口>,再 just prod-build --all
    4. 底座有更新时:./scripts/sync-base.sh
EOF
