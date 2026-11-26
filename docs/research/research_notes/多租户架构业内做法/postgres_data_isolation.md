# PostgreSQL 多租户数据隔离方案(业内做法事实笔记,2024–2026)

> 调研日期:2026-11-25。当前 PostgreSQL 官方文档的 "current" 已是 **PostgreSQL 19**(官方页横幅称 19 于 2026-11-19 发布)— [PG docs 5.10 Row Security Policies](https://www.postgresql.org/docs/current/ddl-rowsecurity.html)。
> 说明:AWS Prescriptive Guidance《Implementing managed PostgreSQL for multi-tenant SaaS applications on AWS》各子页面本次直接抓取均返回 404(疑似改版/迁移),相关条目只能依据搜索引擎摘要引用,已在条目里标注「摘要」。

---

## 1. 三种隔离模型:共享表 + tenant_id / 每租户一个 schema / 每租户一个数据库

### Takeaway
业内主流(AWS、Citus、PlanetScale、Crunchy、Supabase、Nile)对「单库多租户、租户数可能上千」的场景都首推 **共享表 + tenant_id(pool 模型)+ RLS 兜底**;schema-per-tenant 在 2025–2026 的厂商文章里普遍被降级为「不推荐 / 只适合几百个租户以内」;database-per-tenant 隔离最强,但在**单个 PG 实例**里受连接池按库切分和每库目录开销限制,真正发挥优势要配合 Neon 这类「每租户一个项目/实例」的托管平台。

### Cited Findings
**术语(AWS silo / bridge / pool)**
- AWS 把 PG 多租户分为三种:silo = 每租户独立 PG 实例/集群;bridge = 同一实例里每租户一个 database,或同一 database 里每租户一个 schema;pool = 所有租户共用同一实例、同一 schema 的表(摘要)— [AWS Prescriptive Guidance: partitioning models](https://docs.aws.amazon.com/prescriptive-guidance/latest/saas-multitenant-managed-postgresql/partitioning-models.html);[bridge 页](https://docs.aws.amazon.com/prescriptive-guidance/latest/saas-multitenant-managed-postgresql/bridge.html)
- AWS:bridge 模型「suffers from the same noisy neighbor and tenant performance isolation concerns as the pool model」,并把 bridge 描述为 RLS 的替代,代价是租户开通时要新建 database/schema(摘要)— [AWS bridge 页](https://docs.aws.amazon.com/prescriptive-guidance/latest/saas-multitenant-managed-postgresql/bridge.html)
- AWS:pool 模型下「Row-level security (RLS) is required to maintain tenant data isolation」,因为 pool 模型没有按租户的基础设施/库/schema 逻辑隔离;pool 模型「noisy neighbor phenomenon cannot be completely eliminated」,且有些客户会认为 RLS 的逻辑隔离不够、要求更强隔离(摘要)— [AWS FAQ](https://docs.aws.amazon.com/prescriptive-guidance/latest/saas-multitenant-managed-postgresql/faq.html);[AWS pool 页](https://docs.aws.amazon.com/prescriptive-guidance/latest/saas-multitenant-managed-postgresql/pool.html)

**租户数上限 / 规模**
- Citus 12(2023-07)对比表:schema-based 适合 **1–10k** 租户,row-based 适合 **100–1M+**;「carefully consider your sharding model if you expect to have over 10k schemas」;原因之一是「each process keeps a separate catalog cache, which can cause high memory consumption when there are many tables」— [Citus 12 blog](https://www.citusdata.com/blog/2023/07/18/citus-12-schema-based-sharding-for-postgres/)
- PlanetScale(Simeon Griggs,2026-04-21):shared-schema「can easily scale to many thousands of tenants」;schema-per-tenant 与 database-per-tenant 都「likely won't scale beyond a few hundred tenants」;每个 database 约 8 MB 模板开销 + 独立系统目录 — [PlanetScale: Approaches to tenancy in Postgres](https://planetscale.com/blog/approaches-to-tenancy-in-postgres)
- 不同来源对 schema-per-tenant 的「极限」说法差异很大(几百 / ~5000 / 1k–10k),多为厂商博客、非可复现基准 — 汇总见 [PlanetScale](https://planetscale.com/blog/approaches-to-tenancy-in-postgres) 与 [Citus 12](https://www.citusdata.com/blog/2023/07/18/citus-12-schema-based-sharding-for-postgres/)(两者结论冲突:几百 vs 10k)
- 2012 年 pgsql-hackers 讨论「pg_dump and thousands of schemas」:慢的根因是表数量(约 18.4 万张表)而非 schema 数本身,即使 `pg_dump -n schema_name` 也慢 — [pgsql-hackers thread](https://www.postgresql.org/message-id/1352284972611-5730998.post%40n5.nabble.com)(注:2012 年旧证据,pg_dump 之后有过多次优化)

**隔离强度**
- PlanetScale:shared-schema「is the most exposed because tables and indexes are shared」;schema-per-tenant「There is no database-level enforcement of preventing access to the wrong schema」(即 search_path / 拼错 schema 照样能读别人的);database-per-tenant「is the most isolated from a security perspective」;三者共享 CPU/内存/IO/连接,「One tenant running an expensive query degrades performance for all other tenants」— [PlanetScale](https://planetscale.com/blog/approaches-to-tenancy-in-postgres)
- Citus:schema-based 的访问控制靠 schema 权限,row-based 靠 RLS;schema-based 不能跨分布式 schema 建外键,不支持跨租户并行查询 — [Citus 12 blog](https://www.citusdata.com/blog/2023/07/18/citus-12-schema-based-sharding-for-postgres/)

**迁移成本**
- PlanetScale:shared-schema「Migrations and schema changes need only be applied to a single table to update all tenants」;schema-per-tenant「need to be applied to each tenant's schema」;database-per-tenant 每新增租户都要建库并跑一遍迁移 — [PlanetScale](https://planetscale.com/blog/approaches-to-tenancy-in-postgres)
- 博客估算:每 schema 迁移 200 ms × 2000 租户 ≈ 7 分钟,需要按 schema 记录版本、可续跑的迁移执行器(二手博客,未独立验证)— 见搜索汇总 [dev.to: schema-per-tenant vs RLS](https://dev.to/zoomapps/multi-tenant-saas-on-postgresql-schema-per-tenant-vs-row-level-security-332f)

**连接数**
- PlanetScale:「Connection limits are the primary issue with database-per-tenant multi-tenancy」— [PlanetScale](https://planetscale.com/blog/approaches-to-tenancy-in-postgres)
- PG 连接绑定到单个 database;PgBouncer/Neon pooler 的池是「per user and per database」维度划分的,所以 N 个租户库 = N 个池 — [Neon connection pooling](https://neon.com/docs/connect/connection-pooling)
- sqlx 讨论里有人试「每请求建一个池 + after_connect 里 SET 租户」,1000 请求 23.0 s vs 共享池 11.4 s,约慢 2 倍(社区个人测试)— [sqlx discussion #2783](https://github.com/launchbadge/sqlx/discussions/2783)

**单租户删除 / 导出 / 备份**
- PlanetScale:shared-schema 删除租户会产生大量 dead tuples、加重 vacuum,除非按租户分区后直接 drop 分区;schema-per-tenant 一条 `DROP SCHEMA`;database-per-tenant 一条 `DROP DATABASE`,「no side effects」— [PlanetScale](https://planetscale.com/blog/approaches-to-tenancy-in-postgres)
- Neon 推荐 project-per-tenant(每租户一个 Neon 项目),理由包括完全隔离、区域合规、**按租户 PITR**、独立扩缩容;Neon「generally」不推荐 schema-per-tenant(不降低运维复杂度和成本、增加风险、限制按客户 PITR);shared schema 是「a common choice」、合理起点;Launch 计划 100 个项目、Scale 1000 个 — [Neon multitenancy guide](https://neon.com/docs/guides/multitenancy)
- Neon 客户案例(LuBot)提醒:若用 search_path 切 schema,要按查询或按 role 设,并在连接归还时重置,否则会话状态跨租户泄漏 — [Neon: LuBot database-per-tenant](https://neon.com/blog/inside-lubots-database-per-tenant-architecture)

**托管平台的「虚拟租户库」**
- Nile:一个 PG 服务里多个「virtual tenant databases」;应用对连接执行 `set nile.tenant_id = '...'` 后只能看到该租户的数据,「setting a session context to a specific tenant is equivalent to pointing the connection to a specific tenant DB」;**不设租户时**「the connection can access across all the tenant DBs」;租户放到独立硬件仍是「coming soon」— [Nile docs: tenant isolation](https://www.thenile.dev/docs/tenant-virtualization/tenant-isolation)

### Inferences
- 对「单机 docker compose、一个 PG 实例」的形态:database-per-tenant 的「强隔离」主要优势(按租户 PITR、独立资源)在单实例上拿不到 —— 同一实例共享 WAL/备份/CPU;却要付出「每租户一个连接池」和「迁移 N 次」的成本。schema-per-tenant 同理且不提供数据库层的强制隔离。共享表 + tenant_id 是成本最低、文档最多的路径,与 AWS/Citus/PlanetScale 的推荐一致。
- 共享表模式下的「单租户导出/删除」可以靠:所有租户表带 `tenant_id` → 按 tenant_id 的 `COPY (SELECT ...) TO` 导出、批量 DELETE(或租户量大时按 tenant_id LIST/HASH 分区以便 drop 分区)。这是基于 PlanetScale 关于 dead tuple 的描述推得,未见权威基准。

### Gaps
- AWS Prescriptive Guidance 的决策矩阵(matrix.html)原文本次无法直接抓取(404),只拿到搜索摘要;如需逐行矩阵需人工打开核对。
- 没找到可复现的、2024 年后的「单实例 N 个 schema / N 个 database 的性能拐点」基准,各家数字冲突(几百 vs 10k)。

---

## 2. PostgreSQL RLS 的实际用法与坑

### Takeaway
标准做法是:**应用用一个非 owner、非 superuser、无 BYPASSRLS 的角色连库**;租户表 `ENABLE` + `FORCE ROW LEVEL SECURITY`;策略里用 `current_setting('app.tenant_id', true)` 读当前租户,`USING` 与 `WITH CHECK` 都写;在**显式事务里**用 `set_config('app.tenant_id', $1, true)`(即 SET LOCAL 的函数形式,可绑定参数)设置租户。未设置时应返回 0 行(fail closed)。性能上要给 tenant_id 建索引/复合索引,并留意非 LEAKPROOF 函数会阻止索引下推。

### Cited Findings
**机制(官方文档,PG 19)**
- 启用 RLS 后,所有普通的读/改都必须被策略允许;「If no policy exists for the table, a default-deny policy is used」— [PG docs ddl-rowsecurity](https://www.postgresql.org/docs/current/ddl-rowsecurity.html)
- 「Table owners normally bypass row security as well, though a table owner can choose to be subject to row security with ALTER TABLE ... FORCE ROW LEVEL SECURITY」— 同上
- 「Superusers and roles with the BYPASSRLS attribute always bypass the row security system」— 同上
- TRUNCATE、REFERENCES 等整表操作不受 RLS 约束 — 同上
- 只写 USING 时隐式得到相同的 WITH CHECK;也可分开写,使可见性和可修改性不同 — 同上
- 多个策略:permissive(默认)用 OR 合并,restrictive 用 AND 合并 — 同上
- 「Referential integrity checks, such as unique or primary key constraints and foreign key references, always bypass row security」,要防通过约束的「covert channel」泄漏 — 同上
- 备份时可设 `row_security = off`:它不是绕过 RLS,而是「throw an error if any query's results would get filtered by a policy」,防止备份静默丢行 — 同上
- 策略若引用其他表(子查询/函数),在 READ COMMITTED 下有竞态泄漏风险;文档建议尽量让策略只看当前行:「This is the simplest and best-performing case」— 同上
- `set_config(name, value, is_local)`:「If is_local is true, the new value will only apply during the current transaction」;`current_setting(name, missing_ok)`:missing_ok=true 时不存在返回 NULL 而非报错 — [PG docs functions-admin](https://www.postgresql.org/docs/current/functions-admin.html)

**租户上下文的传递方式**
- AWS 推荐「运行时设置租户上下文」而不是「每租户一个 PG 用户」,理由是后者要为每个租户建用户;示例策略比较 `tenant_id` 与 `current_setting('app.current_tenant')::uuid`(摘要)— [AWS Prescriptive Guidance RLS 建议](https://docs.aws.amazon.com/prescriptive-guidance/latest/saas-multitenant-managed-postgresql/rls.html)
- AWS SaaS Factory 示例仓库用 `app.current_tenant`,并建议该值来自「a verified token claim rather than a form field」;管理页面使用一个「deliberately not bound by row level security」的连接 — [aws-samples/aws-saas-factory-postgresql-rls](https://github.com/aws-samples/aws-saas-factory-postgresql-rls)
- Crunchy Data(2024-04-03)示例:`CREATE POLICY ... TO application USING (org_id = NULLIF(current_setting('rls.org_id', TRUE), '')::uuid)`;认为「每请求一个 DB 用户」开销大且放弃了连接池 — [Crunchy Data: RLS for tenants](https://www.crunchydata.com/blog/row-level-security-for-tenants-in-postgres)(注:该文 Python 示例设置的是 `app.current_org_id`,与策略里的 `rls.org_id` 名字不一致,正好是「变量名不一致 → 静默 0 行」的反面教材;文章没讨论连接池/SET LOCAL)
- Svix(Rust 技术栈,2025-11-20):每个请求包在 `SecureTransaction`(基于 SeaORM 的 axum extractor)里,在**事务开始时**写入账户 ID;「attach this information to a database transaction (as opposed to a session)」以避免连接池复用串号;所有表 FORCE RLS;未设置时辅助函数返回 -1 → 看不到任何行,「fails secure」;误用普通连接只会让功能坏掉而不会泄漏 — [Svix: RLS Defense in Depth](https://www.svix.com/blog/row-level-security-defense-in-depth/)

**连接池下的坑(事务外设置泄漏)**
- PgBouncer 官方特性表:transaction pooling 模式**不支持** `SET/RESET`(会话级)、LISTEN、WITH HOLD 游标、SQL 级 PREPARE、会话级 advisory lock 等;协议级预处理语句需 `max_prepared_statements` 非零 — [PgBouncer features](https://www.pgbouncer.org/features.html)
- 机制:会话级 `SET` / `set_config(..., false)` 会留在物理连接上,连接被下一个请求复用时继承上一个租户;sqlx 社区讨论里明确指出「sets this value for the life of the connection」,建议改用事务级 — [sqlx discussion #2783](https://github.com/launchbadge/sqlx/discussions/2783)
- 反向的坑:`SET LOCAL` 在显式事务外执行只会报 WARNING「SET LOCAL can only be used in transaction blocks」且不生效,查询在「没有租户」的状态下运行(若策略 fail-closed 则表现为查不到数据)— 多篇博客一致(二手),例 [DEV: The SET LOCAL advice is right, and it understates the problem](https://dev.to/qays_kadhim_c3fea1c94957f/the-set-local-advice-is-right-and-it-understates-the-problem-1f62)
- `SET LOCAL` 不接受绑定参数,拼字符串有注入风险;`set_config($1, $2, true)` 可参数化 — 见 [sqlx discussion #2783](https://github.com/launchbadge/sqlx/discussions/2783) 中的 `SELECT set_config('app.current_tenant', $1, true)` 示例
- sqlx 事务 drop 时自动回滚,handler 必须显式 commit;另有人建议用池的 `after_release` 钩子清理会话变量(帖中未验证)— [sqlx discussion #2783](https://github.com/launchbadge/sqlx/discussions/2783)
- sqlx 编译期检查宏:若 `DATABASE_URL` 指向受 RLS 约束的角色,检查会失败,建议 DATABASE_URL 指管理员连接、运行时池用受限角色 — [sqlx discussion #2783](https://github.com/launchbadge/sqlx/discussions/2783)

**owner / BYPASSRLS / FORCE 的实践坑**
- Bytebase(2025-09-05)RLS footguns 清单要点:用 superuser/owner 跑测试会「假通过」;只 ENABLE 不 FORCE,应用若以 owner 连接等于没隔离;只写 USING 不写 WITH CHECK 会让用户写入自己读不回来的行;全局唯一索引通过 duplicate key 报错泄漏其他租户是否存在某值(应改为 `(tenant_id, col)` 唯一);RLS 无报错静默过滤,UPDATE 影响 0 行无警告;RLS 只管行不管列;物化视图/导出/后台任务把数据复制出去后不再受策略保护;permissive 策略 OR 合并,新加一条宽策略会扩大访问面(用 RESTRICTIVE)— [Bytebase: Postgres RLS Footguns](https://www.bytebase.com/blog/postgres-row-level-security-footguns/)
- 视图默认以创建者身份执行从而绕过 RLS;PG 15+ 用 `security_invoker = true` — [Supabase RLS docs](https://supabase.com/docs/guides/database/postgres/row-level-security);[Bytebase](https://www.bytebase.com/blog/postgres-row-level-security-footguns/)
- SECURITY DEFINER 函数要 `SET search_path = ''` 并全限定名 — [Supabase RLS docs](https://supabase.com/docs/guides/database/postgres/row-level-security)
- 策略不写 `TO role` 时作用于 PUBLIC — [Supabase RLS docs](https://supabase.com/docs/guides/database/postgres/row-level-security);[PG docs](https://www.postgresql.org/docs/current/ddl-rowsecurity.html)

**性能与索引**
- Supabase 官方:给策略过滤的每一列建索引;列必须是 btree 索引的**前导列**才算被索引(复合主键 `(team_id, user_id)` 不覆盖 `user_id`);把不依赖行数据的函数包成 `(select auth.uid())`,让 PG 生成 initPlan、每语句只算一次而非每行一次 — [Supabase RLS docs](https://supabase.com/docs/guides/database/postgres/row-level-security)
- 同样道理适用于 `(select current_setting('app.tenant_id', true))`(推论自上条,Supabase 文档写的是 auth.uid())。
- 非 LEAKPROOF 的函数/运算符:优化器只会把 leakproof 的条件提前到 RLS 检查之前(官方原文「the optimizer may choose to apply such functions ahead of the row-security check」)— [PG docs](https://www.postgresql.org/docs/current/ddl-rowsecurity.html)。实践后果:用户查询里的 `lower(col) = ...`、某些 LIKE 等非 leakproof 条件无法用索引,需改写或用生成列;托管 PG 上通常改不了函数的 LEAKPROOF 属性 — [Bytebase](https://www.bytebase.com/blog/postgres-row-level-security-footguns/);[pganalyze 5mins E28](https://pganalyze.com/blog/5mins-postgres-row-level-security-bypassrls-security-invoker-views-leakproof-functions)
- 有作者建议在 RLS 之外**仍在应用 SQL 里显式写 `WHERE tenant_id = $1`**,让规划器走索引快路径,RLS 做安全兜底(二手博客)— [DEV: django-rls-tenants index-friendly](https://dev.to/dvoraj75/postgresql-rls-is-fail-closed-but-is-it-fast-making-django-rls-tenants-index-friendly-2j18)
- 策略内跨表 join 代价高;Svix 的对策是把账户 ID 冗余到子表上 — [Svix](https://www.svix.com/blog/row-level-security-defense-in-depth/)

**RLS 相关的 PostgreSQL CVE(说明 RLS 本身也有 bug,要跟 minor 版本)**
- PG 官方安全页列出:CVE-2023-2455(内联后策略忽略 user ID 变化,15.3 修)、CVE-2023-39418(MERGE 不执行 UPDATE/SELECT 策略,15.4 修)、CVE-2024-10976(子查询下的 RLS 忽略 user ID 变化,17.1/16.5/15.9 修),以及 2026 年的 CVE-2026-14666(行安全缓存忽略角色修改,18.6/17.11/16.15/15.19 修)、CVE-2026-120154(`INSERT ... ON CONFLICT` 可读到策略外的行)、CVE-2026-116311(`DROP OWNED` 可删除非自有表上的 restrictive 策略)(后两者 18.7/17.12/16.16/15.20 修)— [PostgreSQL Security Information](https://www.postgresql.org/support/security/)(2026 年条目编号为抓取结果原样转录,建议引用前人工打开核对)
- CVE-2019-10130:规划器统计信息可泄漏 RLS 隐藏行的采样数据,2019 年修复 — [Bytebase](https://www.bytebase.com/blog/postgres-row-level-security-footguns/)(官方当前安全页已不列该条)

### Inferences
- 对 axum + sqlx:最稳的形态是「每个需要租户数据的请求 = 一个 sqlx 事务,事务第一条语句 `SELECT set_config('app.tenant_id', $1, true)`」,与 Svix/sqlx 社区建议一致;这同时绕开了 PgBouncer transaction 模式的会话级 SET 限制(即使当前不用 PgBouncer,未来加上也不用改)。
- 策略写 `NULLIF(current_setting('app.tenant_id', true), '')::uuid` 可同时处理「未设置」(NULL)与「被 RESET 成空串」两种情况,均 fail closed。
- 迁移角色(owner)与运行时角色必须分开;owner 若也是运行时角色,就算 FORCE 了,owner 仍能 `ALTER TABLE ... DISABLE ROW LEVEL SECURITY` / 改策略(官方:启用/禁用及加策略「is always the privilege of the table owner only」)。

### Gaps
- 没有找到官方或可复现的「RLS 对简单 `tenant_id = const` 策略的性能开销」基准;二手博客给的 10×、95% 等数字未验证,不收录为结论。
- PgBouncer 官方文档没有专门讲 RLS 的页面;「SET LOCAL 在 transaction 模式下安全」是从其特性表与 PG 事务语义推得,社区博客一致但无官方声明。

---

## 3. 不用 RLS、靠应用层每条查询带 tenant_id

### Takeaway
应用层过滤仍是最常见的做法(ORM 全局过滤器、仓储基类、请求级 tenant extractor),但所有主流框架的自动过滤都有**绕过口**(原生 SQL、显式忽略过滤器、缓存),因此 2024–2026 的普遍建议是「应用层过滤 + RLS 兜底」(defense in depth),而不是二选一。

### Cited Findings
- EF Core 官方:单库+租户列的场景用 global query filter;过滤器自动作用于 LINQ 查询,包括 navigation/Include;可用 `IgnoreQueryFilters()` 绕过;EF Core 10 起支持具名过滤器(之前租户过滤和软删除过滤只能合成一个表达式,一 Ignore 全没了)— [EF Core Multi-tenancy](https://learn.microsoft.com/en-us/ef/core/miscellaneous/multitenancy);[EF Core Global Query Filters](https://learn.microsoft.com/en-us/EF/core/querying/filters)
- Hibernate `@TenantId`:「automatically set to the current tenant id when the entity is first made persistent. The @TenantId field may not be directly set by the application program」— [Hibernate 7.1 Javadoc TenantId](https://docs.hibernate.org/orm/7.1/javadocs/org/hibernate/annotations/TenantId.html);有博客报告原生 SQL 查询不受 @TenantId 约束(二手)— [DEV: Shared-schema multi-tenancy in Spring Boot + Hibernate](https://dev.to/sushrut_bidwai/shared-schema-multi-tenancy-in-spring-boot-hibernate-the-reference-code-we-actually-run-3pj0)
- Svix:不用 RLS 时「every query must include the account filter」,漏写一个过滤或一次 SQL 注入就能读到别的客户;RLS 是「just one element of a "defense in depth" approach」— [Svix](https://www.svix.com/blog/row-level-security-defense-in-depth/)
- Citus 在 row-based 模型下要求键、join、过滤都包含 tenant 列(否则跨分片)— [Citus 12 blog](https://www.citusdata.com/blog/2023/07/18/citus-12-schema-based-sharding-for-postgres/);Citus 曾为此出 Rails `activerecord-multi-tenant` / Django `django-multitenant` 等库自动注入 tenant 条件 — [Citus: Hibernate & Spring multi-tenant](https://www.citusdata.com/blog/2018/02/13/using-hibernate-and-spring-to-build-multitenant-java-apps/)(2018 年旧文)
- 复合主键 `(tenant_id, id)` 与外键带 tenant_id:Nile 的示例表即用复合主键 `(tenant_id, id)` — [Nile docs](https://www.thenile.dev/docs/tenant-virtualization/tenant-isolation)。好处是外键 `(tenant_id, parent_id) REFERENCES parent(tenant_id, id)` 在数据库层禁止跨租户引用(此为推论,基于 PG 外键语义)。

### Inferences
- 防遗漏手段可分三层(综合上面来源推得):
  1. **类型/结构层**:仓储方法签名强制 `TenantId` 参数(或从 `TenantCtx` extractor 拿到的事务句柄才能执行查询);业务表主键/外键都带 tenant_id;唯一索引改为 `(tenant_id, x)`。
  2. **数据库层兜底**:RLS FORCE + fail closed,应用漏写 WHERE 时最多查不到,而不是查到别人的。
  3. **测试/CI 层**:跨租户集成测试(租户 A 的 token 访问租户 B 的资源 ID 必须 404);迁移审计脚本检查「每张含 tenant_id 的表都 ENABLE+FORCE RLS 且有策略」(tenaxum 提供了类似的 `audit::ensure_isolation`、`audit::scan_migrations`,见第 6 节)。
- 没有找到 sqlx 生态里「检查 SQL 是否带 tenant_id」的通用 lint;sqlx 宏只做类型/语法检查。

### Gaps
- 没有找到权威来源对「纯应用层过滤 vs RLS」的漏洞率做量化对比。

---

## 4. 租户数据泄漏的真实事故与常见原因

### Takeaway
公开事故里,**应用/配置层的「忘了加隔离」**远比 PG 内核 bug 常见:Supabase 上未开 RLS 的表被公开 anon key 直接读写(CVE-2025-48757);连接/缓存层复用导致把 A 的数据返回给 B(ChatGPT 2023-03 redis-py 事故),这和「连接池里残留会话变量」是同一类根因。

### Cited Findings
- **CVE-2025-48757(Lovable + Supabase,2025)**:扫描 1,645 个 Lovable 生成的项目,约 170 个存在未开 RLS 的 Supabase 表、303 个可利用端点,任何拿到公开 anon key 的人可读写;泄漏邮箱、地址、账单、存在表里的 API key;Lovable 对 CVE 有异议,称客户自负数据保护责任 — [GitHub case study](https://github.com/boxed-dev/vibe-coding-security/blob/main/free-case-studies/cve-2025-48757-lovable-rls.md);[securityonline](https://securityonline.info/cve-2025-48757-lovables-row-level-security-breakdown-exposes-sensitive-data-across-hundreds-of-projects/)(注:多为安全厂商二手报道,数字未对 NVD 原文核对)
- **ChatGPT 2023-03-20 事故**:OpenAI 服务端变更导致 Redis 请求取消激增,触发 redis-py asyncio 客户端在 Redis Cluster 下的 bug,连接池中被污染的连接把别的用户的缓存数据返回给当前用户;部分用户看到他人对话标题,约 1.2% 活跃 Plus 用户的姓名、邮箱、地址、卡号后四位等可能暴露;OpenAI 事后加了「返回数据与请求用户匹配」的冗余校验 — [BleepingComputer](https://www.bleepingcomputer.com/news/security/openai-chatgpt-payment-data-leak-caused-by-open-source-bug/);[The Register](https://www.theregister.com/software/2023/03/23/openai-ceo-feels-awful-about-chatgpt-leaking-conversations/333385)
- **常见原因清单**(来源汇总):应用以 owner/superuser/BYPASSRLS 角色连接导致 RLS 不生效;只 ENABLE 不 FORCE;视图/SECURITY DEFINER 函数绕过;物化视图、导出、后台任务把数据拷出 RLS 范围;全局唯一索引通过报错泄漏存在性;会话级 SET 在池化连接上残留 — [Bytebase](https://www.bytebase.com/blog/postgres-row-level-security-footguns/);[Supabase RLS docs](https://supabase.com/docs/guides/database/postgres/row-level-security);[sqlx #2783](https://github.com/launchbadge/sqlx/discussions/2783)
- Nile 的设计本身就是「不设租户上下文 = 可访问所有租户」,说明「漏设上下文」的默认行为取决于实现:Nile 是 fail-open,Svix 的辅助函数返回 -1 是 fail-closed — [Nile docs](https://www.thenile.dev/docs/tenant-virtualization/tenant-isolation);[Svix](https://www.svix.com/blog/row-level-security-defense-in-depth/)
- PG 内核层面的 RLS 绕过也存在,见第 2 节 CVE 列表 — [PostgreSQL Security](https://www.postgresql.org/support/security/)

### Inferences
- 对后台任务(定时任务、事件消费者、导出)要和 HTTP 请求一样显式绑定租户;这类代码路径最容易拿到「裸连接」。tenaxum 专门提供 `spawn_with_tenant` 也说明这是已知痛点(见第 6 节)。
- 管理员/跨租户运维用的 BYPASSRLS 连接应与业务连接池物理分开(AWS 示例也是单独一条「不受 RLS 约束」的连接)。

### Gaps
- 有一些搜索结果称 Supabase 在 2026-04 改了默认值(新 public 表默认不经 Data API 暴露),仅见于二手来源,未在 Supabase 官方 changelog 核实。
- 未找到「因漏写 tenant_id WHERE 条件」导致跨租户泄漏、且有公开复盘的 B2B SaaS 案例(大多是未公开或以 IDOR 归类)。

---

## 5. 对象存储(S3 / MinIO)按租户隔离:前缀 vs 桶 vs 策略

### Takeaway
AWS 官方给两种模式:**共享桶 + 租户前缀**(扩展性好,但版本控制/默认加密等是桶级设置、成本归集难)和**每租户一个桶**(可单独配置、权限/计费简单,但默认配额 10,000 个桶/账号)。真正的隔离来自**策略**:用 IAM/MinIO 策略变量把凭证限制在 `<bucket>/<tenant>/*` 前缀,而不是靠应用拼路径。

### Cited Findings
- AWS 官方「multi-tenant bucket」:单桶 + 唯一前缀,「scales well when you have hundreds of unique datasets」;缺点:默认加密、Versioning、Requester Pays 等是桶级不是前缀级,成本归集复杂 — [S3 common bucket patterns](https://docs.aws.amazon.com/AmazonS3/latest/userguide/common-bucket-patterns.html)
- AWS 官方「bucket-per-use」:每用户/团队一个桶,可单独配置,「simplify both your access management and cost allocation」;缺点是要管理成千上万个桶,「All AWS accounts have a default quota of 10,000 general purpose buckets」,建议在账号区域命名空间建桶避免名字被抢 — 同上
- 2024-11 起 S3 默认配额 10,000 桶/账号,可申请到 100 万;前 2,000 个桶免费,超出按月收费;配额 >10,000 的账号必须用分页 ListBuckets — [AWS What's New 2024-11](https://aws.amazon.com/about-aws/whats-new/2024/11/amazon-s3-up-1-million-buckets-per-aws-account/);[S3 bucket quotas](https://docs.aws.amazon.com/AmazonS3/latest/userguide/BucketRestrictions.html)(旧的「100 桶上限」已过时)
- S3 性能按前缀扩展:每个 partitioned prefix 至少 3,500 写 / **11,000** GET/HEAD 每秒(旧文档常见的 5,500 GET 已被更新)— [S3 optimizing performance](https://docs.aws.amazon.com/AmazonS3/latest/userguide/optimizing-performance.html)
- AWS ABAC 做法:前缀按租户划分,IAM 策略引用 principal tag,如 SageMaker 文档示例资源 `arn:aws:s3:::<bucket>/${aws:PrincipalTag/tenant-id}/*`;租户标签通过 `AssumeRoleWithWebIdentity`(JWT 的 `https://aws.amazon.com/tags` claim)或 `AssumeRole` session tags 注入,需要 `sts:TagSession` 权限 — [AWS Security Blog: SaaS tenant isolation with ABAC using STS tags in JWT](https://aws.amazon.com/blogs/security/saas-tenant-isolation-with-abac-using-aws-sts-support-for-tags-in-jwt/)(正文未能抓取,依据搜索摘要);[SageMaker ABAC 文档](https://docs.aws.amazon.com/sagemaker/latest/dg/model-access-training-data-abac.html)
- MinIO(AIStor 文档)支持策略变量:内置用户 `${aws:username}`、OIDC `${jwt:sub}` / `${jwt:preferred_username}` / `${jwt:groups}` 等、LDAP `${ldap:username}`;示例按用户限制 `s3:ListBucket` 的 `s3:prefix` 条件为 `${aws:username}/*`,读写资源为 `arn:aws:s3:::team-data/${aws:username}/*` — [MinIO AIStor access docs](https://docs.min.io/enterprise/aistor-object-store/administration/iam/access/)
- MinIO OIDC 策略变量只支持固定的一组 jwt claim,任意自定义 claim 不能直接当变量 — [minio discussion #17164](https://github.com/minio/minio/discussions/17164)
- **已变化的现状(2025–2026)**:MinIO 社区版 2025-10 停止发布预编译二进制与容器镜像、2025-12-03 宣布进入维护模式(只按个案评估安全修复),仓库后来被归档(归档日期来源冲突:2026-02 vs 2026-04-25);社区版仍是 AGPLv3、只能源码自建,活跃开发转向商业版 AIStor — [vonng: MinIO is dead](https://vonng.com/en/db/minio-is-dead/);[StableBuild](https://www.stablebuild.com/blog/minio-images-disappeared-from-docker-hub);[linuxiac](https://linuxiac.com/minio-ends-active-development/)(均为二手报道)

### Inferences
- 对后端统一代理上传/下载(前端拿预签名 URL)的架构:隔离点在后端签名时拼 `tenants/{tenant_id}/...` 前缀并校验对象归属;存储侧用**单桶 + 租户前缀**即可,桶级差异化配置需求不大时没必要每租户一个桶。若想把「后端拼错前缀」也兜住,可让后端用按租户下发的受限凭证(STS + 策略变量)而非一个全权 root key,代价是凭证管理复杂度。
- 2026 年在自托管 compose 里继续以 MinIO 社区版为默认对象存储有维护风险,选型时应作为单独议题(可能的替代如 Garage、SeaweedFS、RustFS 等未在本次调研范围内核实)。
- 单租户删除:前缀模式下要列举并删除整个前缀(或用生命周期规则),每租户一个桶则可直接清空删桶 — 推论,未找到量化来源。

### Gaps
- AWS SaaS Lens / Tenant Isolation Strategies 白皮书中关于 S3「pooled storage isolation」的原文本次抓取只返回目录页,未拿到原句。
- 未核实 MinIO 社区版最后一个发布版本是否支持上面 AIStor 文档里的全部策略变量(文档已迁到 AIStor 名下)。

---

## 6. Rust / sqlx 生态里的 RLS / 租户过滤实践

### Takeaway
sqlx 本身没有多租户支持,官方无文档;社区共识是「每请求一个事务 + `set_config('app.tenant_id', $1, true)`」。现成 crate 很少:**tenaxum 0.2.0**(axum 0.8 + sqlx 0.8,task-local 传租户 + 池钩子设 GUC + 启动审计)是最贴近的;Svix 在生产中用 SeaORM 实现了同样思路的 `SecureTransaction` extractor(未开源为 crate)。

### Cited Findings
- **sqlx discussion #2783「Strategies for multi-tenancy」**(2023-09 开、至今标记 Unanswered,无维护者答复):方案依次为 ① 连接选项里固定租户(改池选项只影响新连接,不可行)② 每请求新建池(约慢 2 倍)③ 显式 `WHERE tenant_id = $1` ④ 事务内 `set_config(..., true)`(推荐)⑤ 预留连接 ⑥ axum extractor 取连接后会话级设置(被指出有串号风险);附带提醒:事务 drop 即回滚须显式 commit、`after_release` 可清理、编译期检查宏的 DATABASE_URL 要用管理员连接 — [sqlx discussion #2783](https://github.com/launchbadge/sqlx/discussions/2783)
- **tenaxum**(docs.rs,v0.2.0,MIT,依赖 axum ^0.8、sqlx ^0.8、tokio ^1、uuid ^1):租户存在 Tokio task-local 中,不跨 task,派生任务用 `pool::spawn_with_tenant` / `pool::scope_tenant`;认证中间件把 `TenantId` 放进 request extensions,`pool::tenant_scope` 中间件把它作用到 handler 调用链,**池钩子在借出连接时设置 GUC、归还时重置**;作业/脚本路径用 `PgPoolExt::begin_tenant` 开事务并 `SET LOCAL`;默认 GUC `app.tenant_id`、列 `tenant_id`;要求非超级用户连接、表 ENABLE+FORCE RLS、策略自己写;提供 `audit::ensure_isolation`(启动时审计,建议发现问题即 fail closed)和 `audit::scan_migrations`(轻量 lint);明确声明「A syntactically valid policy can still be wrong」「Postgres superusers bypass RLS unconditionally」— [docs.rs/tenaxum](https://docs.rs/tenaxum/latest/tenaxum/)
- **axum-tenancy**(crates.io):较老、基于 axum-login,示例是 SQLite,不涉及 PG RLS — [crates.io/axum-tenancy](https://crates.io/crates/axum-tenancy)
- **Svix**(Rust,2025-11):axum extractor `SecureTransaction` 基于 SeaORM,事务开始时写入账户 ID;FORCE RLS;未设置时 fail closed — [Svix blog](https://www.svix.com/blog/row-level-security-defense-in-depth/)
- 开源 starter「rust-axum-multitenant-starter」(axum + sqlx + JWT)采用 tenant_id 列 + extractor,而非 RLS — [GitHub Nahianether/rust-axum-multitenant-starter](https://github.com/Nahianether/rust-axum-multitenant-starter)(未审阅代码质量)

### Inferences
- tenaxum 的 HTTP 路径是「借出连接时设会话级 GUC、归还时重置」,依赖池钩子正确执行;若之后在前面加 PgBouncer transaction 模式,会话级设置就不再可靠 —— 其作业路径的 `SET LOCAL` 事务模式更稳。是否采用它需评估:0.x 版本、维护活跃度未核实。
- 自己实现的最小形态(综合 sqlx #2783 与 Svix):一个 axum extractor 从已验证的 JWT/会话里取 tenant_id → `pool.begin()` → `SELECT set_config('app.tenant_id', $1, true)` → 把 `Transaction<'_, Postgres>` 交给仓储;仓储函数只接受这种「已绑租户的事务」类型,不接受裸 `PgPool`,用类型系统防止绕过。

### Gaps
- tenaxum 的 crates.io 下载量、维护者、最近发布日期未核实。
- 没找到 SeaORM / Diesel 官方的多租户 RLS 文档。
- 未找到 sqlx 维护者对 RLS 的官方表态。
