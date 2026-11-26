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
- **底座升级加了新配置项**(如多租户拆出的 `*_DB_OWNER_*` / `*_DB_SYSTEM_*` 数据库账号):`--add-missing`
  只把模板里有、`.env.prod` 里没有的键追加进去(`CHANGE-ME` 换成随机值),已有的密码一个不动;然后重新打包部署。

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

1. 检查:root 用户(私钥要改属主给容器用户)、docker、compose ≥ 2.20、包是否完整、`.env` 里有没有没改的 `CHANGE-ME`、
   有没有多租户新加的 owner / system 账号密码(老的 `.env.prod` 没有 → 本机 `init.sh --add-missing` 补)。
2. 载入 `images/` 里有的镜像(没有的沿用服务器上已有的;服务器上也没有就会在启动时报错停下)。
3. 把 compose、`.env`、nginx 配置、密钥、超管账号文件、建库脚本装到 `DEPLOY_DIR`(默认 `/opt/<项目名>/prod`)。
   私钥和超管账号文件只给容器用户(uid 10001)读。
4. 先起 pg,执行建库脚本补齐各 schema 的 role:initdb 只在空卷首次启动时跑,后来新加的 schema 靠这一步补上;
   密码按 `.env` 重设(`.env` 是密码的唯一来源)。接着(**迁移之前**)做多租户的账号拆分
   (`10-tenancy-roles.sh`):app / content / search 各拆成 owner(迁移、拥有表)/ 运行时(只有 DML)/
   system(BYPASSRLS,后台任务);老库里的表从运行时账号转给 owner,数据不动,可重复执行。
5. `up -d --wait`:迁移是一次性任务,app / idm 等它成功才启动;全部健康才算部署成功,失败会打印状态和日志。
6. nginx 配置变了(或 nginx 没在跑)就强制重建 nginx —— 单文件挂载的配置改了,compose 自己看不出来。
7. search 读模型为空就回填:有账号但账号目录空、或有成员关系但成员索引空(从多租户之前的版本升级后第一次部署)
   → 用同一镜像跑一次 `rebuild_search`(幂等)。`DEPLOY_REBUILD_SEARCH=1` 强制跑(投影漂移时用)。
8. 清理被新镜像顶替的旧镜像。

数据全在 `DEPLOY_DIR/data/`(postgres / minio / nats),部署只换镜像和配置,不动数据。

### 从多租户之前的版本升级

老库升级照常是「本机重新打包 → 服务器执行部署包」,但第一次要多做 / 知道几件事:

1. **本机先补配置**:`./scripts/prod/init.sh --add-missing` —— 把 owner / system 六个数据库账号密码
   (`{APP,CONTENT,SEARCH}_DB_{OWNER,SYSTEM}_PASSWORD` 等)补进 `.env.prod`,已有的密码不动。不补的话 deploy.sh 第 1 步就停下。
   然后 `./scripts/prod/build.sh` 重新打包(镜像、建库脚本都变了)。
2. **账号拆分在迁移之前**(deploy.sh 第 4 步自动做):老库里的表归运行时账号,`10-tenancy-roles.sh` 把它们转给
   `<schema>_owner`,再给运行时 / system 账号授 DML。顺序反了(先迁移):迁移用 owner 账号连库,这时它还不存在 /
   不拥有老表,迁移失败。
   本机开发库同理:先 `just db-ensure-roles`,再 `just migrate`。
3. **迁移**把旧数据归进默认组织(`default`,id `00000000-0000-0000-0000-000000000001`):全部存活账号成为它的成员、
   原有角色复制成它的成员角色,超管在里面兼任管理员;widget、content 的旧行回填 `tenant_id` = 默认组织
   (content 旧行不论原来存的 `tenant_id` 是什么 —— 旧接口原样收客户端传的值 —— 一律归默认组织)。
   老账号登录后直接进默认组织,看到原来的数据。
4. **search 回填**:deploy.sh 第 7 步自动跑 `rebuild_search`(成员索引在迁移后是空的)。回填前的几秒里后台「成员」列表是空的。
5. **旧头像修复**:app 进程**每次启动**都会把「资料里引用着、但还在默认组织里」的头像 content 转成个人内容
   (幂等,已转过的跳过;`seed` 命令也会做)。它用 content 的 system 账号(`content_system`,BYPASSRLS)**改** content 各表,
   需要的 UPDATE 权限由 `10-tenancy-roles.sh` 授(system 账号对 schema 里全部表有 DML);自己改过授权的库要确认还在,
   否则 app 启动失败。
6. 升级前登录的会话:迁移 0004 把**仍有效**(未吊销)的旧 refresh 会话归进默认组织(账号是它的 active 成员时),
   刷新后直接进默认组织,不用重新登录。旧 access token(没有租户 claim)在过期前(≤ access token 有效期)仍能验,
   读出来是平台上下文:这段时间里组织内的页面会显示「选择组织」(选默认组织即可),等 token 刷新后自动恢复。
   已吊销 / 已软删账号的会话不回填。
7. **迁移和旧容器有一小段重叠**:第 4 步拆账号、第 5 步 `up -d` 里 migrate 先跑完,app / idm 才被换成新容器 ——
   迁移(给业务表开 RLS)执行时旧的 app / idm 还在服务。旧代码不设租户上下文,开了 RLS 的表对它读出来是空的、
   写入被拒,直到新容器起来(通常几十秒)。
   能接受这个窗口就照常部署;不能接受就在服务器上先停 app / idm 再部署
   (`docker compose -p <项目名> -f docker-compose.prod.yml -f compose.web.yml stop app idm`,deploy.sh 会把它们重新拉起)。

**成员角色变更何时生效**(平时也适用):角色在 access token 的 claim 里,app 进程只验 token、不查 idm 库。
后台改了某成员的租户角色 / 平台角色,对方**下一次刷新 token** 才拿到新角色 —— 最长一个 access token 有效期
(`IDM_ACCESS_TTL_SECS`,生产默认 180 秒)。停用 / 移出成员同理:会吊销他在该组织的会话(下次刷新失败),
但已签发的 access token 在有效期内仍可用。需要更短的窗口就调小 `IDM_ACCESS_TTL_SECS`。


### 升级到「superadmin 独占 + 平台管理员」(2026-11-26)

角色变成 4 级:superadmin(**只能有一个**)/ platform_admin 平台管理员 / 组织 admin / user;系统监控、登录日志、
任命平台管理员是 superadmin 独占。权限映射不用迁移:启动时自动给 superadmin 补上新权限、建好 platform_admin。

**清理多余的 superadmin**:以前 superadmin 能在后台把 superadmin 授给别人,现在任何接口都撤不掉它。
idm(或单体)进程启动时检查,库里持 superadmin 的存活账号多于一个就**拒绝启动**,日志里列出这些用户名。
先决定保留哪一个,然后在服务器上:

```bash
cd /opt/<项目名>/prod
docker compose -p <项目名> -f docker-compose.prod.yml -f compose.web.yml exec -T pg sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
```

```sql
-- 1. 看谁持有 superadmin
SELECT u.username, ur.granted_by, ur.granted_at
FROM idm.user_roles ur
JOIN idm.roles r ON r.id = ur.role_id AND r.name = 'superadmin' AND r.deleted_at IS NULL
JOIN idm.users u ON u.id = ur.user_id AND u.deleted_at IS NULL;

-- 2. 只保留一个:把 <保留的用户名> 换成要留下的那个,删掉其余账号的 superadmin 授予(账号本身不动)
DELETE FROM idm.user_roles ur
USING idm.roles r, idm.users u
WHERE ur.role_id = r.id AND r.name = 'superadmin'
  AND ur.user_id = u.id AND u.username <> '<保留的用户名>';
```

然后重新部署 / 启动。直接改库不发事件,后台「账号」列表的角色列会停在旧值:跑一次 `rebuild_search`
(命令见上面 deploy.sh 第 7 步的报错提示)。被去掉 superadmin 的人要继续当平台管理员,由 superadmin 在后台「账号」页任命。

**回滚到这之前的版本**:旧版本读到不认识的权限串会**拒绝启动**(role_permissions 里有 ops:read 等)。
回滚前在同一个 psql 里删掉新权限的映射和 platform_admin 的行:

```sql
DELETE FROM app.role_permissions
WHERE permission IN ('ops:read', 'audit:read', 'platform:roles') OR role_name = 'platform_admin';
DELETE FROM app.permissions WHERE key IN ('ops:read', 'audit:read', 'platform:roles');
```

(被任命为平台管理员的账号在旧版本里没有任何权限;idm 里的 platform_admin 角色行留着不影响旧版本。)

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
     (这是回滚这次导出;回滚**程序版本**到「平台管理员」之前,先看上面「升级到 superadmin 独占 + 平台管理员」里的回滚 SQL。)
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
