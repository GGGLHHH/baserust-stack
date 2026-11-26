# 单机多租户 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 baserust 底座一套实例服务多个隔离租户：账号全局、可属多个租户，租户身份在 rust-idm，业务数据共享表 + 显式 TenantId + PG RLS 兜底。

**Architecture:** rust-idm 新增 tenants / tenant_members / member_roles，token 带当前租户与租户角色；rust-content 用 `ContentScope`（租户 / 个人）；baserust 仓储方法显式收 `TenantId`，PG 实现方法内事务 + `set_config('app.tenant_id', …, true)`，表上 ENABLE + FORCE RLS；PG 账号拆成 owner / runtime / system。

**Tech Stack:** Rust（axum 0.8、sqlx、sea-query、utoipa）、PostgreSQL、NATS JetStream、MinIO；前端 TanStack Start + React + TanStack Query + cadenza。

**Spec:** `docs/superpowers/specs/2026-11-25-multi-tenant-design.md`（执行者先读 spec，再读本计划）。

## Global Constraints

- 默认租户 UUID 固定为 `00000000-0000-0000-0000-000000000001`，slug `default`；在 rust-idm、rust-content、baserust 里各定义一个同值常量 `DEFAULT_TENANT_ID`。
- nil UUID 永远不是合法租户：`TenantId::new(Uuid::nil())` 返回错误；业务表 `CHECK (tenant_id <> '00000000-0000-0000-0000-000000000000')`。
- 缺当前租户：HTTP 403，错误码 `tenant_required`；PG 查询不设 `app.tenant_id` 时 0 行。
- 跨租户访问资源 ID → 404。
- RLS 策略表达式：`tenant_id = nullif(current_setting('app.tenant_id', true), '')::uuid`（USING 与 WITH CHECK 都写）；每张业务表 ENABLE + FORCE。
- PG 账号：`<schema>_owner`（迁移、拥有表）、`<schema>`（运行时，NOBYPASSRLS，仅 DML）、`<schema>_system`（BYPASSRLS，后台任务和平台级读），schema ∈ {app, content, search}；idm、ops 不拆。
- 设置租户上下文只用事务级 `set_config(..., true)`，禁止会话级 SET。
- JWT claim：`roles`=平台角色，`tenant_id`（可缺省）=当前租户，`tenant_roles`=当前租户角色。
- 新对象 key：租户内容 `tenants/{tenant_id}/{content_id}/{uuid}`；个人内容 `personal/{owner_id}/{content_id}/{uuid}`。
- 架构铁律照旧：六边形、核心 crate 无基础设施依赖、禁跨 schema join、app 不查 idm 库、事务不进 trait 签名、PUT 全量、新接口写黑盒测试并登记 `covers:`、OpenAPI 快照随改动接受。
- 每个任务结束：所在仓库的 check / test / lint 全绿（baserust：`just check && just test && just lint`；PG 相关加 `just test-pg`；rust-idm / rust-content：`cargo test` + `cargo clippy --all-targets -- -D warnings`，PG conformance 用测试库；basereact：`pnpm lint && pnpm tsc && pnpm test`）。
- **不 commit、不 push、不打 tag**（用户全局规则；改动留在工作区，任务结束把 `git diff` 存到 scratchpad 备份）。
- 本地联调：baserust 的 `Cargo.toml` 把 idm / content 改成 `path = "../rust-idm"` / `path = "../rust-content"`（文件里注释说明了这样做）；发版时再改回 tag（需用户批准）。
- 测试用 PG：只用自己起的容器（compose 项目名 `mt-test`，端口 `15821`），不碰用户的开发库。

## Review Focus

1. 已有数据的库升级：旧账号、旧 widget、旧 content（tenant_id 为 nil）迁移后全部归默认租户，旧账号登录后看得到原数据 —— Task 3、Task 6、Task 7 的迁移测试。
2. 被移出租户 / 租户被停用后再 refresh：必须 401，不能悄悄落到别的租户 —— Task 2 的 `refresh_after_member_removed_is_unauthorized`。
3. 平台管理员（superadmin）不是某租户成员时访问租户级接口：403 `tenant_required` 或 404，不能借平台角色读租户数据 —— Task 5 的 `platform_role_grants_no_tenant_perms`。
4. 后台任务（outbox relay、投影器、保留期清理、seed、rebuild_search）在 RLS 打开后还能工作 —— Task 4 / Task 8 的 e2e。
5. 前端切换租户后另一个标签页还显示旧租户数据 —— Task 11 的 BroadcastChannel 测试。

---

## Phase 0：准备（协调者亲自做）

### Task 0: 分支、联调依赖、测试库、基线

- [ ] rust-idm、rust-content（当前 detached）、baserust、basereact、baserust-stack 各建本地分支 `feat/multi-tenant`（先确认工作区干净、HEAD 等于各自 master）。
- [ ] baserust `Cargo.toml` 的 idm / content 改 path 依赖；`cargo check --workspace` 通过。
- [ ] 起测试 PG：`docker run -d --name mt-test-pg -p 15821:5432 -e POSTGRES_PASSWORD=pwd postgres:<与 compose 相同版本>`，记下容器 id；用 baserust 的 initdb 脚本建 role/schema。
- [ ] 基线：baserust `just test`、`just test-pg`（指向 15821）、rust-idm / rust-content `cargo test`、basereact `pnpm test` 全绿，记下数字。

---

## Phase 1：rust-idm

### Task 1: 租户、成员、租户角色的数据层

**Files:**
- Create: `rust-idm/migrations/0004_tenants.up.sql` / `.down.sql`（并同步拷贝到 `baserust/migrations/idm/`）
- Create: `rust-idm/src/tenant.rs`（领域类型）
- Modify: `rust-idm/src/repo/{mod,memory,postgres}.rs`、`rust-idm/src/lib.rs`
- Test: `rust-idm/tests/idm_repo_conformance.rs`（新增 `idm_tenant_contract`）

**Interfaces:**
- Produces:
  - `pub const DEFAULT_TENANT_ID: Uuid`
  - `pub struct Tenant { id, slug, name, status: TenantStatus, created_at, updated_at, deleted_at }`；`pub enum TenantStatus { Active, Suspended }`
  - `pub struct Membership { tenant: Tenant, user_id, status: MemberStatus, roles: Vec<String>, last_used_at }`；`pub enum MemberStatus { Active, Inactive }`
  - `pub enum RoleScope { Platform, Tenant }`；`RoleRepo::upsert(name, display_name, scope, by)`
  - `trait TenantRepo { create, upsert_fixed(id, slug, name, by), get(id), get_by_slug, list(page), update_name, set_status }`
  - `trait MemberRepo { add(tenant, user, roles, by), remove(tenant, user, by), set_status, set_roles(tenant, user, roles, by), get(tenant, user) -> Option<Membership>, list_by_tenant(tenant, page), memberships_for_user(user) -> Vec<Membership>（只返回 tenant active + member active）, touch_last_used(tenant, user) }`
  - `RoleRepo::roles_for_user` 改为只返回 scope = platform 的角色
  - `SessionRepo::create(user, tenant: Option<Uuid>, hash, expires, by)`；`Session.tenant_id`；`revoke_for_member(tenant, user)`、`revoke_for_tenant(tenant)`
  - outbox 事件：`tenant.created` / `tenant.updated`（含 status）/ `tenant.member_added` / `tenant.member_removed` / `tenant.member_roles_set`，payload 都带 `tenant_id`
- 迁移内容：三张表（字段见 spec §4.1；slug 唯一索引**不带** deleted_at 条件，删除后不复用）；`roles.scope text not null default 'tenant' check (scope in ('platform','tenant'))`；`sessions.tenant_id uuid null references tenants`；插入默认租户；把所有存活用户加为默认租户 active 成员；把现有 `user_roles` **复制**到默认租户的 `member_roles`（scope 过滤在读取时做，平台角色留在 user_roles）。

- [ ] Step 1: 在 `idm_tenant_contract` 写用例：`add_member_then_memberships_for_user_lists_it`、`suspended_tenant_excluded_from_memberships`、`inactive_member_excluded`、`slug_not_reusable_after_delete`、`roles_for_user_returns_platform_scope_only`、`member_roles_are_per_tenant`、`revoke_for_member_revokes_only_that_tenant_sessions`、`member_ops_emit_outbox_events`。内存和 PG 都跑。
- [ ] Step 2: 跑测试确认失败。
- [ ] Step 3: 实现迁移、类型、内存与 PG 仓储（PG 写操作在方法内事务里同时写 outbox）。
- [ ] Step 4: 迁移测试 `migration_backfills_default_tenant`：在跑到 0003 的库里塞两个用户和 user_roles，再跑 0004，断言两人都是默认租户成员、member_roles 有对应行。
- [ ] Step 5: `cargo test`、clippy 全绿；diff 备份。

### Task 2: 登录、refresh、切换、token

**Files:**
- Modify: `rust-idm/src/{token,identity,service,input}.rs`
- Test: `rust-idm/src/service.rs` 的单测（内存仓储）

**Interfaces:**
- Consumes: Task 1 的全部仓储。
- Produces:
  - `TokenClaims { …, roles /*平台*/, tenant_id: Option<Uuid>, tenant_roles: Vec<String> }`；`VerifiedToken`、`AuthUser` 同样加 `tenant_id: Option<Uuid>, tenant_roles: Vec<String>`
  - `AuthService::login`：选 `last_used_at` 最近的有效成员关系，没有则 `tenant_id = None`
  - `AuthService::refresh`：沿用 session.tenant_id，重新校验成员关系和租户状态，失效 → `IdmError::Unauthorized`
  - `AuthService::switch_tenant(refresh_token: &str, tenant_id: Uuid) -> Result<AuthOutcome, IdmError>`：非有效成员 → `Forbidden`；成功则吊销旧 session、建新 session、touch_last_used
  - `AuthService::my_tenants(user_id) -> Result<Vec<Membership>, IdmError>`
  - `AuthService::register`：建账号后若 builder 配置的 `signup_tenant`（默认 `Some(DEFAULT_TENANT_ID)`）存在且 active，加入并授 `signup_roles`（默认 `["user"]`），同一事务
  - builder 新增 `signup_tenant(Option<Uuid>)`、`signup_roles(Vec<String>)`
  - `Hs256Tokens` 序列化新 claim（`#[serde(default)]` 兼容旧 token）

- [ ] Step 1: 单测：`login_picks_last_used_tenant`、`login_without_membership_has_no_tenant`、`switch_tenant_reissues_with_new_tenant_roles`、`switch_to_non_member_tenant_is_forbidden`、`refresh_keeps_tenant`、`refresh_after_member_removed_is_unauthorized`、`refresh_after_tenant_suspended_is_unauthorized`、`register_joins_default_tenant_as_user`、`register_without_default_tenant_only_creates_account`、`old_token_without_tenant_claims_still_verifies`。
- [ ] Step 2: 确认失败 → 实现 → 全绿；更新 rust-idm README / CLAUDE.md 的 token 与租户说明；版本号改 0.6.0（不打 tag）；diff 备份。

---

## Phase 2：rust-content

### Task 3: ContentScope、租户过滤、RLS、对象 key

**Files:**
- Modify: `rust-content/src/{types,input,service}.rs`、`rust-content/src/repo/{mod,memory,postgres}.rs`
- Create: `rust-content/migrations/0002_tenancy.up.sql` / `.down.sql`（同步拷到 `baserust/migrations/content/`）
- Test: `rust-content/tests/content_repo_conformance.rs`、service 单测

**Interfaces:**
- Produces:
  - `pub enum ContentScope { Tenant(Uuid), Personal }`（tenant 值非 nil 由构造校验，nil → `ContentError::InvalidInput`）
  - 所有 service / repo 公开方法第一个业务参数为 `scope: ContentScope`（create / get / update / delete / list / upload / confirm_upload / download / preview / *_url / metadata / objects / set_*_status）；`list` 在 Personal 下按 owner 过滤
  - `Content.tenant_id: Option<Uuid>`（Personal = None）
  - PG 仓储每个方法：`begin` → `select set_config('app.tenant_id', $1, true)`（Personal 时改设 `app.personal_scope = 'on'`）→ SQL 同时带 tenant 条件 → `commit`
  - 对象 key 格式见 Global Constraints；调用方传入的 `object_key` 保持原样
- 迁移：content_metadata / object / object_metadata / content_derived 加 `tenant_id uuid null` 并从 content 回填；`content.tenant_id` 改可空；所有表 nil → `DEFAULT_TENANT_ID`；CHECK 非 nil；ENABLE + FORCE RLS；策略 = 租户分支 OR `(tenant_id is null and current_setting('app.personal_scope', true) = 'on')`；`(tenant_id, …)` 索引。

- [ ] Step 1: conformance 用例（PG 侧用**非 owner** 的运行时账号连）：`get_other_tenant_content_is_not_found`、`list_only_current_tenant`、`personal_scope_invisible_to_tenant_scope`、`tenant_scope_invisible_to_personal_scope`、`query_without_tenant_setting_returns_nothing`（直接 SQL）、`nil_tenant_rejected`、`object_key_has_tenant_prefix`、`legacy_nil_rows_migrated_to_default_tenant`。
- [ ] Step 2: 失败 → 实现 → 全绿；README 更新；版本 0.4.0；diff 备份。

---

## Phase 3：baserust

### Task 4: PG 账号拆分与 RLS 基础设施

**Files:**
- Modify: `baserust/scripts/initdb/00-roles-schemas.sh`、`baserust/scripts/migrate-all.sh`、`baserust/justfile`、`baserust/docker-compose.yml`、`baserust/docker-compose.prod.yml`、`baserust/.env.example`、`baserust/src/infra/config.rs`、`baserust/src/app/state.rs`、`baserust/src/infra/pg.rs`
- Create: `baserust/scripts/initdb/10-tenancy-roles.sh`（幂等升级：建 owner/system 账号、转移 schema 与表 owner、给运行时账号授 DML、`ALTER DEFAULT PRIVILEGES`）
- Modify: stack 层 `scripts/prod/`（prod-init 生成新账号密码、deploy.sh 迁移前跑升级脚本）、`.env.compose`
- Create: `baserust/tests/rls_audit.rs`

**Interfaces:**
- Produces:
  - `infra::pg::tenant_tx(pool: &PgPool, tenant: TenantId) -> Result<Transaction<'_, Postgres>, sqlx::Error>`（Task 5 定义 TenantId；本任务先在 pg.rs 里写，接 `Uuid` 也可，Task 5 再收紧）
  - `AppState` 增加 `app_system_pool`、`content_system_pool`、`search_system_pool`（`Option<PgPool>`，内存模式为 None）
  - 配置：`APP_DB_SYSTEM_USER/PASSWORD` 等（命名跟现有 `*_DB_*` 一致），默认值让零配置仍能跑
  - `rls_audit`：常量 `GLOBAL_TABLES: &[&str]`（app.permissions、app.role_permissions、app.profiles、app.outbox、app._sqlx_migrations 等）；断言 app/content/search 中其余每张表 relrowsecurity && relforcerowsecurity && 有策略；断言运行时账号不是任何表的 owner、`rolbypassrls = false`

- [ ] Step 1: 写 `rls_audit`（此时会因为业务表还没 RLS 而失败 —— 先把尚未改造的表临时列进 `PENDING_TABLES`，后续任务每改一张就删一个，Task 13 时必须为空）。
- [ ] Step 2: 改 initdb / 升级脚本 / migrate-all / 配置 / 连接池；在测试 PG 上从零建一遍，再在「旧结构」库上跑升级脚本，两边 `rls_audit` 的账号断言都通过。
- [ ] Step 3: `just check && just test && just lint && just test-pg` 全绿；diff 备份。

### Task 5: 内核与认证边界

**Files:**
- Create: `baserust/crates/core/src/kernel/tenant.rs`
- Modify: `crates/core/src/kernel/{authz,audit,mod}.rs`、`src/features/auth/adapters/{token.rs,http/routes.rs,http/middleware.rs}`、`src/infra/authz.rs`、`src/infra/http/audit.rs`、`src/app/router.rs`、`src/app/seed.rs`、`seed.toml`、`seed.prod.toml.example`、`mock.toml` / `src/app/mock.rs`、`tests/http_support/mod.rs` 及各 `*_api.rs` 测试夹具
- Test: `tests/http_auth.rs`（或新建 `tests/http_tenancy.rs`）、`crates/core` 单测

**Interfaces:**
- Produces:
  - `pub struct TenantId(Uuid)`：`TenantId::new(Uuid) -> Result<TenantId, AppError>`（nil 报错）、`as_uuid()`、`DEFAULT_TENANT_ID: TenantId`
  - `Perm::scope(&self) -> PermScope`；`pub enum PermScope { Platform, Tenant }`；`RoleName::scope(&self) -> RoleScope`（superadmin = Platform；admin、user = Tenant）
  - `Policy::perms_for(platform_roles: &[String], tenant_roles: &[String]) -> HashSet<Perm>`：平台角色只贡献平台级权限，租户角色只贡献租户级权限；跨作用域的 role_permissions 行启动时 WARN 并忽略
  - 提取器 `CurrentTenant(pub TenantId)`：token 无租户 → 403 `tenant_required`
  - `AuditContext` / `Actor` 带 `tenant_id: Option<TenantId>`；认证中间件把 `tenant_id`、`user_id` 记进 tracing span
  - 接口：`GET /api/v1/frontend/auth/tenants`、`POST /api/v1/frontend/auth/switch-tenant`（body `{ tenant_id }`，写新 cookie）；admin 登录准入按有效权限；`GET /permissions/me` 返回 `tenant: { id, slug, name } | null`
  - seed 格式：`[[tenants]] { id?, slug, name }`（slug=default 时 id 固定为默认租户）；`[[users]].platform_roles`、`[[users]].tenants = [{ slug, roles }]`；seed 幂等、取并集
  - 测试夹具：`mint(id, username, platform_roles, tenant: Option<Uuid>, tenant_roles, scope)`、`TestServer::login` 返回的会话带默认租户

- [ ] Step 1: 黑盒测试：`login_enters_default_tenant`、`tenants_lists_my_memberships`、`switch_tenant_changes_token_tenant`、`switch_to_foreign_tenant_is_403`、`tenant_route_without_tenant_is_403_tenant_required`、`platform_role_grants_no_tenant_perms`、`permissions_me_includes_tenant`、`seed_is_idempotent_with_tenants`。核心单测：`tenant_id_rejects_nil`、`perm_scopes_cover_all_variants`。
- [ ] Step 2: 失败 → 实现 → 登记 `covers:`、接受 OpenAPI 快照 → 全绿；diff 备份。

### Task 6: widget 按租户隔离

**Files:**
- Create: `baserust/migrations/app/0006_widget_tenancy.up.sql` / `.down.sql`
- Modify: `crates/core/src/features/widget/{ports,service,events,memory,model}.rs`、`src/features/widget/adapters/{postgres,bus,http/routes}.rs`
- Test: `tests/widget_repo_conformance.rs`、`tests/http_widget.rs`

**Interfaces:**
- Consumes: `TenantId`、`CurrentTenant`、`tenant_tx`。
- Produces: `WidgetRepo` 所有方法加 `tenant: TenantId`；`WidgetEvent` 各变体带 `tenant_id`；SSE 先比租户。
- 迁移：widgets / widget_tags 加 `tenant_id` 回填默认租户 → not null + CHECK → 唯一索引改 `(tenant_id, name)` → keyset 索引以 tenant_id 打头 → ENABLE + FORCE + 策略；从 `PENDING_TABLES` 移除。

- [ ] Step 1: 测试：`widget_of_other_tenant_is_404`、`widget_list_only_current_tenant`、`same_name_allowed_in_different_tenants`、`sse_does_not_leak_other_tenant_events`、conformance `tenant_isolation`（内存 + PG 运行时账号）。
- [ ] Step 2: 失败 → 实现 → 全绿；diff 备份。

### Task 7: content 接线与个人资料（全局）+ 头像个人作用域

**Files:**
- Modify: `src/features/content/adapters/http/{routes,dto}.rs`（删请求里的 `tenant_id`，用 `CurrentTenant`）、`src/features/profile/adapters/http/routes.rs`（头像用 `ContentScope::Personal`）、`src/app/adapters/content_avatar_probe.rs`、`src/infra/objectstore.rs`（若涉及 key）
- Test: `tests/http_content.rs`、`tests/http_profile.rs`

**Interfaces:**
- Consumes: Task 3 的 `ContentScope`；Task 5 的 `CurrentTenant`。
- Produces: content 接口不再接受 `tenant_id` 入参（DTO 字段删除；响应里的 `tenant_id` 改为可空）；profiles 保持全局（进 `GLOBAL_TABLES`）。

- [ ] Step 1: 测试：`content_of_other_tenant_is_404`、`upload_lands_in_current_tenant`、`avatar_visible_across_tenants`、`avatar_not_listed_in_tenant_contents`、`only_owner_can_replace_avatar`。
- [ ] Step 2: 失败 → 实现 → 快照 → 全绿；diff 备份。

### Task 8: 搜索索引、认证审计、事件与后台任务

**Files:**
- Create: `baserust/migrations/search/0003_tenancy.up.sql` / `.down.sql`
- Modify: `src/features/search/adapters/{postgres,projector}.rs`、`crates/core/src/features/search/*`、`src/features/auth_audit/adapters/{postgres,projector,http/routes}.rs`、`src/infra/outbox.rs`、`src/features/profile/adapters/{postgres,outbox}.rs`、`src/bin/rebuild_search.rs`、保留期任务、`src/app/state.rs`（后台任务用 system 池）
- Test: `tests/search_repo_conformance.rs`、`tests/search_projection_p3.rs`、`tests/auth_event_repo_conformance.rs`、`tests/durable_events_p1.rs`

**Interfaces:**
- Produces:
  - outbox 信封加 `tenant_id: Option<Uuid>`
  - `admin_user_index` → 主键 `(tenant_id, user_id)`，投影 `tenant.member_added / removed / member_roles_set`；`user.updated` / `profile.updated` 更新该用户所有行；`SearchIndexRepo` 读方法加 `tenant: TenantId`
  - `auth_event.tenant_id uuid null`；审计读接口走 system 池（平台级）
  - 所有后台任务用 `*_system_pool`
- 迁移：重建 admin_user_index（可清空，rebuild_search 重建）；auth_event 加列；admin_user_index ENABLE + FORCE + 策略；auth_event 进 `GLOBAL_TABLES`（平台级、只走 system 池）。

- [ ] Step 1: 测试：`member_index_scoped_by_tenant`、`profile_update_refreshes_all_tenant_rows`、`projector_handles_member_events`、`auth_event_records_tenant`、`relay_and_projectors_work_with_rls_on`（e2e）。
- [ ] Step 2: 失败 → 实现 → 全绿；diff 备份。

### Task 9: 平台与租户管理接口

**Files:**
- Create: `src/features/tenants/`（平台租户管理：核心在 `crates/core/src/features/tenants/`，照 widget 范式；仓储端口由组合根用 idm 的 TenantRepo / MemberRepo 适配）
- Modify: `crates/core/src/features/users/*`、`src/features/users/adapters/http/routes.rs`、`src/app/router.rs`、`src/app/state.rs`
- Test: `tests/http_tenants.rs`、`tests/http_users.rs`

**Interfaces:**
- Produces（权限名加进 `Perm` 闭集并标作用域）：
  - 平台级（`tenants:admin`，Platform）：`GET/POST /api/v1/admin/platform/tenants`、`GET/PUT /api/v1/admin/platform/tenants/{id}`（PUT 全量：name、status）、`GET /api/v1/admin/platform/tenants/{id}/members`、`PUT /api/v1/admin/platform/tenants/{id}/members/{user_id}`（body `{ roles }`，不存在则加入）、`DELETE …/members/{user_id}`
  - 平台级账号管理：现有 `/admin/auth/users*` 改为需要平台权限 `users:admin`（Platform）
  - 租户级（`members:read` / `members:admin`，Tenant）：`GET /api/v1/admin/auth/members`、`POST /api/v1/admin/auth/members`（body `{ username, roles }`，精确匹配，查不到 404 `account_not_found`）、`PUT /api/v1/admin/auth/members/{user_id}/roles`、`DELETE /api/v1/admin/auth/members/{user_id}`
  - 停用租户 / 移除成员时调用 idm 吊销相关 session

- [ ] Step 1: 测试：`platform_admin_creates_and_suspends_tenant`、`suspended_tenant_member_cannot_refresh`、`tenant_admin_adds_member_by_username`、`unknown_username_is_404`、`tenant_admin_cannot_manage_accounts`、`tenant_admin_cannot_touch_other_tenant_members`、`removed_member_sessions_revoked`。
- [ ] Step 2: 失败 → 实现 → covers 登记 → 快照 → 全绿；diff 备份。

---

## Phase 4：basereact

### Task 10: 租户切换与空状态

**Files:**
- Modify: `basereact/src/components/team-switcher.tsx`、`src/brand.tsx`、`src/api/auth.ts`、`src/lib/query-keys.ts`、`src/lib/route-guard.ts`、frontend 顶栏 `src/routes/frontend/-shell.tsx`
- Create: 「还没加入任何组织」页（admin 与 frontend 各一）、`src/lib/tenant-sync.ts`（BroadcastChannel）
- Regenerate: `src/generated/*`（`pnpm generate`，后端起在非默认端口）

**Interfaces:**
- Consumes: Task 5 的 `/auth/tenants`、`/auth/switch-tenant`、`/permissions/me`。
- Produces: `useMyTenants()`、`useSwitchTenant()`（成功后 `queryClient.clear()`、广播 `tenant-changed`、重新导航当前路由）；切换器只在租户数 ≥ 2 时显示；遵守 cadenza 组件约定（见 memory：滚动 / 下拉用 @gedatou/cadenza-ui）。

- [ ] Step 1: 测试：`switcher_hidden_with_single_tenant`、`switch_clears_cache_and_broadcasts`、`other_tab_reloads_on_tenant_changed`、`no_tenant_user_sees_empty_state`。
- [ ] Step 2: 失败 → 实现 → `pnpm lint && pnpm tsc && pnpm test` 全绿；diff 备份。

### Task 11: 后台管理页

**Files:**
- Create: 平台「租户管理」页（列表、新建、停用 / 恢复、成员管理）、租户「成员」页（列表、按用户名添加、改角色、移除）
- Modify: 现有「用户」页改为平台「账号管理」（仅平台权限可见）、菜单与 `access-control` / `use-admin-menu`、i18n（zh / en）

- [ ] Step 1: 测试：菜单按权限裁剪（租户管理员看不到租户管理和账号管理；平台管理员看得到）、成员添加表单的 404 提示、停用确认。
- [ ] Step 2: 失败 → 实现 → 全绿；用浏览器在本机起的整栈上手动走一遍（非默认端口），截图核对；diff 备份。

---

## Phase 5：收尾

### Task 12: 文档、skills、全量验证

**Files:**
- Modify: `baserust/CLAUDE.md`（固定架构里加「多租户」一节）、`baserust/README.md`、`baserust/.claude/skills/{authorization,transactions,adding-a-feature}/SKILL.md`（新模块必须带 TenantId + RLS + 黑盒跨租户测试）、`docs/new-project.md`（「同步多租户版本后要做的事」）、`scripts/prod/README.md`、rust-idm / rust-content README
- [ ] `rls_audit` 的 `PENDING_TABLES` 为空。
- [ ] 全量：baserust `just check && just test && just lint && just test-pg`；rust-idm、rust-content `cargo test` + clippy；basereact `pnpm lint && pnpm tsc && pnpm test`。
- [ ] 升级演练：用 master 版本在测试 PG 建库 + seed + 造数据，切到本分支跑升级脚本和迁移，旧账号登录看到原数据。
- [ ] 整栈：compose（项目名 `mt-test`、非默认端口）起来，浏览器走一遍登录、切换、跨租户 404。
- [ ] 停掉自己起的容器 / 进程（只按记下的 id）。
- [ ] 向用户列出待批准动作：各仓库提交、推送、rust-idm v0.6.0 / rust-content v0.4.0 打 tag、baserust 改回 tag 依赖、stack 指针更新。
