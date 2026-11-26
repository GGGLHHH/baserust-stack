# 主流应用框架的多租户实现模式（2024–2026 现行做法事实笔记）

> 采集日期：2026-11-25。版本/维护状态来自各仓库 GitHub API（\`gh api repos/...\`）和官方文档当前页。
> 说明：WebFetch 返回的是页面摘要，引号内为摘要中引用的原文；个别细节只在社区帖/二手文章出现的，已标注「二手」。

---

## Q1. ABP Framework 怎么做（host / tenant、IMultiTenant、数据过滤器、租户解析器链）

### Takeaway
ABP 是「框架内建、全栈贯通」的典型：一个 \`ICurrentTenant\` 环境上下文 + \`IMultiTenant\` 实体接口 + 自动数据过滤 + 有序的解析器链（claims 优先），缓存 key、事件总线、后台作业都自动带 TenantId；\`TenantId == null\` 即 host（平台方）。默认一个用户只属于一个租户，「一个账号多租户」是 2026 年 10.x 才加的**商业版**功能（Shared User Accounts）。

### Cited Findings
- **开关**：\`AbpMultiTenancyOptions.IsEnabled\` 控制多租户；"Multi-Tenancy is disabled in the ABP by default"，但启动模板通过 \`MultiTenancyConsts\` 打开。官方页没有单独的「单租户模式」，最接近的就是 \`IsEnabled = false\` — [ABP Multi-Tenancy](https://abp.io/docs/latest/framework/architecture/multi-tenancy)
- **Host vs Tenant**：Tenant 是付费客户，Host 是拥有并运营系统的公司；\`ICurrentTenant.Id\` 为 null 表示 host 用户或无法确定租户；\`IMultiTenant.TenantId\` 可空，null 表示数据属于 host（例：host 用户的 \`IdentityUser.TenantId\` 为 null）；\`CurrentTenant.Change(null)\` 切回 host — [ABP Multi-Tenancy](https://abp.io/docs/latest/framework/architecture/multi-tenancy)
- **解析器链**：实现 \`ITenantResolveContributor\` / \`TenantResolveContributorBase\`，注册到 \`AbpTenantResolveOptions.TenantResolvers\`。默认顺序：\`CurrentUserTenantResolveContributor\`（从已认证用户的 claims 取，文档称其为 "the first contributor for the security"）→ QueryString → Route → Header → Cookie，默认 key 为 \`__tenant\`；域名解析 \`AddDomainTenantResolver("{0}.mydomain.com")\` — [ABP Multi-Tenancy](https://abp.io/docs/latest/framework/architecture/multi-tenancy)
- **默认租户**：\`AbpTenantResolveOptions.FallbackTenant\` 可设回退租户，但设了之后 "no way to switch to the host side" — [ABP Multi-Tenancy](https://abp.io/docs/latest/framework/architecture/multi-tenancy)
- **中间件**：\`app.UseMultiTenancy()\`，通常放在认证中间件之后（这样才能读 claims）；\`AbpAspNetCoreMultiTenancyOptions.MultiTenancyMiddlewareErrorPageBuilder\` 处理租户不存在/停用 — [ABP Multi-Tenancy](https://abp.io/docs/latest/framework/architecture/multi-tenancy)
- **数据过滤**：实体实现 \`IMultiTenant\` 即自动过滤，"A tenant can not access to data of another tenant by default"；\`TenantId\` 在基类 \`Entity\` 构造时从 \`ICurrentTenant.Id\` 取值；跨租户查询用 \`IDataFilter.Disable<IMultiTenant>()\`；该关闭在「库按租户分」时 "won't work" — [ABP Multi-Tenancy](https://abp.io/docs/latest/framework/architecture/multi-tenancy)
- **上下文切换**：\`CurrentTenant.Change(tenantId)\` 返回 IDisposable、可嵌套，官方要求总是包在 \`using\` 里 — [ABP Multi-Tenancy](https://abp.io/docs/latest/framework/architecture/multi-tenancy)
- **租户存储**：\`ITenantStore\`；不用租户管理模块时 \`DefaultTenantStore\` 从 appsettings 的 \`Tenants\` 数组读（Id/Name/NormalizedName/可选 ConnectionStrings）；租户名大小写不敏感。数据库模型支持单库、库按租户、混合；**按租户连接串是 PRO（SaaS 模块）功能** — [ABP Multi-Tenancy](https://abp.io/docs/latest/framework/architecture/multi-tenancy)
- **反模式（官方）**：别在实体创建后改 TenantId（等于把数据搬到别的租户）；纯租户数据别让 TenantId 为 null；别改 \`__tenant\` key 名；Nginx 默认可能丢弃含下划线的 header — [ABP Multi-Tenancy](https://abp.io/docs/latest/framework/architecture/multi-tenancy)
- **缓存**：\`IDistributedCache<TCacheItem>\` "automatically adds the current tenant id to the cache key"；key = 缓存名 + 应用前缀（\`AbpDistributedCacheOptions.KeyPrefix\`）+ 当前租户 ID；要跨租户共享就在缓存项类上加 \`[IgnoreMultiTenancy]\`；HybridCache 同规则 — [ABP Caching](https://abp.io/docs/latest/framework/fundamentals/caching)
- **分布式事件**：\`OutgoingEventInfo.SetTenantId()\` 把租户 ID 写进事件的 \`ExtraProperties[EventBusConsts.TenantIdHeaderName]\`，消费侧 \`GetTenantId()\` 解析 — [ABP 源码 OutgoingEventInfo.cs](https://github.com/abpframework/abp/blob/dev/framework/src/Volo.Abp.EventBus.Abstractions/Volo/Abp/EventBus/Distributed/OutgoingEventInfo.cs)
- **后台作业（二手/社区）**：作业参数类实现 \`IMultiTenant\` 时执行器按参数里的 TenantId 切上下文，否则以 worker 当前租户（通常为 null=host）运行；后台 worker 默认 host 上下文，需自己遍历租户 + \`CurrentTenant.Change\`；PR #26148 让动态作业参数也带上入队时的租户 — [ABP support #10688](https://abp.io/support/questions/10688/VoloAIManagementBackgroundJobsIndexDocumentJob-fails-for-tenant-uploads--blob-path-mismatch-caused-by-missing-IMultiTenant-on-IndexDocumentJobArgs)；[ABP support #9458](https://abp.io/support/questions/9458/Is-BackgroundWorker-Tenant-Safe)；[PR #26148](https://github.com/abpframework/abp/pull/26148)。官方 [Background Jobs 文档](https://abp.io/docs/latest/framework/infrastructure/background-jobs) 页面本身没写租户如何传递。
- **一个账号属于几个租户**：\`AbpMultiTenancyOptions.UserSharingStrategy\` = \`TenantUserSharingStrategy.Isolated\`（默认，"a user belongs to exactly one tenant (or the Host)"，用户名/邮箱唯一性按租户）或 \`Shared\`（一个账号可加入多个租户；用户名/邮箱全局唯一；身份、锁定、密码策略、2FA "live at the host level"；登录时若属于多个租户需选择，登录后用户菜单可切换；租户管理员通过邀请拉人，邀请 7 天过期；租户管理员只能把成员「移出本租户」，删账号/锁定只能 host 做；按租户分库时 host 库里要有影子用户）。该功能 "mainly provided by Account.Pro and Identity.Pro"（商业版）— [ABP Shared User Accounts (10.7)](https://abp.io/docs/10.7/modules/account/shared-user-accounts)
- 早期社区帖确认默认模型下「一个用户多租户」不开箱支持，只能每租户各注册一个账号 — [ABP support #4860](https://abp.io/support/questions/4860/Can-one-user-belong-to-multiple-tenants)；[GitHub issue #2611](https://github.com/abpframework/abp/issues/2611)
- **版本**：abpframework/abp 最新 release \`11.0.0\`（2026-11-19），文档站 latest 仍标 10.7（页面更新于 2026-06-01）— GitHub API；[ABP Multi-Tenancy](https://abp.io/docs/latest/framework/architecture/multi-tenancy)

### Inferences
- ABP 的「身份库里的 user 带 TenantId（Isolated）」正是「租户身份放 idm」的一种落地；而 Shared 模式等价于「全局账号 + 成员关系表」，且把安全策略提升到 host 级——说明「账号属于多个租户」会把用户名唯一性、锁定、2FA 的归属从租户级挪到平台级，这是设计时必须先定的。
- 「claims 解析器排第一」意味着：已登录请求以 token 里的租户为准，header/query 只作为未登录或 host 切租户时的辅助——可直接借鉴为「JWT 里带 tid，header 只在 host 管理员时生效」。

### Gaps
- 官方文档未明确背景作业/分布式事件的完整租户传递规则，以上作业部分来自支持论坛与 PR，需对照 11.0 源码确认。
- ABP 11.0 是否改动了多租户 API 未核实（文档站仍是 10.7）。

---

## Q2. Rails / Django / Laravel / Spring-Hibernate / .NET Finbuckle 各自怎么做

### Takeaway
2026 年主流库分两派：**共享表 + tenant_id 自动作用域**（acts_as_tenant、django-multitenant、stancl 单库模式、Hibernate \`@TenantId\`、Finbuckle EF Core 命名查询过滤器）和**按 schema/库隔离 + 切换连接**（ros-apartment、django-tenants、stancl 多库模式、Hibernate \`MultiTenantConnectionProvider\`、Basecamp activerecord-tenanted）。共同点：都靠「ORM 层自动加条件」，原生 SQL 一律不管；新趋势是把过滤下沉到 PostgreSQL RLS（stancl v4）和 fail-closed（Finbuckle v11、activerecord-tenanted）。

### Cited Findings

**Rails — acts_as_tenant（行级、共享库）**
- \`acts_as_tenant(:account)\` 基于 Rails \`default_scope\`；"ActsAsTenant uses row-level multitenancy"；当前租户存在 \`ActiveSupport::CurrentAttributes\`（按线程隔离，Falcon 可设 \`isolation_level = :fiber\`）— [acts_as_tenant README](https://github.com/ErwinM/acts_as_tenant)
- 解析：\`set_current_tenant_by_subdomain\`、\`set_current_tenant_by_subdomain_or_domain\`、\`set_current_tenant_through_filter\` + \`before_action\`；块作用域 \`ActsAsTenant.with_tenant\`；绕过 \`without_tenant\` — 同上
- \`config.require_tenant\`：没设租户时直接报错而不是不加过滤；作业：ActiveJob 把租户放进参数，Sidekiq 放进 job hash 的 \`acts_as_tenant\` 键 — 同上
- **README 明列不受保护的情况**：未设租户且没开 \`require_tenant\` 时的任何查询；\`unscoped\`；\`find_by_sql\` / \`connection.execute\` 等原生 SQL；\`update_counters\` 系列；\`update_column(s)\`；\`upsert_all\` 的匹配跨所有租户 — 同上
- 维护：v2.3.1 发布于 2026-11-24（GitHub API），1.7k stars

**Rails — Apartment（schema-per-tenant）的现状**
- 原版 influitive/apartment：默认分支最后提交 2019-06-25，最新 tag v2.2.1，仓库未归档但事实上停更（GitHub API）；README 仍是 travis-ci 徽章 — [influitive/apartment](https://github.com/influitive/apartment)
- 现由 fork **ros-apartment** 接手："a maintained fork of the original Apartment gem. Maintained by CampusESP since 2024"；v3.10.1（2026-08），v4.0.0.alpha15（2026-09-28）；要求 Ruby 3.3+、Rails 8.1+、PG 14+ — [rails-on-services/apartment](https://github.com/rails-on-services/apartment)
- v4 架构转变：从 v3 的「线程局部 + 在共享连接上切 search_path」改为「按 \`tenant:role\` 建连接池」，"connection pools are managed per tenant rather than swapping search paths on a shared connection"；上下文用 fiber-safe 的 \`CurrentAttributes\` — 同上
- **重要风险（官方原文）**："PgBouncer in \`transaction\` pooling mode can silently serve one tenant another tenant's data"（PG ≤17）；需 session 模式或 PG18+ 的 \`track_extra_parameters = IntervalStyle,search_path\` — 同上
- 其他官方建议：用块形式 \`switch\`（保证异常时清理），\`switch!\` "discouraged"，直接写 \`Apartment::Current\` 有 RuboCop cop 报错；作业要把租户名作参数显式切换；遍历租户用 \`Tenant.each\`；缓存需按租户分 keyspace — 同上
- 「Apartment 为何被弃用」：没有找到原作者的正式弃用声明；事实是原仓库 2019 年后停更，社区转向 ros-apartment fork 或 acts_as_tenant（二手比较文章 — [Medium 比较](https://medium.com/@kiasalvati/simplifying-multi-tenancy-in-rails-comparing-ruby-gems-apartment-act-as-tenant-and-98f123712315)）。schema-per-tenant 的结构性成本（每租户迁移、连接池随租户数膨胀、PgBouncer 串租户）在 ros-apartment README 里有明确记录（见上）。

**Rails — Basecamp activerecord-tenanted（新，database-per-tenant）**
- 37signals 的 gem："Enable a Rails application to have separate databases for each tenant"；"Only the sqlite3 database adapter is fully supported right now"；设计原则 "All tenant-related code execution must happen within a well-defined isolated tenant context"、"Developing a multi-tenant Rails app should be as easy as developing a single-tenant app" — [basecamp/activerecord-tenanted](https://github.com/basecamp/activerecord-tenanted)
- 机制：\`ApplicationRecord\` 上声明 \`tenanted\`，database.yml 路径含 \`%{tenant}\`；服务器内由中间件自动设上下文，默认解析器 \`->(request) { request.subdomain }\`；无租户上下文访问抛 \`ActiveRecord::Tenanted::NoTenantError\`（fail-closed）；AR 缓存 key 内置租户，但 \`Rails.cache\` 不自动处理；Active Job 带租户等多项仍是 TODO（指南自称 work-in-progress）— [GUIDE.md](https://github.com/basecamp/activerecord-tenanted/blob/main/GUIDE.md)

**Django — django-tenants（schema-per-tenant）**
- 共享一个 PG 库、每租户一个 schema；按主机名识别租户，匹配后 "the search path is updated to use this tenant's schema"，找不到租户返回 404；\`public\` schema 永远在 search_path 里放共享数据 — [django-tenants docs](https://django-tenants.readthedocs.io/en/latest/)
- 配置：\`django_tenants.postgresql_backend\`，\`TenantMainMiddleware\` 放在 MIDDLEWARE 第一位；\`TENANT_MODEL\`（继承 \`TenantMixin\`）、\`TENANT_DOMAIN_MODEL\`（\`DomainMixin\`）、\`SHARED_APPS\` / \`TENANT_APPS\`、\`PUBLIC_SCHEMA_NAME\`、\`PUBLIC_SCHEMA_URLCONF\`（主站与租户站同路径不同路由）；子目录模式 \`TenantSubfolderMiddleware\`（beta）；迁移用 \`migrate_schemas --shared\` — [django-tenants install](https://django-tenants.readthedocs.io/en/latest/install.html)
- 缓存：\`KEY_FUNCTION = django_tenants.cache.make_key\` "adds the tenants schema_name as the first key prefix" — 同上
- Celery：配套 tenant-schemas-celery，"The \`TenantTask\` class transparently inserts current connection's schema into the task's kwargs"，worker 端在 \`task_prerun\` 弹出并切 schema — [tenant-schemas-celery](https://github.com/maciej-gol/tenant-schemas-celery)
- 用户跨租户：django-tenant-users "ensures users can authenticate globally but have permissions tailored to each specific tenant" — [django-tenant-users](https://github.com/Corvia/django-tenant-users)
- 维护：django-tenants v4.1.1（2026-11-24，GitHub API）

**Django — django-multitenant（Citus，共享表）**
- "assumes that all the tenant relates models/tables have a tenant_id column"；\`TenantModel\` / \`TenantModelMixin\`、\`TenantForeignKey\`、\`set_current_tenant()\` 通常在中间件里调；自动给 queryset、join、update、count、子查询加 tenant_id；可选 PG 后端建含 tenant_id 的复合外键 — [django-multitenant](https://github.com/citusdata/django-multitenant)
- **未设租户时退化为不加过滤**："If the current_tenant is not set, then the default/native API without tenant scoping is used"（fail-open）— 同上
- 维护：最后 release v4.0.0 为 2023-09，仓库最后 push 2026-03；兼容矩阵止于 Django 4.2（GitHub API + README）——维护活跃度偏低

**Laravel — stancl/tenancy（archtechx/tenancy）**
- 两种模式：多库（主打）和单库；"automatic mode"：识别租户后 "database connections, caches, filesystems, queues etc were switched to that tenant's context"；官方提醒「只是给用户的 todo 加作用域」不需要多租户包 — [Tenancy v3 Introduction](https://tenancyforlaravel.com/docs/v3/introduction)
- 识别中间件：\`InitializeTenancyByDomain\` / \`BySubdomain\` / \`ByDomainOrSubdomain\` / \`ByPath\` / \`ByRequestData\`（默认 \`X-Tenant\` header → \`tenant\` query）；失败回调 \`$onFail\` — [Tenant identification](https://tenancyforlaravel.com/docs/v3/tenant-identification)
- 「central app vs tenant app」：无租户时运行的中央应用（注册、平台管理后台）和租户上下文里的租户应用 — [The two applications](https://tenancyforlaravel.com/docs/v3/the-two-applications)
- **Bootstrapper 机制**（核心设计）：\`DatabaseTenancyBootstrapper\`（切默认连接，显式指定连接的代码不受影响）、\`CacheTenancyBootstrapper\`（每次缓存调用加租户 tag，需 Redis 等支持 tag 的存储）、\`FilesystemTenancyBootstrapper\`（storage 路径加后缀）、\`QueueTenancyBootstrapper\`（"Adds the tenant ID to job payloads"，执行时据此初始化租户）、\`RedisTenancyBootstrapper\`（改 Redis 前缀）；自定义实现 \`TenancyBootstrapper::bootstrap()/revert()\` — [Tenancy bootstrappers](https://tenancyforlaravel.com/docs/v3/tenancy-bootstrappers)
- 单库模式：\`BelongsToTenant\` trait（主模型）、\`BelongsToPrimaryModel\`（次级模型经父关系作用域）、\`withoutTenancy()\`；**无当前租户时查询不加作用域**；唯一索引、校验规则要自己按 tenant 加；"The package can only provide scoping logic for the abstraction logic that Eloquent is" — [Single-database tenancy](https://tenancyforlaravel.com/docs/v3/single-database-tenancy)
- 队列：中央与租户作业 "it's recommended not to mix queue connections" — [Queues](https://tenancyforlaravel.com/docs/v3/queues)
- **v4 + PostgreSQL RLS**：\`tenants:rls\` 生成 RLS 策略并建一个受限 DB 用户；租户初始化时切到该用户，会话变量（默认 \`my.current_tenant\`）存当前租户，策略比对该变量；\`TableRLSManager\`（沿外键最短路径到 tenants 表自动生成策略）/ \`TraitRLSManager\`；**官方明确 "not a security boundary"**：无策略的表不受限、\`ON DELETE CASCADE\` 和外键检查绕过 RLS、TRUNCATE 不受 RLS 约束、事务模式连接池会破坏会话变量 — [Tenancy v4 PostgreSQL RLS](https://v4.tenancyforlaravel.com/postgres-rls/)
- 维护：最新 tag v3.10.1（2026-08-05），仓库 2026-11-12 仍有 push（GitHub API）；v4 有独立文档站，但据二手文章截至撰文时**无 tagged release**、安装走 dev-master（未经一手核实）— [saas-laravel.com 比较](https://saas-laravel.com/blog/stancl-tenancy-vs-spatie-multitenancy.html)；v4 已知问题：\`TableRLSManager\` 把 tenant_id 转 text 导致索引失效 — [issue #1526](https://github.com/archtechx/tenancy/issues/1526)

**Laravel — spatie/laravel-multitenancy（极简派）**
- "it should only provide the bare essentials to enable multitenancy"：只负责确定当前租户 + 租户切换时执行的 task — [Spatie multitenancy v4](https://spatie.be/docs/laravel-multitenancy/v4/introduction)
- 队列：\`queues_are_tenant_aware_by_default\`；或标记接口 \`TenantAware\` / \`NotTenantAware\`（后者运行时无当前租户）— [Making queues tenant aware](https://spatie.be/docs/laravel-multitenancy/v4/basic-usage/making-queues-tenant-aware)
- 缓存：\`PrefixCacheTask\` "dynamically changing the \`cache.prefix\`"；Octane 的 \`octane\` 缓存驱动忽略前缀 — [Prefixing cache](https://spatie.be/docs/laravel-multitenancy/v4/using-tasks-to-prepare-the-environment/prefixing-cache)

**Java — Hibernate ORM（Spring 生态实际依赖它）**
- 三种方式：Separate database、Separate schema（\`TenantSchemaMapper\` 负责切 schema）、Shared tables + 鉴别列（\`@TenantId\`）；另有 \`TenantCredentialsMapper\` 按租户选 DB 用户 — [Hibernate MultiTenancy.adoc (main)](https://raw.githubusercontent.com/hibernate/hibernate-orm/main/documentation/src/main/asciidoc/userguide/chapters/multitenancy/MultiTenancy.adoc)
- \`@TenantId\`："Hibernate generates the tenant value from the session tenant"；手动给了不同租户值会被拒（root 租户除外）；映射查询、实体变更、HQL/Criteria 批量 update/delete 都会过滤；**HQL insert 不自动填、原生 SQL / 存储过程 / JDBC 不改写** — 同上
- \`CurrentTenantIdentifierResolver\`（\`hibernate.tenant_identifier_resolver\`）给新 session 提供默认租户；\`validateExistingCurrentSessions()\` 不一致时抛 \`TenantIdentifierMismatchException\`；\`isRoot(tenant)\` 标识可跨分区访问的特权会话（"does not grant database privileges"）；\`MultiTenantConnectionProvider\`（\`hibernate.multi_tenant_connection_provider\`）按租户取/还连接 — 同上
- "An existing session keeps its tenant across transactions and calls to \`clear()\`. To work for another tenant, open a new session"；"Hibernate's default tenant-aware cache keys distinguish tenants" — 同上
- Spring：Spring Data JPA 官方文档没有多租户章节 — [Spring Data JPA docs](https://docs.spring.io/spring-data/jpa/reference/jpa/getting-started.html)；社区做法均为 Spring Boot + Hibernate \`@TenantId\` / \`MultiTenantConnectionProvider\`（二手：[JulioLabs starter](https://github.com/JulioLabs/spring-boot-multitenant-starter)；[DEV 文章](https://dev.to/sushrut_bidwai/shared-schema-multi-tenancy-in-spring-boot-hibernate-the-reference-code-we-actually-run-3pj0)），并普遍提醒原生查询绕过 \`@TenantId\`

**.NET — Finbuckle.MultiTenant**
- 解析管道：Strategy（\`IMultiTenantStrategy.GetIdentifierAsync\`，从请求取标识字符串）→ Store（\`IMultiTenantStore\`，标识映射到 \`TenantInfo\`）；内置策略 Static / Delegate / HttpContext / BasePath / Claim / Session / Route / Host / Header（默认 key \`__tenant__\`）；按注册顺序尝试，"Chain strategies in priority order to provide graceful fallbacks"；Static 策略总是最后执行 — [Finbuckle Strategies](https://www.finbuckle.com/MultiTenant/Docs/Strategies)
- 环境上下文：\`ITenantContext\` 单例，"the current tenant is stored in an \`AsyncLocal\`, so it flows with the current asynchronous execution context rather than with the DI scope"；\`TenantInfo\` 在一个 scope 内 "can only be set once"；scope 外读取抛异常；后台工作捕获 scope 后保留该 scope；非 Web 宿主手动 \`BeginTenantScope(tenantInfo)\` — [Finbuckle Core Concepts](https://www.finbuckle.com/MultiTenant/Docs/CoreConcepts)
- \`Id\`（永不改变）与 \`Identifier\`（解析用的 key，如子域名）分离；"Never change \`Identifier\` in place" — 同上
- EF Core 共享库：影子属性 \`TenantId\` + **命名全局查询过滤器**（.NET 10 起 EF Core 支持命名过滤器，不再和其他过滤器冲突）；**fail-closed**："queries against multi-tenant entity types return no rows rather than all rows" when TenantInfo 为 null（早期版本是抛异常）；\`TenantMismatchMode\`（Throw 默认 / Ignore / Overwrite）、\`TenantNotSetMode\`；过滤器只作用于查询根，不作用于 Include — [Finbuckle EF Core](https://www.finbuckle.com/MultiTenant/Docs/EFCore)
- 反模式：在已跟踪实体的 context 上换 TenantInfo 会造成隔离破坏；唯一索引要含 TenantId — 同上
- 维护/许可：v11.0.0 发布于 2026-11-24（GitHub API），大版本对齐 .NET 大版本；源码 Apache 2.0，但**官方 NuGet 包走 Open Source Maintenance Fee EULA**，盈利性使用需付费（小组织免费），构建会出 \`FBMT0001\` 警告直到设 \`AcceptFinbuckleEULA\` — [Finbuckle Introduction](https://www.finbuckle.com/MultiTenant/Docs/v9/Introduction)

**.NET — Orchard Core（「Default 租户」）**
- 存在名为 \`Default\` 的租户，可创建 Feature Profiles 限制其他租户能用的功能；共享库时用 \`TablePrefix\` 隔离各租户表，静态文件放 \`App_Data\Sites\[Tenant]\` — [Orchard Core Tenants](https://docs.orchardcore.net/en/latest/reference/modules/Tenants/)

### Inferences
- 各家「自动过滤」都只覆盖 ORM 抽象层，原生 SQL 全部裸奔——对 sqlx（本身就是原生 SQL、无 ORM 拦截层）意味着：**应用层没有可依赖的自动作用域机制**，只能靠 (a) 仓储层强制签名带 tenant_id，或 (b) PostgreSQL RLS 让数据库兜底。这一点 sqlx 栈和上述框架有本质差别。
- schema-per-tenant 在 2026 年的维护者自己都在退：ros-apartment v4 放弃切 search_path、改连接池按租户；PgBouncer 事务模式会串租户。单机 compose、租户数不确定的场景，共享表 + tenant_id（+ RLS）成本最低。
- fail-closed（无租户 = 报错或空结果）是新版本的方向（Finbuckle v11、activerecord-tenanted、acts_as_tenant \`require_tenant\`），旧库多为 fail-open（django-multitenant、stancl 单库、acts_as_tenant 默认）。

### Gaps
- Hibernate \`@TenantId\` 首次引入的确切版本（社区说 6.3+，未核到 release notes）。
- stancl/tenancy v4 是否已有正式 tag 仅有二手来源；release 列表最新为 v3.10.1。
- django-tenants 官方文档首页未说明 Celery 集成，Celery 方案来自独立第三方包。

---

## Q3. 租户上下文如何在请求内传递；后台任务、消息事件、缓存 key 怎么带租户

### Takeaway
统一模式是「**入口解析一次 → 写入执行流局部的环境上下文 → 所有下游基础设施读它**」：.NET 用 \`AsyncLocal\`，Rails 用 \`CurrentAttributes\`（线程/fiber 局部），Laravel 用容器单例 + bootstrapper，Hibernate 绑在 Session 上。跨进程边界（作业、事件）一律**序列化租户 ID 进消息体/头**，消费端重新建立上下文；缓存一律**加租户前缀/标签**，并提供显式的「全局共享」退出口。

### Cited Findings
- **请求内载体**：Finbuckle 用 \`AsyncLocal\`，随异步执行上下文流动而非 DI scope — [Finbuckle Core Concepts](https://www.finbuckle.com/MultiTenant/Docs/CoreConcepts)；acts_as_tenant 用 \`ActiveSupport::CurrentAttributes\`（per-thread，可改 per-fiber）— [acts_as_tenant](https://github.com/ErwinM/acts_as_tenant)；ros-apartment v4 用 fiber-safe \`CurrentAttributes\` — [ros-apartment](https://github.com/rails-on-services/apartment)；Hibernate 把租户固定在 Session 上，换租户要开新 Session — [Hibernate MultiTenancy.adoc](https://raw.githubusercontent.com/hibernate/hibernate-orm/main/documentation/src/main/asciidoc/userguide/chapters/multitenancy/MultiTenancy.adoc)
- **只设一次 / 块作用域**：Finbuckle 一个 scope 内 TenantInfo 只能设一次 — [Core Concepts](https://www.finbuckle.com/MultiTenant/Docs/CoreConcepts)；ABP \`CurrentTenant.Change\` 必须 \`using\` — [ABP](https://abp.io/docs/latest/framework/architecture/multi-tenancy)；ros-apartment 推荐块形式 "guarantees cleanup on exceptions" — [ros-apartment](https://github.com/rails-on-services/apartment)
- **中间件顺序**：ABP \`UseMultiTenancy()\` 放在认证后 — [ABP](https://abp.io/docs/latest/framework/architecture/multi-tenancy)；Apartment 建议插在 \`Warden::Manager\` 之前让 Devise 在租户上下文里运行 — [influitive/apartment](https://github.com/influitive/apartment)；django-tenants 中间件放第一位 — [install](https://django-tenants.readthedocs.io/en/latest/install.html)
- **后台作业**：acts_as_tenant 把租户写进 ActiveJob 参数 / Sidekiq job hash — [acts_as_tenant](https://github.com/ErwinM/acts_as_tenant)；stancl \`QueueTenancyBootstrapper\` 把租户 ID 写进 payload，作业执行前初始化租户，\`$forceRefresh\` 每个作业重新初始化 — [bootstrappers](https://tenancyforlaravel.com/docs/v3/tenancy-bootstrappers)；Spatie \`TenantAware\` / \`NotTenantAware\` — [Spatie queues](https://spatie.be/docs/laravel-multitenancy/v4/basic-usage/making-queues-tenant-aware)；tenant-schemas-celery 把 schema 放进 kwargs — [tenant-schemas-celery](https://github.com/maciej-gol/tenant-schemas-celery)；ros-apartment："Pass tenant names as job arguments and switch in the worker" — [ros-apartment](https://github.com/rails-on-services/apartment)；ABP 作业参数实现 \`IMultiTenant\`（社区）— [ABP support #10688](https://abp.io/support/questions/10688/VoloAIManagementBackgroundJobsIndexDocumentJob-fails-for-tenant-uploads--blob-path-mismatch-caused-by-missing-IMultiTenant-on-IndexDocumentJobArgs)
- **周期性 worker（非请求触发）**：ABP 默认以 host 运行，需遍历租户逐个 \`Change\` — [ABP support #9458](https://abp.io/support/questions/9458/Is-BackgroundWorker-Tenant-Safe)；ros-apartment 提供 \`Tenant.each(names, release_connection: true)\`，反对手写循环 — [ros-apartment](https://github.com/rails-on-services/apartment)
- **消息/事件**：ABP 分布式事件把 TenantId 写进事件 ExtraProperties 头 — [ABP OutgoingEventInfo.cs](https://github.com/abpframework/abp/blob/dev/framework/src/Volo.Abp.EventBus.Abstractions/Volo/Abp/EventBus/Distributed/OutgoingEventInfo.cs)；按租户分库时 ABP outbox/inbox 曾不支持（需轮询每个租户库）— [ABP issue #10036](https://github.com/abpframework/abp/issues/10036)
- **实时通道**：acts_as_tenant 要求 Action Cable \`stream_from\` 块内用 \`with_tenant\`，在 \`before_subscribe\` 设租户 "won't work" — [acts_as_tenant](https://github.com/ErwinM/acts_as_tenant)
- **缓存**：ABP 自动在 key 加租户 ID，\`[IgnoreMultiTenancy]\` 退出 — [ABP Caching](https://abp.io/docs/latest/framework/fundamentals/caching)；django-tenants \`make_key\` 加 schema 前缀 — [install](https://django-tenants.readthedocs.io/en/latest/install.html)；stancl 用 cache tag，Redis 直连用前缀 — [bootstrappers](https://tenancyforlaravel.com/docs/v3/tenancy-bootstrappers)；Spatie 改 \`cache.prefix\` — [Spatie cache](https://spatie.be/docs/laravel-multitenancy/v4/using-tasks-to-prepare-the-environment/prefixing-cache)；Hibernate 二级缓存 key 默认区分租户 — [Hibernate](https://raw.githubusercontent.com/hibernate/hibernate-orm/main/documentation/src/main/asciidoc/userguide/chapters/multitenancy/MultiTenancy.adoc)；activerecord-tenanted 只保证 AR 缓存 key，\`Rails.cache\` 需自己处理 — [GUIDE.md](https://github.com/basecamp/activerecord-tenanted/blob/main/GUIDE.md)
- **文件存储/日志**：stancl 给 storage 路径加 \`tenant{id}\` 后缀，日志不分租户 — [bootstrappers](https://tenancyforlaravel.com/docs/v3/tenancy-bootstrappers)；Orchard Core 每租户 \`App_Data\Sites\[Tenant]\` — [Orchard Core](https://docs.orchardcore.net/en/latest/reference/modules/Tenants/)
- **数据库会话级上下文（RLS）**：stancl v4 用 PG 会话变量 \`my.current_tenant\` 传租户给 RLS 策略，并警告事务模式连接池会破坏会话变量 — [Tenancy v4 RLS](https://v4.tenancyforlaravel.com/postgres-rls/)

### Inferences
- Rust/axum 对应物：请求入口用中间件/extractor 解析出 \`TenantId\`，放进 request extensions 并（如需隐式传递）用 \`tokio::task_local!\` 包住 handler future——这与 \`AsyncLocal\` / \`CurrentAttributes\` 是同一模式；注意 \`tokio::spawn\` 出去的任务不继承 task-local，等价于 Finbuckle「后台工作需捕获 scope」的问题，需显式传。
- 若用 RLS：sqlx 每个事务里 \`SELECT set_config('app.tenant_id', $1, true)\`（事务级 \`is_local=true\`），即可规避 stancl/ros-apartment 文档提到的「连接池复用导致会话变量串租户」问题。这是推论，非上述框架文档原文。
- 作业/事件统一做法可总结为：消息 envelope 里强制字段 \`tenant_id\`（可空=平台级），消费端先建上下文再执行；周期任务显式「遍历租户」。

### Gaps
- 未找到官方文档系统讨论「日志/trace 里带租户字段」的规范（仅 stancl 提到日志不分租户目录）。

---

## Q4. 「默认租户 / 单租户也当一个租户」有没有框架这么做？单租户和多租户能否同一套代码？

### Takeaway
有，而且是普遍做法：多数框架都有一个「默认/公共/中央」上下文，且同一套代码可在关掉多租户或只有一个租户时运行。但具体语义分两种：**(A) 无租户 = 平台/host 上下文**（ABP host、stancl central app、django-tenants public schema），**(B) 回退到一个固定租户**（ABP \`FallbackTenant\`、Finbuckle Static 策略、Orchard Core \`Default\` 租户）。官方都提醒两者有取舍：设了固定回退租户就进不了 host。

### Cited Findings
- ABP：多租户可通过 \`IsEnabled\` 关闭，关闭时同一套代码（实体仍有 TenantId，值为 null）单租户运行；\`FallbackTenant\` 设默认租户但 "no way to switch to the host side" — [ABP Multi-Tenancy](https://abp.io/docs/latest/framework/architecture/multi-tenancy)
- Finbuckle：\`WithStaticStrategy\` 给固定标识且总是最后执行（即「其他策略都没命中时落到默认租户」）— [Finbuckle Strategies](https://www.finbuckle.com/MultiTenant/Docs/Strategies)
- Orchard Core：存在名为 \`Default\` 的租户，它有特权（建 Feature Profiles 管其他租户）且有自己的 \`Default:TablePrefix\` — [Orchard Core Tenants](https://docs.orchardcore.net/en/latest/reference/modules/Tenants/)
- django-tenants：建议给主域名建一个租户，通常落在 \`public\` schema；\`PUBLIC_SCHEMA_URLCONF\` 让主站与租户站路由不同 — [django-tenants](https://django-tenants.readthedocs.io/en/latest/)；[install](https://django-tenants.readthedocs.io/en/latest/install.html)
- Apartment：\`switch\` 无参数回到默认租户 \`public\`；出错时自动切回 public — [influitive/apartment](https://github.com/influitive/apartment)；ros-apartment 的 \`pin_tenant\` / \`with_default_tenant\` 把全局模型钉在默认 schema — [ros-apartment](https://github.com/rails-on-services/apartment)
- stancl：central application "is executed when there is no tenant"（注册、平台管理）— [The two applications](https://tenancyforlaravel.com/docs/v3/the-two-applications)
- Basecamp activerecord-tenanted 的目标："Developing a multi-tenant Rails app should be as easy as developing a single-tenant app" — [activerecord-tenanted](https://github.com/basecamp/activerecord-tenanted)
- Azure 架构中心：同时支持单租户部署和多租户部署时 "Your codebase needs to be designed to support both multitenant and single-tenant deployments"；并区分「逻辑租户」与「部署」：共享部署时靠应用代码 + 数据库里的租户标识隔离，独立部署时代码 "might be less important ... to account for a multitenant environment" — [Azure Tenancy models](https://learn.microsoft.com/en-us/azure/architecture/guide/multitenant/considerations/tenancy-models)
- 反例/提醒：django-multitenant、stancl 单库模式在「未设租户」时退化为不过滤（单租户运行正常，但多租户下是泄露风险）— [django-multitenant](https://github.com/citusdata/django-multitenant)；[stancl single-db](https://tenancyforlaravel.com/docs/v3/single-database-tenancy)

### Inferences
- 「单租户 = 只有一个租户的多租户」在数据层（每行都有 tenant_id，种子数据建一个 default 租户）是最不分叉的写法：代码路径完全一致，以后开多租户无需迁移数据。代价是 host/平台管理员的语义要单独设计（ABP 的 null TenantId，或一个保留的平台租户）。
- 选「回退到默认租户」时要注意 ABP 文档的警告：回退会吞掉「无租户」这个状态，平台级操作需另走显式通道。

### Gaps
- 未找到某框架明确把「单租户产品」官方定义为「tenant_id 固定为某常量的多租户」的文档；以上为各框架的近似机制。

---

## Q5. 共同的最佳实践清单与反模式

### Takeaway
各框架文档反复出现的规则高度一致：租户 ID 不可变、块作用域切换、fail-closed、唯一约束含 tenant_id、原生 SQL/批量操作是盲区、跨进程必须显式传租户、缓存按租户分 key、别自建 IdP、用户跨租户要有显式切换。

### Cited Findings — 最佳实践
- 租户 ID 在创建时设定且不再修改 — [ABP](https://abp.io/docs/latest/framework/architecture/multi-tenancy)；\`Id\` 永不变、与可变的 \`Identifier\` 分离 — [Finbuckle Core Concepts](https://www.finbuckle.com/MultiTenant/Docs/CoreConcepts)
- 用块/using 作用域切换租户，保证异常时恢复 — [ros-apartment](https://github.com/rails-on-services/apartment)；[ABP](https://abp.io/docs/latest/framework/architecture/multi-tenancy)
- 没有租户时报错或返回空，不要静默全量：acts_as_tenant \`require_tenant\` — [acts_as_tenant](https://github.com/ErwinM/acts_as_tenant)；Finbuckle v11 返回 0 行 — [Finbuckle EF Core](https://www.finbuckle.com/MultiTenant/Docs/EFCore)；activerecord-tenanted 抛 \`NoTenantError\` — [GUIDE.md](https://github.com/basecamp/activerecord-tenanted/blob/main/GUIDE.md)；ros-apartment \`require_tenant!\` — [ros-apartment](https://github.com/rails-on-services/apartment)
- 唯一索引/唯一校验带 tenant_id：\`validates_uniqueness_to_tenant\` — [acts_as_tenant](https://github.com/ErwinM/acts_as_tenant)；stancl 唯一索引 \`(tenant_id, slug)\` — [stancl single-db](https://tenancyforlaravel.com/docs/v3/single-database-tenancy)；Finbuckle 唯一索引含 TenantId — [Finbuckle EF Core](https://www.finbuckle.com/MultiTenant/Docs/EFCore)
- 外键/关联校验同租户：acts_as_tenant 校验 \`belongs_to\` 指向当前租户（\`tenant_mismatch\`）— [acts_as_tenant](https://github.com/ErwinM/acts_as_tenant)；django-multitenant 建含 tenant_id 的复合外键 + 被引用表 \`unique_together = ["id", "store"]\` — [django-multitenant](https://github.com/citusdata/django-multitenant)
- 在中间件里一次性设置租户，而不是每个视图各自设 — [django-multitenant](https://github.com/citusdata/django-multitenant)
- 认证 claims 优先于 header/query 等客户端可控来源 — [ABP](https://abp.io/docs/latest/framework/architecture/multi-tenancy)
- 中央作业和租户作业分队列连接 — [stancl Queues](https://tenancyforlaravel.com/docs/v3/queues)
- 用成熟 IdP、不自建身份认证（Azure 视为 antipattern）；用户跨租户时：凭证只存一份，"a tenant identifier claim is added to the token"，并提供 "A clear mechanism ... to switch between tenants" 以 "prevents accidental cross-tenant access" — [Azure Identity considerations](https://learn.microsoft.com/en-us/azure/architecture/guide/multitenant/considerations/identity)
- 授权/权益分离：不要从用户角色推断租户权益，"don't use feature flags as a permanent licensing system"；权益在应用库或独立服务管理，登录时注入 token claims — 同上
- 隔离是连续谱，可以按层选择不同隔离级别（应用层共享、库分开等）— [Azure Tenancy models](https://learn.microsoft.com/en-us/azure/architecture/guide/multitenant/considerations/tenancy-models)

### Cited Findings — 反模式
- 原生 SQL、\`unscoped\`、计数器、\`update_column(s)\`、\`upsert_all\` 绕过租户作用域 — [acts_as_tenant](https://github.com/ErwinM/acts_as_tenant)；Hibernate 原生 SQL / 存储过程 / JDBC 不改写，HQL insert 不自动填租户 — [Hibernate](https://raw.githubusercontent.com/hibernate/hibernate-orm/main/documentation/src/main/asciidoc/userguide/chapters/multitenancy/MultiTenancy.adoc)；stancl "can only provide scoping logic for ... Eloquent" — [stancl single-db](https://tenancyforlaravel.com/docs/v3/single-database-tenancy)
- 只靠 RLS 当安全边界：stancl v4 明说 "not a security boundary"（无策略表、级联删除、外键检查、TRUNCATE 都是缺口）— [stancl v4 RLS](https://v4.tenancyforlaravel.com/postgres-rls/)
- PgBouncer 事务池 + search_path/会话变量 → 串租户 — [ros-apartment](https://github.com/rails-on-services/apartment)；[stancl v4 RLS](https://v4.tenancyforlaravel.com/postgres-rls/)
- 在已有跟踪实体的上下文里换租户 — [Finbuckle EF Core](https://www.finbuckle.com/MultiTenant/Docs/EFCore)；在同一 Hibernate Session 里换租户 — [Hibernate](https://raw.githubusercontent.com/hibernate/hibernate-orm/main/documentation/src/main/asciidoc/userguide/chapters/multitenancy/MultiTenancy.adoc)
- 直接写全局上下文变量而不走块作用域（ros-apartment 用 RuboCop 拦截）— [ros-apartment](https://github.com/rails-on-services/apartment)
- 为「数据只属于某用户」这种简单需求上多租户包 — [stancl Introduction](https://tenancyforlaravel.com/docs/v3/introduction)
- 直接查询次级模型（\`Comment::all()\`）而非经父关系 — [stancl single-db](https://tenancyforlaravel.com/docs/v3/single-database-tenancy)
- 自建 IdP — [Azure Identity considerations](https://learn.microsoft.com/en-us/azure/architecture/guide/multitenant/considerations/identity)
- 跨 schema 用 \`has_and_belongs_to_many\` — [ros-apartment](https://github.com/rails-on-services/apartment)

### Inferences
- 针对本项目三个待决问题，框架证据指向：
  1. **租户身份放哪**：ABP（Isolated 与 Shared 两种）都把「用户 ↔ 租户」关系放在身份模块，租户元数据（名称、状态、连接串）放在租户管理模块，业务数据只存 tenant_id。对应到本项目：tenants 表 + 成员关系放 idm、JWT 带 \`tid\`，app schema 只存 \`tenant_id\` 列——与 ABP「claims 解析器第一」一致。
  2. **一个账号一个还是多个租户**：一对一（ABP Isolated 默认）实现最简单；一对多（ABP Shared、django-tenant-users、Azure 指南）需要成员关系表、登录后选租户/切租户、用户名全局唯一、安全策略上移到平台级。若将来可能一对多，**一开始就用「全局账号 + memberships 表」建模、先限制每人一个 membership**，比日后从 users.tenant_id 迁移便宜（推论）。
  3. **数据隔离**：单机 compose + sqlx（无 ORM 拦截）下，共享表 + \`tenant_id NOT NULL\` + 复合唯一/外键 + 仓储层强制传租户，再用 RLS（事务级 \`set_config\`）做纵深防御，是与 2026 主流方向一致且运维最省的组合；schema-per-tenant 的维护成本已被 ros-apartment 自己记录在案。

### Gaps
- 没找到横向对比上述框架「性能/租户规模上限」的权威数据。
- Spring 官方（Spring Boot / Spring Framework）没有一手多租户文档，Spring 部分只能以 Hibernate 文档 + 社区实现代替。
