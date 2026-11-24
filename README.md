# baserust-stack

baserust 全家桶的总仓库：用 git submodule 把五个独立仓库挂在一起，固定「这一组版本能一起跑」，并提供一个 VS Code 多根工作区。

本仓库**不放业务代码**，只有指针（`.gitmodules` + 各子模块的提交号）、工作区文件和这份说明。各仓库照旧独立开发、独立发版。

## 成员

| 目录 | 仓库 | 跟踪分支 | 角色 |
|---|---|---|---|
| `baserust/` | [baserust](https://github.com/GGGLHHH/baserust) | `master` | 后端脚手架（axum + sqlx + utoipa） |
| `rust-idm/` | [rust-idm](https://github.com/GGGLHHH/rust-idm) | `main` | 认证 / IDM 领域库（零 HTTP） |
| `rust-content/` | [rust-content](https://github.com/GGGLHHH/rust-content) | `master` | 内容 / 对象存储领域库（零 HTTP） |
| `basereact/` | [basereact](https://github.com/GGGLHHH/basereact) | `master` | 前端（TanStack Start + React） |
| `cadenza/` | [cadenza](https://github.com/GGGLHHH/cadenza) | `master` | 组件库，发布为 npm `@gedatou/cadenza-*` |

## 依赖关系

```
basereact ──npm ^x.y──▶ cadenza            (@gedatou/cadenza-ui / -form / -utils)
basereact ──OpenAPI───▶ baserust           (vite dev 代理 + codegen 读 /api-docs/openapi.json)
baserust  ──git tag───▶ rust-idm           (Cargo.toml: idm = { git, tag })
baserust  ──git tag───▶ rust-content       (Cargo.toml: content = { git, tag })
```

子模块只负责「放在一起、版本对齐」，**不改变上面的依赖方式**：baserust 构建时仍从 GitHub 按 tag 拉 idm / content，basereact 仍从 npm 装 cadenza。

## 一键启动（Docker）

```bash
docker compose up -d --build      # 首次要编译 Rust release 镜像，约 10–20 分钟
```

起来后浏览器打开 <http://localhost>（端口见 `NGINX_PORT`），开发默认账号见 `baserust/seed.toml`（如 `superadmin` / `pwd`，仅开发用）。

| 入口 | 地址（默认端口） |
|---|---|
| 前端 + API（同源，经 nginx） | <http://localhost> |
| app 直连 / idm 直连 | <http://localhost:6453> / <http://localhost:6454> |
| API 文档（Scalar，dev 才挂） | <http://localhost:6453/docs> |
| Postgres | `localhost:5821` |
| MinIO 控制台 | <http://localhost:9863> |
| dbhub MCP | <http://localhost:3777> |

组成：

- `compose.yaml` 用 `include` **原样复用** `baserust/docker-compose.yml`（pg / migrate / nats / minio / app / idm / nginx / dbhub），不复制、不改它；只额外加一个 `web` 服务（`basereact/Dockerfile`，TanStack Start SSR）。
- `deploy/baserust.override.yml` 把 nginx 的配置换成 `deploy/nginx.conf`：和 `baserust/nginx.conf` 完全相同，只有 `location /` 从 404 改成反代到 `web`。前端和 `/api` 同源，httponly cookie 不跨域。
- 端口、凭据在 `.env.compose` 里改（或用同名环境变量临时覆盖）。后端 `${VAR}` 只从这份取，不读 `baserust/.env`（那份给本机 `just dev` 用）。

baserust 改了 `nginx.conf` 之后，跑一下 `bash scripts/check-nginx-drift.sh` 看 `deploy/nginx.conf` 要不要同步。

停止：`docker compose down`（保留数据卷）；连数据一起清：`docker compose down -v`。

### 生产部署

单机 docker compose,一键离线部署:本机 `just prod-init --name <项目名> --port <端口>`(只做一次,生成随机密码和密钥)→ `just prod-build --all`(构建并导出镜像、生成部署包)→ 把 `prod/update/` 传到服务器,执行里面的 `.run`。升级只重复后两步;换服务器有数据迁移脚本。详见 [scripts/prod/README.md](scripts/prod/README.md)。

### 用底座起新项目

`just new-project <项目名>` 建项目自己的总仓库、后端、前端(带着底座的历史);之后底座有更新,在项目里 `just sync-base` 合并过去。怎么改才好同步、冲突怎么处理,见 [docs/new-project.md](docs/new-project.md)。

### 只起基础容器，后端 / 前端本机跑

```bash
just infra                 # = docker compose up -d pg migrate minio minio-init nats dbhub
cd baserust  && just dev   # 后端 :8137（读 baserust/.env，从 .env.example 复制）
cd basereact && pnpm dev   # 前端 :7621（读 basereact/.env，/api 代理到 :8137）
```

`baserust/.env.example` 里的端口（pg 5821、minio 9862、nats 2224）和 compose 的默认端口一致，复制成 `.env` 就能连上。改了 `.env.compose` 里的端口，记得同步改 `baserust/.env`。

`just` 的其他目标：`just up`（整栈）、`just ps`、`just down`。

> 前端改完要看效果，日常更快的是本机 `pnpm dev`（见下文「本地联调」）；compose 适合整栈验收、给别人演示。

## 拉取

```bash
git clone --recurse-submodules https://github.com/GGGLHHH/baserust-stack.git
# 已经 clone 过但子目录是空的：
git submodule update --init
```

子模块 URL 用的是相对路径（`../baserust.git`），走 HTTPS 还是 SSH 跟着总仓库的 remote 走。

然后用 VS Code 打开 `baserust-stack.code-workspace`。

## 日常操作

子模块被 checkout 出来时处于 **detached HEAD**（固定在某个提交上）。要在里面改代码，先切回分支：

```bash
cd rust-idm
git switch main          # 各仓库的分支见上表
# …改代码、提交、推送到 rust-idm 自己的远端…
```

**子仓库提交之后，总仓库要再提交一次新指针**，否则别人拉总仓库拿到的还是旧版本：

```bash
cd ..                    # 回到 baserust-stack
git add rust-idm
git commit -m "chore(rust-idm): bump to v0.6.0"
```

把所有子模块一次性更新到各自跟踪分支的最新提交：

```bash
git submodule update --remote
git status               # 看哪些指针动了，确认能一起跑后再提交
```

建议在本机打开递归，`git pull` / `git switch` 时会顺带更新子模块：

```bash
git config submodule.recurse true
```

## 本地联调

### 后端改库（baserust ↔ rust-idm / rust-content）

baserust 默认按 git tag 依赖两个库，**不会**用到这里的本地目录。要连库一起改，临时把 `baserust/Cargo.toml` 改成 path 依赖：

```toml
idm     = { path = "../rust-idm" }
content = { path = "../rust-content" }
```

目录结构是并排的，相对路径正好对得上。注意：

- path 依赖期间 `docker compose build` 不可用（路径在构建上下文之外）。
- 联调完成后：库先打新 tag、推送，baserust 再改回 `{ git, tag = "新 tag" }`，最后总仓库提交两边的新指针。**别把 path 依赖提交进 baserust。**

### 前端连后端（basereact ↔ baserust）

basereact `.env` 里的 `BACKEND_ORIGIN` 要和 baserust `.env` 的 `BIND_ADDR` 一致（默认 `8080`），否则 dev 代理和 `pnpm generate` 都会打空。

### 前端改组件库（basereact ↔ cadenza）

basereact 从 npm 装 cadenza。要试未发布的改动，可以在 basereact 里临时用 `pnpm link ../cadenza/packages/ui`（form / utils 同理），试完 `pnpm unlink` 并恢复 `package.json` / lockfile。正式使用仍以 cadenza 发版到 npm 为准。

## 版本对齐

总仓库每个提交 = 一组已知能一起工作的版本。提交指针前至少确认：

- baserust `Cargo.toml` 里锁的 idm / content tag，与 `rust-idm/`、`rust-content/` 指向的提交一致（或更新）。
- basereact `package.json` 里的 cadenza 版本范围，覆盖了 `cadenza/` 当前发布的版本。
