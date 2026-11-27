# 多租户提交复审与修复报告（2026-11-27）

分支：5 个仓库都在 `fix/multi-tenant-review`（从 rust-idm 9255b77 / rust-content 7f554b9 / baserust a21daaf / basereact d090823 / stack 973a10a 切出）。
2026-11-27 按用户要求提交、快进合并到主分支并推送。

## 流程
1. 6 路只读复审（idm / content / baserust 数据层 / baserust 接口层 / basereact / 部署脚本）。
2. 5 路修复，每条先写会失败的测试再修。
3. 终审 → 二轮修复 → 复核 → 三轮修复，最后主控整体重跑全部测试。

## 修了什么（按严重度）

### 高
- **basereact 切换组织后页面仍显示旧组织数据，写操作会以新组织身份打到旧行**：`clear()` 改成 `resetQueries()`；后台页面区按「账号 + 组织」加 key，切换时整页重新挂载；新增 `src/lib/session-sync.ts`，取代 tenant-sync。
- **seed 补授前校验密码会让 idm 起不来**（这是一轮修复引入的，终审发现）：改成校验不过就记日志并跳过这个账号的补授，不拦启动。库里一个 superadmin 都没有时记 ERROR。密码哈希解析失败也按跳过处理。

### 中
- **rust-idm**
  - 成员 add 会把已软删账号加进去：现在返回 NotFound，成员列表和 total 也排除已删账号。
  - 平台账号列表会命中迁移遗留在 user_roles 里的组织角色：现在只看平台角色。
- **baserust**
  - `PUT /frontend/profiles/{id}` 能让 platform_admin 改 superadmin 的资料：改别人资料现在要 `platform:roles`，OpenAPI 用 `x-conditional-scopes` 标明。
  - superadmin 改用户名后 idm 起不来：seed 现在识别声明已过时，记日志并跳过。
- **前端**
  - 登录、登出、注册、改密码不会通知其他标签页：现在统一广播「会话已变更」。
  - 改密码 / 注销时密码输错被当成会话过期：后端新增 401 错误码 `invalid_credentials`，拦截器遇到它直接把错误交给调用方。
- **部署**
  - `deploy.sh` 判断是否回填搜索索引有竞态：改成在迁移前探测是否从旧版本升级，探测到就先停 app / idm，并写标记文件，按标记执行 rebuild_search；回填失败时标记保留，下次部署再跑。
  - `10-tenancy-roles.sh` 每次部署都把收紧过的权限授回去、schema 名写死成 `search`：现在只给本次转了属主的对象补授，收回范围按参数传入，每个 schema 包成一个事务。
  - README 的回滚 SQL 对这次升级不成立：改成升级前停服，备份 pg、minio、nats；回滚 = 恢复备份。
  - superadmin 清理步骤补写：必须保留 seed 里声明的那个账号。
- **0004 down 迁移**：回写前先对账，被撤权、停用、移出的人回滚后不会复活。

### 低
- **rust-idm**：refresh / switch_tenant 改为原子撤销 refresh 会话，同一个 token 并发使用不会再分出两个会话。
- **rust-content**
  - `scoped_tx` 同时清掉另一个作用域的变量。
  - 调用方给的 object_key 必须带本作用域前缀，并且不许有 `..` 段。
  - 建对象时父行加 FOR SHARE，挡住并发软删。
  - 补了两个租户只靠 RLS 隔开的测试。
- **baserust**
  - superadmin 不能 `DELETE /auth/me`。
  - put_member 先确认账号存活。
  - rls_audit 增加策略谓词检查和角色成员关系检查。
  - 新增 OpenAPI 防表腐测试。
- **stack**
  - justfile 新增 `db-ensure-roles`；读 `.env.compose` 不再吃掉值末尾的 `=`；缺省账号名和 compose 一致；值里有 `$` 时报错。
  - 生产 token 有效期统一写成 180 秒，代码默认 900 秒。

## 有意不改，只写进文档
- content 迁移 0003 会把旧行的 updated_at 改成升级时刻（已执行的 up 迁移不能改）。
- platform_admin 停用某组织时，会连 superadmin 在该组织的会话一起吊销（superadmin 能从平台上下文重新进入）。
- 已拆过账号的库上，改了 `*_DB_SYSTEM_USER` 或重建 system 账号后，老表需要手动 grant（文档给了 SQL）。
- app 迁移 0007 的平台权限清单少 3 项（都是同一版本新加的权限，无影响；已执行的迁移不能改）。

## 契约变化（提交前要知道）
- **rust-idm**：`SessionRepo::revoke` 的返回值改成 `bool`，改密码 / 注销密码错时返回 `InvalidCredentials`。这是破坏性改动，建议发 0.7.0。
- **rust-content**：显式给的 object_key 必须带作用域前缀。baserust 只传 None，不受影响。
- **HTTP**：登录、改密码、注销密码错时返回 401 `invalid_credentials`（以前是 `unauthorized`）；未登录或会话失效仍是 `unauthorized`。
- - **已提交并推送（2026-11-27）**：rust-idm 00f4e4d、rust-content fa3e600、baserust 857f671（按这两个提交号钉依赖）、basereact 7d67992，stack 见本次提交。库都没打 tag。

## 验证（主控最后一次整体重跑，全部通过）

| 仓库 | 结果 |
|---|---|
| baserust | 全量测试 554；PG 测试 45；NATS 6；search 投影和 durable 两个端到端测试；clippy -D warnings 0 警告；fmt 干净 |
| rust-idm | 51 个单元 / 契约测试；PG 38；clippy 0 警告；fmt 干净 |
| rust-content | 29；PG 21；clippy 与 fmt 干净 |
| basereact | tsc 通过；lint 0 error（6 个 warning 是改动前就有的）；38 个文件 227 个测试 |
| stack 脚本 | `tenancy-roles.test.sh`、`deploy-rebuild-search.test.sh`、`db-ensure-roles.test.sh` 全部通过；nginx 漂移检查通过 |

新增的 3 个 shell 测试还没接进 CI（CI 需要起一个 postgres service）。
