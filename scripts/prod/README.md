# 一键部署与数据迁移

前端 + 后端 + nginx 打成**离线部署包**:本机构建镜像,服务器上传一个目录、执行一条 `bash`,
不用 GitHub、不用 Docker Hub(第三方镜像也一起导出)。生产是**单机 docker compose**。

## 三步

| # | 在哪 | 命令 | 做什么 |
|---|---|---|---|
| 1 | 本机,只做一次 | `./scripts/prod/init.sh --name <项目名> --port <端口>` | 生成 `.env.prod`(全部随机密码)、JWT 密钥对、首个超管账号(密码只打印这一次) |
| 2 | 本机,每次发版 | `./scripts/prod/build.sh`(首次部署用 `--all`) | 构建镜像、导出有变化的镜像、生成部署包,要上传的东西都在 `prod/update/` |
| 3 | 服务器 | 把 `prod/update/` 整个传到一个**新的空目录**,进去用 root 执行 `bash <项目名>-deploy_<时间>.run` | 载入镜像 → 装配置到 `/opt/<项目名>/prod` → 补齐数据库 role → 启动并等全部健康检查通过 |

`just prod-init ...` / `just prod-build ...` 是同样的命令。首次部署和升级都是第 3 步这一条。

### init.sh

```bash
./scripts/prod/init.sh                                   # 项目名 baserust,nginx 端口 80
./scripts/prod/init.sh --name shop --port 8080 --domain admin.example.com
```

- 生成的 `.env.prod`、`prod-secrets/`(JWT 密钥、超管账号)都在 `.gitignore` 里。**备份它们**:
  丢了 MinIO 凭据就读不出已存的文件;换了 JWT 密钥所有人要重新登录。
- 模板是 `baserust/.env.prod`,每个 `CHANGE-ME` 换成随机值;MinIO 的 root 账号和 app 用的 S3 凭据自动设成同一对。
- 要改配置就改 `.env.prod`,重新打包部署。**不要在服务器上直接改 `.env`**:每次部署都会被包里的覆盖。
- 同一台服务器部署多个项目:项目名、端口各不相同即可(compose 项目名、目录、容器名、自家镜像名都按项目名区分)。
- 已经有 `.env.prod` 时会拒绝覆盖;`--force` 重新生成全部密码和密钥(已部署的服务器要重新部署)。

### build.sh

| 命令 | 构建 | 导出到 `prod/images/` |
|---|---|---|
| `./scripts/prod/build.sh` | 全部(没改动的命中缓存,很快) | 只导出镜像 ID 和上次导出时不同的 |
| `./scripts/prod/build.sh app web` | 只构建 / 拉取指定的 | 指定的,不管有没有变化 |
| `./scripts/prod/build.sh --all` | 全部 | 全部(新服务器首次部署用) |

服务名:自家镜像 `app`(app + idm 共用)、`migrate`、`web`;第三方 `postgres` `nginx` `minio`(建桶的 minio-init 也用它,自带 mc)`nats`。

- **默认走国内源**:基础镜像缺了从 DaoCloud / 1ms 镜像站拉下来再打上原名(gcr.io 的 distroless 走 DaoCloud),
  构建里的 apt / cargo / npm 分别走阿里云、rsproxy.cn、npmmirror。不想走:`BUILD_MIRROR=official ./scripts/prod/build.sh`。
- **不连 GitHub**:baserust 依赖的 `rust-idm` / `rust-content` 直接用本仓库的子模块源码(`git archive` 出当前提交)。
  打包前会核对子模块提交号和 `baserust/Cargo.lock` 一致,不一致就停下 —— 先 `git submodule update` 对齐。
- 部署包里有 `VERSION`:总仓库和各子模块的提交号;带着没提交的改动打包会标出来(这种包没法从仓库复现)。
- 自动模式比的是「上次导出的」,不是「服务器上的」:打了包就要把那次的 `update/` 部署上去。
  跳过了某次部署,就用 `build.sh <服务名>` 补导出服务器缺的,拿不准就 `--all`。
- `prod/images/` 保留全部镜像,是下次比较的基准,别删。

## 部署做了什么(deploy.sh,由 .run 自动调用)

1. 检查:root 用户(私钥要改属主给容器用户)、docker、compose ≥ 2.20、包是否完整、`.env` 里有没有没改的 `CHANGE-ME`。
2. 载入 `images/` 里有的镜像(没有的沿用服务器上已有的;服务器上也没有就会在启动时报错停下)。
3. 把 compose、`.env`、nginx 配置、密钥、超管账号文件、建库脚本装到 `DEPLOY_DIR`(默认 `/opt/<项目名>/prod`)。
   私钥和超管账号文件只给容器用户(uid 10001)读。
4. 先起 pg,执行建库脚本补齐各 schema 的 role:initdb 只在空卷首次启动时跑,后来新加的 schema 靠这一步补上;
   密码按 `.env` 重设(`.env` 是密码的唯一来源)。
5. `up -d --wait`:迁移是一次性任务,app / idm 等它成功才启动;全部健康才算部署成功,失败会打印状态和日志。
6. nginx 配置变了(或 nginx 没在跑)就强制重建 nginx —— 单文件挂载的配置改了,compose 自己看不出来。
7. 清理被新镜像顶替的旧镜像。

数据全在 `DEPLOY_DIR/data/`(postgres / minio / nats),部署只换镜像和配置,不动数据。

服务器上手动操作 compose:

```bash
cd /opt/<项目名>/prod
docker compose -p <项目名> -f docker-compose.prod.yml -f compose.web.yml ps
docker compose -p <项目名> -f docker-compose.prod.yml -f compose.web.yml logs -f app
```

## HTTPS

nginx 只服 HTTP。HTTPS 和域名由前面的 1Panel / LB 负责:把域名反代到 `http://127.0.0.1:<端口>`,
网站配置里加 `client_max_body_size 50m;`(上传文件)。后端 cookie 带 `Secure`,**必须经 HTTPS 访问才能登录**。
HSTS 也在 1Panel 那一层开(确认整站都走 HTTPS 之后);其余安全响应头(防嵌入、nosniff、CSP 等)nginx 已经加了。
`.env.prod` 默认 `TRUSTED_PROXY_HOPS=2`(1Panel / LB → nginx → app 两层,取到的才是真实客户端 IP):
nginx 的端口要用防火墙 / 安全组挡住公网、只让外层代理访问;nginx 直接对公网时改成 1。
部署前想先验证:`ssh -L <本机端口>:127.0.0.1:<端口> <服务器>`,然后本机浏览器打开 `http://localhost:<本机端口>/health`。

## 数据迁移(旧服务器 → 新服务器)

前提:新服务器已经用部署包部署好(项目名相同)。脚本在本机 `prod/` 下(`migrate-export.sh` / `migrate-import.sh`)。

1. **旧服务器**:`bash migrate-export.sh`(有多个项目时加目录参数,如 `bash migrate-export.sh /opt/shop/prod`)
   - 停掉 app / idm / web / nginx 并**保持停止**,网站从这时起不可用。
   - 导出整库(含各表精确行数)和 MinIO 文件,写到 `/opt/<项目名>-migrate/<项目名>-data.tar`。
   - 回滚:进项目目录 `docker compose -p <项目名> -f docker-compose.prod.yml -f compose.web.yml up -d`。
2. 把 `<项目名>-data.tar` 传到新服务器的 `/opt/<项目名>-migrate/`(或和导入脚本放同一目录),**文件名不能改**。
3. **新服务器**:`bash migrate-import.sh`
   - 校验文件 → 停 app 等 → 清空并整库恢复 → **逐表核对行数** → 替换 MinIO 文件 → 启动并等健康检查。
   - 任何一步不通过就停下,app 保持停止,不会带着不完整的数据启动。可以重复执行。
   - 空间:导出要数据量 2 倍、导入要 3 倍的空闲空间。
4. 验证后切 DNS。JWT 密钥和旧服务器不同的话,所有人需要重新登录一次。

不迁移 NATS:里面只是已经落库事件的副本,发件箱表才是源头。

## 本机验证过的

在 Docker 虚拟机里模拟服务器(Linux 文件系统、docker CLI 容器挂 docker.sock)跑过:全新数据卷首次部署、
再次部署(升级:只重跑迁移,其余服务不动,nginx 不重建)、导出 → 删数据 → 导入(29 张表行数一致,
MinIO 文件可下载)、经 nginx 登录和调后台接口(app 汇总 idm 的监控数据)。
