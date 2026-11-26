# 单机多租户设计

> 状态：草稿，待用户审阅。日期：2026-11-25。
> 调研依据：`docs/research/reports/多租户架构业内做法.md`（下称「调研报告」）。
> 涉及仓库：rust-idm、rust-content、baserust、basereact（cadenza 不动）。

## 1. 为什么做、做成什么样

baserust 现在是「一个项目一套部署」，代码里是单租户：账号、角色、业务数据都不分组织。要支持**一套实例同时服务多个互相隔离的组织（租户）**，一个人可以同时属于多个组织，登录后在组织之间切换。

用户已定的三件事：

1. 单机、一套实例服务多个租户（不是每个租户一套部署）。
2. 一个账号可以属于多个租户。
3. 数据隔离用做法 A：共享表 + 仓储显式传租户 + PostgreSQL 行级安全（RLS）兜底。

### 目标

- 租户之间的业务数据互相看不见、改不了；漏写一个过滤条件也不会串数据（数据库层兜底）。
- 一个账号可以加入多个租户，各租户内角色不同；切换租户不用重新输密码。
- 平台管理员（跨租户）和租户管理员（只管本租户）分两层。
- 用底座起的单租户项目**登录和日常使用不变**：只有一个默认租户，登录直接进入，不显示租户切换器。不加单/多租户配置开关（用户定）：后台会多出平台管理员的「租户管理」菜单，「用户」页变成「成员」页，这是接受的变化。
- 已有项目同步底座后，现有数据自动归入默认租户，不丢数据。

### 不做（这一期）

- 子域名、自定义域名识别租户（租户只从 token 来）。
- 租户自定义角色（角色全局定义，在成员关系上授予）。
- 按租户限流、配额、计费。
- 监控页按租户拆分（监控仍是平台级）。
- 租户硬删除、单租户数据导出（只做停用）。
- SSO、SCIM、MFA。
- 停用租户或移除成员「秒级生效」（见 §4.6，上限是 access token 有效期）。
- MinIO 替换、按租户下发对象存储凭证。

### 绝不能出现（做出来也算失败）

- 代码里取不到租户时**悄悄落到默认租户**或 nil。缺租户必须报错或查不到数据。
- 任何业务表出现 `tenant_id = 00000000-0000-0000-0000-000000000000`。
- 运行时连库的账号能绕过 RLS（是表 owner、superuser 或带 BYPASSRLS）。
- 为了做租户而跨 schema join，或让 app 进程去查 idm 库。
- 单租户项目登录多一步，或者普通用户界面出现租户元素。

## 2. 方案取舍

| 做法 | 说明 | 结论 |
|---|---|---|
| **A. 应用层过滤 + RLS 兜底** | 每个仓储方法显式收 `TenantId`、SQL 写 `where tenant_id`；PG 实现在方法自己的事务里 `set_config('app.tenant_id', …, true)`，表上 RLS 策略兜住漏写 | **用户选定** |
| B. 只做应用层过滤 | 不拆 PG 账号、不写策略，靠参数和测试 | 没选：sqlx 是手写 SQL，没有 ORM 自动过滤，漏一个条件就串数据 |
| 每租户一个 schema / 库 | — | 排除：单机拿不到按租户恢复、独立资源的好处，迁移要按租户数重复跑（调研报告第二节） |
| 租户身份放 baserust | — | 排除：签 token 的是 idm，app 不查 idm 库；放 app 会破坏 app/idm 分库隔离 |

## 3. 约束（现有架构不变）

- 六边形分层、核心 crate 无基础设施依赖、`tests/architecture.rs` 的规则照旧。
- 禁跨 schema join；跨模块引用用标识不用外键。
- app 进程只验 JWT，不查 idm 库。
- 「一个原子单元 = 一个 trait 方法，事务不进签名」（transactions skill）。
- 每个仓储都有内存实现和 PG 实现，conformance 测试对拍。
- 写操作 PUT 全量替换、禁 PATCH；新接口要有黑盒测试并登记 `covers:`；OpenAPI 快照随代码评审。
- 库（rust-idm、rust-content）按 git tag 发版，baserust 升 tag。
- 用底座起的项目靠 `sync-base.sh` 合并更新，迁移必须能在已有数据上跑。

## 4. 设计

### 4.1 身份模型（rust-idm）

新增三张表（idm schema）：

| 表 | 字段要点 |
|---|---|
| `tenants` | `id` uuid v7、`slug`（唯一，**删除后也不复用**）、`name`、`status ∈ {active, suspended}`、审计字段、`deleted_at` |
| `tenant_members` | `(tenant_id, user_id)` 主键、`status ∈ {active, inactive}`、`last_used_at`、`added_by`/`added_at` |
| `member_roles` | `(tenant_id, user_id, role_id)`，外键到 `tenant_members` 和 `roles` |

- 账号（`users`）保持全局，用户名、邮箱仍全局唯一。
- `roles` 仍是全局角色目录。角色分两类：**平台角色**（经 `user_roles` 授予，如 superadmin）和**租户角色**（经 `member_roles` 授予，如 admin、user）。同一个角色名只属于一类，由代码闭集 `RoleName` 标明。
- `sessions` 加 `tenant_id`（可空：空 = 平台上下文，见 §4.2）。
- 新增仓储端口 `TenantRepo`、`MemberRepo`，内存 + PG 两套实现，并进 idm 的 conformance 契约。
- idm 表**不开 RLS**：idm 是身份权威，登录时本来就要跨租户查「这个人属于哪些租户」。

新增 outbox 事件（供 search 投影等消费）：`tenant.created`、`tenant.updated`（含 status）、`tenant.member_added`、`tenant.member_removed`、`tenant.member_roles_set`。现有 `user.*` 事件不变。

### 4.2 登录、切换、token

**token 形状**（`TokenClaims` / `AppClaims` / `VerifiedToken` / `AuthUser` 同步扩展）：

| claim | 含义 |
|---|---|
| `roles` | 平台角色（含义从「全部角色」收窄为「平台角色」） |
| `tenant_id` | 当前租户；平台上下文时缺省 |
| `tenant_roles` | 当前租户内的角色 |

access token 只放**一个当前租户**，不放全部租户列表。

**登录流程**（不改登录表单，不加租户输入框）：

```
账号密码通过
 ├─ 有 active 成员关系 → 进入 last_used_at 最近的那个租户
 └─ 没有 → 平台上下文（tenant_id 为空，只有平台角色）
           ├─ 有平台角色 → 正常进入（平台管理界面）
           └─ 没有 → 前端显示「还没加入任何组织」
```

只计算 `tenant.status = active` 且 `member.status = active` 的成员关系。

**切换租户**：新增 `POST /api/v1/frontend/auth/switch-tenant`（body：`tenant_id`）。idm 校验成员关系和租户都 active → 吊销当前 session → 建新 session（带新 `tenant_id`）→ 写 cookie，更新 `last_used_at`。平台管理员切进一个自己不是成员的租户**不允许**（要管理别的租户走平台接口，见 §4.5）。

**我的租户列表**：新增 `GET /api/v1/frontend/auth/tenants`，返回当前账号 active 的成员关系（id、name、slug、我的租户角色、是否当前）。

**refresh**：沿用 session 上的 `tenant_id`，重新读成员关系和租户角色；成员关系或租户已不 active → refresh 失败（401），前端回登录页。

**后台登录**（`/admin/auth/login`）：同样流程；准入判断改为「当前租户角色或平台角色里有后台权限」。

### 4.3 授权（baserust）

- 核心 kernel 新增 `TenantId` newtype：构造时拒绝 `Uuid::nil()`；序列化为普通 uuid。
- `Perm` 闭集每个变体标明作用域：**租户级**（widget、content、成员管理、审计查看等）或**平台级**（租户管理、系统监控、账号管理）。
- 有效权限 = 平台角色给的平台级权限 ∪ 当前租户角色给的租户级权限。平台角色**不自动**获得任何租户的租户级权限。
- 新增提取器 `CurrentTenant(TenantId)`：从 token 取；没有当前租户时返回 403，错误码 `tenant_required`。租户级接口一律用它，**不接受**请求体或查询参数里的 `tenant_id`（content 现有的可选 `tenant_id` 字段删除）。
- 跨租户访问别的租户的资源 ID → 404（按 authorization skill 的口径，不泄露存在性）。
- `Actor` / `AuditContext` 带上 `tenant_id`；认证中间件把 `tenant_id`、`user_id` 写进 tracing 根 span。
- `GET /permissions/me` 返回里加当前租户信息。

### 4.4 数据隔离（baserust、rust-content）

**哪些表加 `tenant_id uuid not null`**：

| schema | 表 | 说明 |
|---|---|---|
| app | widgets、widget_tags | 唯一索引 `widgets_name_unique_alive` 改为 `(tenant_id, name)` |
| content | content（已有列）、content_metadata、object、object_metadata、content_derived | 每张表都带列，策略不靠子查询 |
| search | admin_user_index | 改为租户成员索引，主键 `(tenant_id, user_id)` |
| search | auth_event | 加 `tenant_id`（可空：登录失败等事件没有租户） |

**保持全局、不开 RLS 的表**：app.permissions、app.role_permissions、**app.profiles**（资料全局一份，用户定，见 §6.2）、所有 outbox 表（payload 里带 tenant_id）、ops.*、idm.*。这些表列进代码里的「全局表白名单」。

**所有业务表加** `CHECK (tenant_id <> '00000000-0000-0000-0000-000000000000')`。

**RLS 策略**（每张业务表）：

```sql
alter table widgets enable row level security;
alter table widgets force row level security;
create policy tenant_isolation on widgets
  using      (tenant_id = nullif(current_setting('app.tenant_id', true), '')::uuid)
  with check (tenant_id = nullif(current_setting('app.tenant_id', true), '')::uuid);
```

没设 `app.tenant_id` 时查不到任何行、写不进任何行。auth_event 的策略额外允许「tenant_id 为空的行只给系统账号看」（见下面的账号拆分）。

**PG 账号拆分**（app、content、search 三个 schema；idm、ops 不变）：

| 账号 | 用途 | 属性 |
|---|---|---|
| `<schema>_owner` | 跑迁移，拥有表 | 不用于运行时 |
| `<schema>` | 运行时请求 | 只有 DML 权限，非 owner，NOBYPASSRLS |
| `<schema>_system` | 后台任务、平台级跨租户读 | BYPASSRLS，单独连接池 |

- `scripts/initdb/00-roles-schemas.sh`、`migrate-all.sh`、justfile 的迁移命令、`prod-init` 生成的随机密码、compose 的环境变量都要跟着改。
- 已有部署的升级：一个幂等的升级步骤，建新账号、`alter schema/table ... owner to <schema>_owner`、给运行时账号授 DML。由 `deploy.sh` 在迁移前执行。

**仓储写法**：

- 每个读写租户数据的端口方法签名带 `tenant: TenantId`。内存实现按它过滤（内存实现没有 RLS，参数是唯一防线）。
- PG 实现：方法内 `pool.begin()` → `select set_config('app.tenant_id', $1, true)` → 业务 SQL（**同时写** `where tenant_id = $1`，走索引）→ `commit`。读方法也一样。
- 提供一个 helper（如 `infra::pg::tenant_tx(&pool, tenant)`），rust-content 内部各写一份同样的 helper（库不依赖 baserust）。
- 不在借出连接时设会话级变量，避免以后加 PgBouncer 时串租户。

**rust-content**：

- 所有 service 和 repo 方法加 `tenant` 参数，按 ID 取单条的方法（`get_content`、`download_url` 等）都按租户过滤，查不到返回 NotFound。
- 新对象 key 改为 `tenants/{tenant_id}/{content_id}/{uuid}`。已有对象 key 存在库里，不搬家，照旧能读。
- **个人内容（头像）的特例**：资料是全局的，头像不属于任何租户。rust-content 的作用域做成枚举 `ContentScope::Tenant(TenantId) | ContentScope::Personal`：
  - 个人内容的 `tenant_id` 存 **NULL**（显式的「不属于租户」，和被禁止的 nil 不是一回事；content 各表的 `tenant_id` 因此改为可空，其他业务表仍 not null），对象 key 为 `personal/{owner_id}/{content_id}/{uuid}`。
  - RLS 策略在租户条件之外加一支：`tenant_id is null and current_setting('app.personal_scope', true) = 'on'`。仓储方法用 Personal 作用域时设 `app.personal_scope = on`，不设 `app.tenant_id`；租户作用域的请求看不到个人内容，反之亦然。
  - 个人内容的读写权限在 app 层判断：只有本人能上传、替换、删除；头像对已登录用户可读（和现在一样）。
  - 只有 profile 模块用 Personal 作用域，其他模块一律用租户作用域。
- 发新 tag，baserust 升版本。

**事件和后台任务**：

- outbox 信封加 `tenant_id`（idm 的 tenant.* 事件、app 的 profile.updated、widget 事件都带）。
- 投影器（search、auth_event）用 `_system` 账号写，按消息里的 `tenant_id` 落行。
- `WidgetEvent` 带 `tenant_id`，SSE 逐帧过滤时先比租户再比 owner；auth_event 的 SSE 同理。
- 保留期清理、`rebuild_search`、seed、mock 用 `_system` 账号。

### 4.5 管理功能

**平台管理员**（平台角色 superadmin）：

- 租户：新建、改名、停用 / 恢复、列表。
- 某个租户的成员：查看、添加已有账号为成员、移除、设置租户角色（用于给新租户指定第一个管理员）。
- 账号：现有的全局账号管理（新建、重置密码、删除）只给平台管理员。

**租户管理员**（当前租户里有成员管理权限）：

- 本租户成员列表（替代现在后台的「用户」页，数据来自租户成员索引）。
- **按用户名把已有账号加进本租户**（用户定）：输入完整用户名精确匹配，不提供模糊搜索全局账号。查不到时提示「账号不存在」——这会让租户管理员能确认某个用户名是否存在，接受这个代价（账号是平台管理员发的，用户名不算秘密）。
- 移出本租户、设置本租户内角色。
- 不能新建账号，不能改别人的密码、锁定或删除账号（账号是全局的，可能也属于别的租户）。新人的账号由平台管理员建，建好后平台管理员或租户管理员把他加进租户。

**公开注册**（`POST /api/v1/public/auth/register`）：注册成功后自动加入默认租户，角色 `user`；默认租户不存在或已停用时只建账号、不加入（我的判断：保持单租户项目注册后能直接用，不需要开关）。

接口路径（我的判断，可调整）：平台级挂在 `/api/v1/admin/platform/...`；租户级成员管理挂在 `/api/v1/admin/auth/members...`。

### 4.6 停用与生效时间

- 停用租户 / 移除成员 / 停用成员：idm 立即吊销相关 session，refresh 立刻失败。
- 已发出的 access token 在过期前仍有效，**最长延迟 = access token 有效期**（默认 900 秒，可用 `IDM_ACCESS_TTL_SECS` 调短）。
- 秒级生效（idm 事件投影到 app、中间件每次查）列为后续可选项。

### 4.7 默认租户与已有数据迁移

- 固定一个默认租户 UUID（常量，在 idm 和 app/content/search 的迁移里各写一份）。slug `default`，名称取项目名或「默认组织」。
- idm 迁移：建默认租户；把每个现有账号加为成员；现有 `user_roles` 里的租户角色（admin、user）搬到 `member_roles`，平台角色（superadmin）留在 `user_roles`。superadmin 同时加为默认租户的 admin，保证升级后还能用后台。
- 业务表迁移：加列 → 回填默认租户 UUID（content 里现有的 nil 也改成默认租户）→ `not null` + CHECK → 改唯一键 → 开 RLS。
- 单租户项目：只有一个默认租户，登录自动进入，当前账号只属于 ≤ 1 个租户时前端隐藏切换器。

**seed（初始数据）也要准备默认租户**（用户要求）：

- `seed.toml` 和 `seed.prod.toml.example` 新增租户段，至少声明默认租户（固定 UUID、slug `default`），以及每个账号在哪些租户里、是什么租户角色。示例：

  ```toml
  [[tenants]]
  slug = "default"
  name = "默认组织"

  [[users]]
  username = "superadmin"
  platform_roles = ["superadmin"]
  tenants = [{ slug = "default", roles = ["admin"] }]

  [[users]]
  username = "user"
  tenants = [{ slug = "default", roles = ["user"] }]
  ```

- seed 幂等：默认租户按固定 UUID upsert；成员关系和租户角色按声明补齐（取并集，和现在 `ensure_roles_with_event` 的做法一致），并发对应的 tenant.* 事件。
- 开发用的 `mock.toml` 可以再多建一两个演示租户和跨租户账号，方便本地试切换（非 prod 才有）。

### 4.8 前端（basereact）

- `team-switcher.tsx` 改成真实的组织切换器（数据来自 `GET /auth/tenants`，只有一个组织时不显示），**只放在后台**（侧栏、后台 403 页）。
- **前台不提供切换组织**（2026-11-26 用户定）：普通用户只在一个组织内；前台跟随当前组织（登录时决定，或在后台切换）。
  以后前台可能按域名或其他配置确定组织——到时由后端从请求解析组织，并校验「解析出的组织 == token 里的当前组织」，不一致按无权处理；前台仍不出现切换器。
  「还没加入任何组织」页里的组织选择保留（处在平台上下文、没有当前组织的账号要靠它进入）。
- 切换后清空全部查询缓存再重新进入当前路由，避免显示上一个租户的数据。
- 新页面：「还没加入任何组织」；平台管理员的租户管理页；后台「用户」页改为「成员」页。
- 重新生成 API 类型。

### 4.9 测试

- **跨租户黑盒测试**：租户 A 的 token 访问租户 B 的每类资源 ID → 404；列表里不出现 B 的数据。每个业务模块都要有。
- **RLS 审计测试**：查 `pg_class` / `pg_policies`，断言每张有 `tenant_id` 列的业务表都 ENABLE + FORCE 且有策略；断言运行时账号不是 owner、没有 BYPASSRLS。
- **PG conformance 用运行时账号跑**（不是 owner），这样 RLS 真的生效；加「不设 app.tenant_id 时查不到」的用例。
- conformance 契约加租户隔离用例，内存和 PG 都要过。
- 迁移测试：在有数据的旧库上跑迁移，数据全部归入默认租户，旧账号能登录、能看到原来的数据。
- `http_support` 的 `mint`、登录 helper、`TestServer` 增加租户参数；其余 `*_api.rs` 测试跟着改。

## 5. 建议的实施顺序

1. **rust-idm**：租户、成员、租户角色、session 租户、switch、默认租户迁移、新事件；发 tag。
2. **baserust 认证边界**：claims、`TenantId`、`CurrentTenant`、Perm 作用域、switch/tenants 接口、平台和租户管理接口；前端切换器。
3. **RLS 基础设施**：PG 账号拆分、升级脚本、`tenant_tx` helper、RLS 审计测试。
4. **baserust 业务表**：widget、profile、search、auth_event 加租户和策略，事件带租户。
5. **rust-content**：租户过滤、对象 key 前缀、RLS；发 tag，baserust 升级并删掉请求里的 `tenant_id`。
6. **前端管理页**：租户管理、成员页、空状态页。

每一步各自 `just check && just test && just lint` 通过。

## 6. 我的判断与待定问题

### 6.1 我替你定的（审阅时请核对）

- **已有下游项目**：RLS 审计用严格规则——app / content / search 里每张表要么按租户隔离（有 `tenant_id` + ENABLE + FORCE + 策略），要么列在代码里的显式「全局表白名单」里，否则测试失败。下游项目同步底座后测试会变红，这是有意的提醒；`docs/new-project.md` 补一节「同步多租户版本后要做的事」（自己的表加租户或进白名单、自己加的 RoleName 标明平台/租户、升级步骤里给运行时账号授 DML 并设 `ALTER DEFAULT PRIVILEGES`）。
- **多标签页**：当前租户放在共享 cookie 里，一个标签页切换，其他标签页跟着切。前端用 BroadcastChannel 通知其他标签页清缓存并刷新。不做「每个标签页各自一个租户」。
- **认证审计页**：这一期仍只给平台管理员（和现在一样，superadmin 才能看），走平台接口和 `_system` 连接池，能看到无租户的行。租户管理员自己的登录日志页列为后续。auth_event 的 `tenant_id` 先记上，方便以后做。
- **app 库里手工改过的角色→权限行**：新规则下，平台角色只取平台级权限、租户角色只取租户级权限；启动时发现某行映射跨了作用域，打 WARN 日志并忽略该行。

### 6.2 你已定的（2026-11-25）

1. **加人方式**：平台管理员建账号；租户管理员按用户名把已有账号加进本租户（§4.5）。
2. **不加单/多租户开关**：按数据决定显示什么；单租户项目后台多出租户管理菜单、「用户」页变「成员」页是接受的（§1）。
3. **资料全局一份**（GitHub 式）：profiles 不分租户，头像走 rust-content 的个人作用域特例（§4.4）。
4. **初始数据要有默认租户**：seed 声明默认租户和成员关系（§4.7）。

### 6.3 由此带出的我的判断

- 公开注册自动加入默认租户、角色 `user`（§4.5）。
- 租户成员索引（search.admin_user_index）里的显示名来自全局资料：收到 `profile.updated` 时更新该用户在所有租户里的索引行。

## 7. 2026-11-26 角色补充（superadmin 独占 + 平台管理员）

用户 2026-11-26 确认（原话「可以,开始把」）。本节优先于前文里「平台管理员 = superadmin」的说法。

**角色 4 级**

| 角色 | 作用域 | 说明 |
|---|---|---|
| `superadmin` 超级管理员 | 平台 | **只有一个**（用户本人）。只由 seed 声明；任何接口都授不出、也撤不掉；seed 声明给多个账号、或库里已有别的账号持有 → 启动 / seed 报错。 |
| `platform_admin` 平台管理员 | 平台 | 新增，可多个。superadmin 在后台「账号」页任命 / 撤销，或 seed 声明。 |
| `admin` 组织管理员 / `user` 普通成员 | 组织 | 不变。 |

**权限拆分**（`Perm` 闭集，都是平台级）

- `users:admin`：账号管理（建号、改账号信息、重置密码、删除、后台改资料）。
- `tenants:admin`：组织管理（开、停、改名、指定成员与组织管理员）。
- `ops:read`（新）：系统监控（实时、历史指标、日志查询）。
- `audit:read`（新）：认证审计（登录日志查询 / 统计 / 实时流、某账号的认证事件）。
- `platform:roles`（新）：授予 / 撤销平台角色（任命平台管理员），以及管理持有平台角色的账号。命名按用户原话保留（`resource:action` 里 action 不是动词，是唯一的例外）。

superadmin 默认 = 全部平台级权限（随闭集自动增长）；platform_admin 默认 = 全部平台级权限减去 `ops:read` / `audit:read` / `platform:roles`（代码常量 `SUPERADMIN_ONLY`）。

**superadmin 独占**：① 运维（系统监控页）② 认证审计（登录日志）③ 任命 / 撤销平台管理员 ④ superadmin 账号本身没人能改（它本人可以改自己的资料 / 密码，但去不掉自己的 superadmin、删不了自己）。

**防接管**：对**持有任一平台角色**的账号（superadmin、平台管理员，以及闭集外的平台角色名——fail-closed）做写操作，操作者都要 `platform:roles`：账号接口（改信息 / 改资料 / 改角色 / 重置密码 / 删除）、平台成员接口（改角色 / 移出）、组织内成员接口（改角色 / 移出）。目标角色按 `user_roles` 未过滤的原始名判断。组织内接口先确认对方是本组织成员再判（别的组织的人仍 404）；平台成员接口把人加进一个新组织不算动他。

- 组织内「按用户名加成员」同样受这道闸：对方持平台角色 → 要 `platform:roles`（组织管理员加进来就移不走，口径与移出一致）。平台成员接口 PUT「加入新组织」放行：平台管理员 / superadmin 可以把平台账号加进组织（加入不是对他动手，改角色 / 移出才是）。
- 成员列表（组织内、平台两个接口）和成员写操作的响应带 `holds_platform_role`（按原始平台角色名判断，fail-closed），前端据此隐藏「改角色 / 移出」。
- **平台管理员在后台不能改自己的账号 / 角色**（他自己就持平台角色，对自己同样要 `platform:roles`）；改自己的资料 / 密码只能走 `/me`（`/frontend/auth/me`、`/frontend/auth/me/password`、`/frontend/profiles/me`）。superadmin 本人持 `platform:roles`，可以在后台改自己的资料 / 密码。

**授出 superadmin**：账号接口（建号 / 改角色）加上或去掉 superadmin → 403；组织成员接口里 superadmin 不是组织角色 → 422（两类接口语义不同：前者是越权，后者是参数非法）。角色目录不列 superadmin；没有 `platform:roles` 的人目录为空。

**后台准入**不变：持有任一平台级权限即可进后台，平台管理员能进；前端菜单按生成的权限裁剪，平台管理员看不到「系统监控」「登录日志」；账号页对持平台角色的账号行，没有 `platform:roles` 时不显示编辑 / 删除 / 重置密码 / 改角色（后端兜底 403）。

**平台权限不穿透组织数据**：平台管理员要看某组织的业务数据，仍得先成为该组织成员（§4.3 作用域规则不变）。

**只有一个 superadmin 的启动检查**：改动前 superadmin 能经账号接口授给别人，存量库里可能已有多个，而现在接口撤不掉。装配了 idm 的进程每次启动（不受 seed 开关控制）检查持 superadmin 的存活账号数，> 1 → 拒绝启动并列出用户名；清理 SQL 见 `scripts/prod/README.md`「清理多余的 superadmin」。回滚到之前的版本前要删掉新权限映射（同一节有 SQL），否则旧版本因不认识的权限串拒绝启动。

**存量升级**：启动时 `seed_authz`（ON CONFLICT DO NOTHING）给 superadmin 补上三项新权限、给 platform_admin 建默认映射，idm 的 seed 补建 `platform_admin` 角色行；不需要迁移。
