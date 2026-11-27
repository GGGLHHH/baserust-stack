# baserust-stack 常用命令。用法:just <目标>

# 基础设施容器 —— pg(+迁移)· minio(+建桶)· nats · dbhub。
# 后端 / 前端在本机手动起:baserust 里 just dev,basereact 里 pnpm dev(连接配置见各自 .env)。
infra_services := "pg migrate minio minio-init nats dbhub"

# 只起基础容器(改了迁移要重建 migrate 镜像:just infra --build)
infra *flags:
    docker compose up -d {{flags}} {{infra_services}}

# 整栈(含 app / idm / web / nginx)
up *flags:
    docker compose up -d --build {{flags}}

# initdb 只在空卷首次启动时跑:老卷升级到多租户先跑这个,再 `just infra --build`(重跑 migrate)。
# 打的是本栈(baserust-stack)的 pg 容器,脚本用 baserust/scripts/initdb 里的。账号名 / 密码按 .env.compose
# (同名环境变量优先,和 compose 一样)显式传进去:老的 pg 容器建的时候还没有 owner / system 这几个环境变量,
# 改过 .env.compose 的密码容器里也还是旧值。没配的取 baserust/docker-compose.yml 里写的缺省:运行时账号 = schema 名,
# owner / system = app_owner / app_system 这样**按 schema 名写死**(不跟 *_DB_USER 走),密码 pwd。
# 测试:scripts/tests/db-ensure-roles.test.sh。
# 给已有的 pg 卷补齐 role 并拆分多租户账号(先于迁移,可重复执行)
db-ensure-roles:
    #!/usr/bin/env bash
    set -euo pipefail
    # .env.compose 里没被环境变量覆盖的键。按 compose 的 .env 规则取值:整行在第一个 '=' 处切开(值里、末尾的
    # '=' 都保留),去掉回车;单 / 双引号括起来的取引号里的原文(双引号里认 \" \\ \n \t,收尾引号之后的是注释),
    # 不带引号的去掉首尾空白,空白后面的 '#' 起是行内注释('a#b' 里的 '#' 是值的一部分)。
    # 不做 $ 插值,所以值里有 $ 就报错:不带引号 / 双引号里的 $ compose 会当变量插值(\$ 也不保证原样),
    # 照原文传下去,账号密码就和 compose 给容器的对不上。单引号里 compose 不插值,原样放行。
    dotenv_value() { # $1=等号后面的原文 $2=键名(报错用)
      local raw="$1" v q out="" c i
      no_dollar() { echo ".env.compose:$1 的值里有 \$:compose 会把它当变量插值,这里不插值 —— 要字面的 \$ 就把整个值用单引号括起来(compose 对单引号不插值),否则去掉 \$" >&2; }
      v="${raw#"${raw%%[![:space:]]*}"}"
      case "$v" in
        \"* | \'*)
          q="${v:0:1}"
          for ((i = 1; i < ${#v}; i++)); do
            c="${v:i:1}"
            if [ "$c" = "$q" ]; then printf '%s' "$out"; return 0; fi
            if [ "$q" = '"' ] && [ "$c" = '$' ]; then no_dollar "$2"; return 1; fi
            if [ "$q" = '"' ] && [ "$c" = "\\" ] && [ $((i + 1)) -lt ${#v} ]; then
              i=$((i + 1)); c="${v:i:1}"
              case "$c" in n) c=$'\n' ;; t) c=$'\t' ;; '"' | "\\") ;; '$') no_dollar "$2"; return 1 ;; *) c="\\$c" ;; esac
            fi
            out+="$c"
          done
          echo ".env.compose:$2 的引号没有收尾" >&2; return 1 ;;
        *)
          v="${raw%%[[:space:]]#*}"; v="${v#"${v%%[![:space:]]*}"}"
          case "$v" in *'$'*) no_dollar "$2"; return 1 ;; esac
          printf '%s' "${v%"${v##*[![:space:]]}"}" ;;
      esac
    }
    while IFS= read -r line; do
      line="${line%$'\r'}"; k="${line%%=*}"
      [ -n "${!k+x}" ] && continue
      v="$(dotenv_value "${line#*=}" "$k")"
      export "$k=$v"
    done < <(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' .env.compose || true)
    # 缺省值照 baserust/docker-compose.yml:运行时账号 = schema 名;owner / system 按 schema 名写死
    # (${APP_DB_OWNER_USER:-app_owner} …),不是「运行时账号名 + 后缀」—— 只改了 APP_DB_USER 时 compose 仍用 app_owner。
    e=()
    for s in APP IDM CONTENT SEARCH OPS; do
      user_var="${s}_DB_USER"; pw_var="${s}_DB_PASSWORD"; lower="$(printf '%s' "$s" | tr '[:upper:]' '[:lower:]')"; user="${!user_var:-$lower}"
      e+=(-e "${s}_DB_USER=$user" -e "${s}_DB_PASSWORD=${!pw_var:-pwd}")
      case "$s" in APP | CONTENT | SEARCH)
        for kind in owner system; do
          u="${s}_DB_$(printf '%s' "$kind" | tr '[:lower:]' '[:upper:]')_USER"; p="${u%_USER}_PASSWORD"
          e+=(-e "$u=${!u:-${lower}_$kind}" -e "$p=${!p:-pwd}")
        done ;;
      esac
    done
    docker compose exec -T "${e[@]}" pg bash -s < baserust/scripts/initdb/00-roles-schemas.sh
    docker compose exec -T "${e[@]}" pg bash -s < baserust/scripts/initdb/10-tenancy-roles.sh

# 看状态
ps:
    docker compose ps -a

# 停掉(保留数据卷);连数据一起清用 just down -v
down *flags:
    docker compose down {{flags}}

# ── 生产部署(scripts/prod,说明见 scripts/prod/README.md)──
# 一次性生成生产配置:just prod-init --name shop --port 8080
prod-init *args:
    bash scripts/prod/init.sh {{args}}

# 打离线部署包(首次部署加 --all):产物在 prod/update/,传到服务器执行里面的 .run
prod-build *args:
    bash scripts/prod/build.sh {{args}}

# ── 新项目 / 同步底座(说明见 docs/new-project.md)──
# 以本底座起新项目(在底座里运行):just new-project shop --owner my-org
new-project *args:
    bash scripts/new-project.sh {{args}}

# 把底座的更新合并进本项目(在项目里运行)
sync-base *args:
    bash scripts/sync-base.sh {{args}}
