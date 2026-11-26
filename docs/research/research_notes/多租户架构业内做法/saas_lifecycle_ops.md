# B2B SaaS 的租户生命周期、授权与运维实践（2024–2026 现行做法）

> 调研日期：2026-11-25。资料以各产品官方帮助文档、Microsoft Azure Architecture Center（多租户指南）、AWS Well-Architected SaaS Lens、PostgreSQL 官方文档为主。
> 标注说明：大多数产品帮助页**没有显示「最后更新日期」**（只有 ©2026 页脚），下文凡是页面给出了日期的都单独写出。
> Azure 多租户指南几篇的元数据：tenant-life-cycle ms.date 2025-06-13 / updated_at 2026-11-16；identity ms.date 2025-12-16；domain-names ms.date 2025-06-13 / updated_at 2026-11-06；tenancy-models ms.date 2025-06-11。AWS SaaS Lens 的发布日期是 **2023-04-04**，是 AWS 目前仍在用的官方 lens（在 Well-Architected Tool 的 Lens Catalog 里），但比 Azure 那组旧。

---

## 1. 主流 B2B 产品的租户 / 成员 / 角色模型（一个人能不能在多个组织里，怎么切换）

### Takeaway
所有被查的产品（GitHub、Slack、Linear、Notion、Atlassian）以及身份平台（Auth0、Clerk、WorkOS）都是**「一个全局账号 + 多条组织成员关系（membership）」**的结构：同一个登录身份可以属于多个组织，角色挂在成员关系上，不挂在账号上；前端有一个明确的「当前组织」切换器，后端令牌带一个当前组织 ID（如 `org_id`）。只有企业托管账号（GitHub EMU、Atlassian managed accounts）会把账号锁进单个组织/企业边界里。

### Cited Findings

**通用指南（Azure / AWS）**
- Azure 建议：尽可能「每个人一个身份」（single identity per person），因为它让账号管理更简单，而且 IdP 的很多威胁防护都依赖「一个人一个账号」；只有工作/个人分离或有严格的监管/地域要求时，才给同一个人建多个身份。用每租户身份时，凭据也只能存一份，靠 guest identity 之类的引用指过去。 — [Azure: Identity in multitenant](https://learn.microsoft.com/en-us/azure/architecture/guide/multitenant/considerations/identity)
- Azure 给了两种身份信息的存放方式：①全部身份和授权信息都放在 IdP 目录里，在租户之间共享；②**凭据放 IdP，授权数据（租户角色/权限）放应用层、和租户信息放在一起**。 — [Azure: Identity](https://learn.microsoft.com/en-us/azure/architecture/guide/multitenant/considerations/identity)
- 用户和租户的映射「应当基于租户和用户双方不可变的唯一 ID 来存」。如果一个用户只能属于一个租户，要决定 IdP 怎么认出租户，通常是「在令牌里加一个 tenant identifier claim」；如果一个用户能属于多个租户，就要有跨租户的权限逻辑（在 A 是管理员、在 B 是普通成员）、「清楚的租户切换机制，防止误跨租户访问」，还要防止租户 A 往用户档案里补的信息被租户 B 看到。 — [Azure: Identity › Grant users access to tenant data](https://learn.microsoft.com/en-us/azure/architecture/guide/multitenant/considerations/identity)
- Azure 建议用不可变 ID 做授权和审计（例如 Entra 的 OID），不要用会变的 UPN/邮箱。 — [Azure: Identity](https://learn.microsoft.com/en-us/azure/architecture/guide/multitenant/considerations/identity)
- **Azure 明确把「自己造 IdP」列为反模式**：「Building your own IdP is complex, expensive, and challenging to secure. It's considered an antipattern」。 — [Azure: Identity](https://learn.microsoft.com/en-us/azure/architecture/guide/multitenant/considerations/identity)
- AWS SaaS Lens SEC 1 的要求：
  - 租户要在一个**独立于用户的集中服务**里管理；
  - 每个租户有内部唯一 ID、可读名称、**active/inactive 状态（用来开关访问）**、tier/plan；
  - 登录后加一步「post-authentication」生成给下游用的令牌；
  - **用户属于多个租户时，加一步让用户选目标租户**；
  - 令牌里只放必要的租户属性（custom claims），不要塞细粒度授权，并且要签名。 — [AWS SaaS Lens SEC 1](https://wa.aws.amazon.com/saas.question.SEC_1.en.html)
- AWS 把「用户身份绑定租户」称为 *SaaS identity*：租户上下文要能随 JWT 流过所有服务，「不需要再往返另一个服务」去查。 — [AWS SaaS Lens: Identity and access management](https://docs.aws.amazon.com/wellarchitected/latest/saas-lens/identity-and-access-management.html)
- Azure 把授权模型分成两类，一类是按角色（role-based），一类是按资源（resource-based，每个资源一套权限）。它还建议**授权 ≠ 授权许可（entitlement）**：许可要在应用代码或专门的 entitlements 系统里跟踪，「Don't infer tenant entitlements from a user's role, and don't use feature flags as a permanent licensing system」。常见做法是登录时由 IdP 取出 entitlements 作为自定义 claim 注入令牌。 — [Azure: Identity › Authorization models / Entitlements](https://learn.microsoft.com/en-us/azure/architecture/guide/multitenant/considerations/identity)

**GitHub**
- 每个人登录的是个人账号（personal account），多个个人账号「通过加入同一个 organization 协作」；单个组织超过 100,000 成员时部分 UI/API 会降级，单组织最多拥有 100,000 个仓库。 — [GitHub: About organizations](https://docs.github.com/en/organizations/collaborating-with-groups-in-organizations/about-organizations)
- 切换方式：页面左上角选用户名，从「Switch dashboard context」下拉里选组织；下拉列出个人账号关联的所有组织（即一人可在多个组织）。 — [GitHub: About your organization dashboard](https://docs.github.com/en/organizations/collaborating-with-groups-in-organizations/about-your-organization-dashboard)
- 组织级预置角色有：Owner（建议至少 2 人）、Member（默认）、Moderator、Billing manager、Security manager、GitHub App manager，外加 Outside collaborator（不是成员，只能访问指定仓库）。另外还有 team 级（team maintainer）和仓库级角色；**自定义组织角色只有 Enterprise Cloud 才有**。邀请时只能直接给 owner / billing manager / member 三种。 — [GitHub: Roles in an organization](https://docs.github.com/en/organizations/managing-peoples-access-to-your-organization-with-roles/roles-in-an-organization)
- Enterprise Managed Users（EMU）：由 IdP 通过 SCIM 来开通账号、管理用户名/资料/组织成员关系；「Managed user accounts cannot create public content or collaborate outside your enterprise」；用户不能改自己的名字和邮箱。 — [GitHub: About Enterprise Managed Users](https://docs.github.com/en/enterprise-cloud@latest/admin/managing-iam/understanding-iam-for-enterprises/about-enterprise-managed-users)

**Slack**
- 一个用户可以同时登录多个 workspace，从左上角的 workspace 图标切换（快捷键 Ctrl/⌘+Shift+S）；Enterprise 方案的侧栏有「All workspaces」，可以跨 workspace 过滤会话。 — [Slack: Switch between workspaces](https://slack.com/help/articles/1500002200741)
- 角色分两层：
  - Workspace 层：Member/Guest、Workspace Admin、Workspace Owner、Workspace Primary Owner；
  - Enterprise org 层：Org Admin、Org Owner、Org Primary Owner，外加 Security Admin、Users Admin 系统角色。
  - Primary Owner 不能被停用，要先转移所有权。
  - Enterprise 里把人移出某个 workspace 后「will remain part of the org」。 — [Slack: Deactivate a member's account](https://slack.com/help/articles/204475027)

**Linear**
- 「You can create multiple workspaces in Linear under a single account」，每个 workspace 有独立的成员列表和计费方案；官方建议一个组织只用一个 workspace。切换方式是左上角 workspace 名，或快捷键 O 然后 W。 — [Linear: Workspaces](https://linear.app/docs/workspaces)
- 角色：
  - Workspace owner（仅 Enterprise，管计费/安全/审计日志/导出/OAuth 审批）；
  - Admin（Free 方案下所有人都是 Admin）；
  - Team owner（Business/Enterprise）；
  - Member；
  - Guest（Business/Enterprise，只能访问被加进去的 team，按正式成员计费）。
  - 启用 SCIM 后，同一用户在两个组里时「will get the permission of the most recent group that was pushed」。 — [Linear: Members and roles](https://linear.app/docs/members-roles)
- workspace 的数据区域在创建时选定，之后**不能改**；要迁移区域就新建 workspace 再导入。 — [Linear: Workspaces](https://linear.app/docs/workspaces)

**Notion**
- 切换器默认列出「all the workspaces associated with your email address」；「Workspaces are completely separate silos」，内容不能跨 workspace 链接；付费方案只覆盖一个 workspace，不覆盖整个账号；支持「Add another account」，一个客户端可以同时挂多个账号。 — [Notion: Create, join & leave workspaces](https://www.notion.com/help/create-delete-and-switch-workspaces)
- 加入方式有两种：管理员按邮箱邀请，或者管理员开启「Allowed Email Domains」后按邮箱域自动加入（gmail.com 这类个人域不行）。 — [同上](https://www.notion.com/help/create-delete-and-switch-workspaces)

**Atlassian**
- 账号不绑定某个应用，也「aren't tied to one organization either until you can claim ownership of their accounts」：组织验证邮箱域之后，对应账号变成 managed accounts，组织对它们有完全控制（改邮箱/名字、删除/停用、密码策略、空闲会话时长），但这些账号仍然能访问组织外的应用。另外存在两套用户管理模型：centralized（没有站点过滤）和 original（每个应用实例归属一个 site，有自己的 URL 和管理）。 — [Atlassian: What is an Atlassian organization?](https://support.atlassian.com/organization-administration/docs/what-is-an-atlassian-organization/)

**身份平台（落地机制最具体）**
- Auth0 Organizations：「Any user may belong to multiple organizations」。登录时往 `/authorize` 传 `organization` 参数（M2M 则传给 `/oauth/token`）；ID 和 access token 默认只带 `org_id`，开启后再加 `org_name`。API「must also segment access to data and resources based on the `org_id`」，并且要把 `org_id` 和已知列表或请求 URL（例如子域名）比对校验；校验不过的令牌应视为无效。组织角色的权限只反映「当前会话所在 Organization」里的角色（这个 Organization Roles 功能当时是 Early Access）。 — [Auth0: Organizations overview](https://auth0.com/docs/manage-users/organizations/organizations-overview)；[Auth0: Work with tokens and Organizations](https://auth0.com/docs/manage-users/organizations/using-tokens)
- Auth0 的限制：Organizations **不支持每个组织一个自定义域名**，所有组织共用一个登录域，要分域就得分 Auth0 tenant。 — [Auth0: Organizations overview](https://auth0.com/docs/manage-users/organizations/organizations-overview)
- Clerk：「Users can belong to multiple Organizations」，会话里带 Active Organization，由它决定能看哪些数据、适用哪套角色权限。**每个浏览器标签页记住自己的 Active Organization**，但 session cookie 是全局单例，只反映当前聚焦标签页，所以后台请求要用 `getToken()` 放进 Authorization 头。角色和权限在应用级定义一次，所有组织通用。「Filtering by Organization doesn't itself authorize access to a resource」——按组织过滤本身不等于授权。 — [Clerk: Organizations overview](https://clerk.com/docs/organizations/overview)
- WorkOS 分成 User / Organization / Organization Membership 三个对象，角色挂在 membership 上（既有环境级角色，也有组织自定义角色）。membership 有三种状态：`pending` / `active` / `inactive`。数据归组织、不归个人成员。新用户的流程是：没有 `org_id` 就让他建组织 → 建 membership → 带新组织 ID 调 refresh-token 认证，**换一张带 `org_id` 的 access token**（切组织本质上就是「带目标 organization_id 刷新令牌」）。 — [WorkOS: Users and Organizations](https://workos.com/docs/authkit/users-organizations.md)

### Inferences
- 业内收敛到「全局用户（身份库）+ 租户表 + 成员关系表（user_id, tenant_id, role, status）+ 令牌里带当前 tenant_id」。对本项目来说，**多对多成员关系几乎是默认答案**：一人一租户是多对多的特例（加唯一约束就能退化成一对一），反过来从一对一改成多对多要迁移数据和令牌格式。
- 「租户身份放 idm 还是 app」：Azure 的两种存放选项和 AWS 的「租户在独立于用户的集中服务里管理」都支持一种拆法——**成员关系 + 角色 + 租户状态放在签发令牌的那一侧（idm）**，这样 JWT 能直接带 `tenant_id`/角色，下游不用回查；**租户的业务配置、品牌、entitlements 放 app**。Azure 也明确说 entitlements 不要靠身份系统去推断。
- 「切换租户」的标准实现是**重新签发令牌**（Auth0 的 `organization` 参数、WorkOS 带 organization_id 刷新），而不是让一个令牌同时对多个租户有效。前端要注意 Clerk 指出的「多标签页 + 单例 cookie」问题：如果用 cookie 存会话，不同标签页切了不同租户会互相覆盖。
- 本项目自建 idm 正是 Azure 所说的「self-administered identity」反模式。这是有意的取舍（单机部署、不依赖外部 IdP），但应当知情：MFA、风险检测、SCIM/SSO 联邦以后都要自己补。

### Gaps
- GitHub、Slack、Linear 的内部数据模型（成员关系怎么存、令牌里带什么）没有公开文档，上面只能从 UI 行为反推「一个账号对多个组织」。
- 没找到 Notion 和 Atlassian 在角色细分上的权威页面（这次抓的页面只提到 admin/member 和 org admin）。

---

## 2. 租户生命周期：开通、停用（会话怎么处理）、删除与导出、配额与限流（noisy neighbor）

### Takeaway
现行指南把**商业订阅状态和技术租户状态分开**建模，按「provisioning → active → restricted → deactivated（可恢复）→ offboarded（删除）」推进，转换过程要幂等、要能容忍乱序和重复事件。停用（deactivate）是临时、保留数据的状态，删除前一般要过一段保留期，常见是 48 小时到 90 天。停用成员时，主流产品都**立即在所有设备上登出**、内容保留。noisy neighbor 靠按租户计量、配额限流和把重活放到异步/低峰去跑来解决；限流的作用域普遍是**「每租户（× 每应用 × 每方法）」**。

### Cited Findings

**开通 / 状态机**
- Azure 给出商业状态和租户状态的对照：
  - Pending activation ↔ Provisioning；
  - Active ↔ Active；
  - Plan change pending ↔ Active 或 migrating；
  - Payment problem / grace period ↔ Active 或 restricted；
  - Suspended ↔ Deactivated（「Block new activity while preserving data」）；
  - Canceled ↔ Deactivated 或 offboarding；
  - Expired retention period ↔ Offboarded（删除数据、资源、身份和访问）。
  - 另外：「Design transitions to tolerate duplicate, delayed, and out-of-order events」，要保留审计轨迹，定期对账租户、权益和订阅状态；暂停或取消时不要立刻删数据。 — [Azure: Tenant life cycle](https://learn.microsoft.com/en-us/azure/architecture/guide/multitenant/considerations/tenant-life-cycle)
- 开通时要考虑的点：用自助、自动还是人工流程；数据驻留；合规；DR（RTO/RPO）；需要客户提供哪些信息（法定名称、logo 的尺寸和格式）；计费如何激活权益（以及「commercial activation 成功、technical provisioning 失败」怎么办）；是否需要预生产环境。 — [Azure: Tenant life cycle](https://learn.microsoft.com/en-us/azure/architecture/guide/multitenant/considerations/tenant-life-cycle)
- 试用租户：要决定试用和正式客户是否共用基础设施、试转正怎么迁移数据、怎么防滥用、有哪些限制（时长、功能、性能上限）；也可以用 freemium 替代试用。 — [同上](https://learn.microsoft.com/en-us/azure/architecture/guide/multitenant/considerations/tenant-life-cycle)
- 控制面（control plane）的激活流程：接收购买事件 → 校验 offer/plan/客户 → 新建租户或关联到已有租户 → 开通资源 → 激活 entitlements → 回执给外部系统。全程按分布式工作流设计，要可恢复。 — [Azure: Multitenant control planes](https://learn.microsoft.com/en-us/azure/architecture/guide/multitenant/considerations/control-planes)
- AWS SEC 1：租户记录里要有 active/inactive 状态，「use it to enable or disable access」。 — [AWS SaaS Lens SEC 1](https://wa.aws.amazon.com/saas.question.SEC_1.en.html)

**停用 / 重新激活（租户级）**
- 「Deactivation differs from offboarding because it's intended to be a temporary state」。要定义停用是封掉全部访问还是只封计费操作，还要考虑：管理员访问、**数据导出**、支持人员访问、后台任务、集成，以及停用期间仍在产生费用的用量。 — [Azure: Tenant life cycle › Deactivate and reactivate](https://learn.microsoft.com/en-us/azure/architecture/guide/multitenant/considerations/tenant-life-cycle)
- Atlassian（来自搜索摘要，原页未能直接抓取）：取消订阅后还能访问约 15 天，然后站点停用并进入保留期；付费方案保留 60 天，试用/免费 15 天，期内重新激活就恢复数据，过期永久删除，也可以申请立即删除。原计费体系下另有「两周」的说法，说明各来源之间有出入。 — [Atlassian: Reactivate a subscription](https://support.atlassian.com/subscriptions-and-billing/docs/reactivate-a-subscription/)；[Atlassian: Track storage and move data](https://support.atlassian.com/security-and-access-policies/docs/track-storage-and-move-data-across-products/)（**注：这两页只经搜索结果摘要获得，未逐字核对**）

**停用成员时会话怎么处理**
- Slack 停用成员时：从所有频道移除，「signed out of your workspace(s) on all devices, and unable to sign back in」；消息和文件不删；资料（姓名、头像）不删；**被停用者不会收到通知**；可以重新激活。org 级停用会登出所有 workspace 并移出 org。 — [Slack: Deactivate a member's account](https://slack.com/help/articles/204475027)
- Slack 有专门的管理 API：`admin.users.session.reset` 清掉某个用户所有设备上的会话（Enterprise）；`admin.users.session.invalidate` 只作废单个会话；`resetBulk` 异步批量处理。 — [Slack API: admin.users.session.reset](https://docs.slack.dev/reference/methods/admin.users.session.reset)（经搜索结果摘要）
- Linear：「Suspended users lose all access immediately and are removed from your next billing cycle」；被暂停的用户仍留在成员列表里，这样历史活动还能看。 — [Linear: Members and roles](https://linear.app/docs/members-roles)
- WorkOS：停用 membership 会把状态置为 `inactive`，**并 revoke 所有活动会话**；重新激活后恢复原来的角色；pending 状态的 membership 不能停用，只能删除。WorkOS 建议：成员留下了数据（消息、文档）的用停用；只操作客户数据、不需要保留记录的用硬删除。 — [WorkOS: Users and Organizations](https://workos.com/docs/authkit/users-organizations.md)
- Notion：登录令牌 90 天过期；有「Log out of all devices」。 — [Notion: Create, join & leave workspaces](https://www.notion.com/help/create-delete-and-switch-workspaces)
- GitHub 移除成员：成员失去对组织私有仓库私有 fork 的访问；他发出但还没被接受的邀请会被取消；**成员数据保留 3 个月**，期内重新邀请可选「Invite and reinstate」，恢复角色、私有 fork、团队成员关系、仓库权限、star、issue 指派和通知设置。 — [GitHub: Removing a member](https://docs.github.com/en/organizations/managing-membership-in-your-organization/removing-a-member-from-your-organization)；[GitHub: Reinstating a former member](https://docs.github.com/en/organizations/managing-membership-in-your-organization/reinstating-a-former-member-of-your-organization)

**删除与导出**
- Azure 的 offboarding 要点：保留期限（以及法律强制销毁的期限）；是否允许重新入驻；共享基础设施要不要重新平衡；**即使删了业务数据，也要保留计费、计量、权益和审计记录**；关掉外部订阅、支持访问和集成。 — [Azure: Tenant life cycle › Offboard tenants](https://learn.microsoft.com/en-us/azure/architecture/guide/multitenant/considerations/tenant-life-cycle)
- Linear 删除 workspace：邮件验证码确认 → **排期在 48 小时后执行，并邮件通知所有管理员** → 窗口内任何管理员都能取消 → 到期后永久删除。 — [Linear: Workspaces](https://linear.app/docs/workspaces)
- Linear 导出：workspace 级 CSV 导出由 admin 执行（Enterprise 方案只有 owner 能做），**导出动作会记进审计日志**，下载链接 12 小时后失效，不包含附件；普通成员每次导出上限 250 个 issue，Guest 不能导出。 — [Linear: Exporting data](https://linear.app/docs/exporting-data)
- GitHub 删除组织：不可逆（「This action is irreversible」），GitHub 不能恢复内容；**组织名 90 天内不能被重新注册**；想立刻释放名字应该改名而不是删除；替代方案有降级到 Free 或归档（只读）。 — [GitHub: Deleting an organization account](https://docs.github.com/en/organizations/managing-organization-settings/deleting-an-organization-account)
- Slack 删除 workspace：只有 Primary Owner 能删，要输入密码确认，永久删除、不可恢复，建议先导出；所有方案都能导出公开频道，Business+ 可申请导出私有频道和 DM。 — [Slack: Delete a workspace](https://slack.com/help/articles/204067366)
- Azure 关于域名的安全建议：**禁止重用租户标识（tenant identifier）**，防止子域名接管（见第 4 节）。 — [Azure: Domain names](https://learn.microsoft.com/en-us/azure/architecture/guide/multitenant/considerations/domain-names)

**配额 / 限流 / noisy neighbor**
- Azure 给服务提供方的建议：
  - 同时监控整体和每个租户的资源用量并设告警；
  - 用 Throttling / Rate Limiting 模式做配额；
  - 扩容或加分片；
  - 让租户购买预留容量；
  - 把非时间敏感的重活异步化、放到低峰去跑；
  - 限制租户能做的操作（「setting a maximum returnable record count or query time limit」）；
  - 做 QoS 优先级。
  - 并且要「Be transparent with clients about any throttling mechanisms or usage quotas」。 — [Azure: Noisy Neighbor antipattern](https://learn.microsoft.com/en-us/azure/architecture/antipatterns/noisy-neighbor/noisy-neighbor)
- 检测：找「某个租户本身没占多少资源却出错」的模式；把租户 ID 写进遥测，按租户聚合资源消耗。 — [同上](https://learn.microsoft.com/en-us/azure/architecture/antipatterns/noisy-neighbor/noisy-neighbor)
- Azure 对 PostgreSQL 的说法：shared tables 和 schema-per-tenant 都有 noisy neighbor 风险；PgBouncer「creates a separate pool for each user and database pair」，所以按租户分库或分角色能限制单个租户占用的服务器连接数。 — [Azure: PostgreSQL multitenant](https://learn.microsoft.com/en-us/azure/architecture/guide/multitenant/service/postgresql)
- Slack Web API 限流「per API method per workspace/team per app」，按分钟计：Tier 1 是 1+/min，Tier 2 是 20+/min，Tier 3 是 50+/min，Tier 4 是 100+/min；超限返回 429 + `Retry-After`；Events API 每 workspace 每 app 每 60 分钟 30,000 次投递；每个频道每秒不超过 1 条消息。 — [Slack: Rate limits](https://docs.slack.dev/apis/web-api/rate-limits)
- GitHub REST：
  - 每用户 5,000/h；
  - GitHub App 每个 installation（≈每个组织）基础 5,000/h，仓库超过 20 个或组织用户超过 20 人后每多一个加 50，上限 12,500；Enterprise Cloud 组织为 15,000；
  - 二级限流：并发 100，REST 900 点/分钟（GET=1 点，写=5 点），内容创建 80/分钟、500/小时；
  - 响应头有 `x-ratelimit-limit/remaining/used/reset/resource`，超限返回 403/429。 — [GitHub: Rate limits for the REST API](https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api)
- AWS SaaS Lens（来自搜索摘要）：按租户 tier 定义不同的 API Gateway usage plan（不同的限流和配额），用来防止低 tier 租户影响他人。 — [AWS SaaS Lens REL 1](https://wa.aws.amazon.com/saas.question.REL_1.en.html)；[AWS Architecture Blog: Throttling a tiered multi-tenant REST API](https://aws.amazon.com/blogs/architecture/throttling-a-tiered-multi-tenant-rest-api-at-scale-using-api-gateway-part-1)（**未逐页核对**）

### Inferences
- 对单机 compose 脚手架，最小可行的状态集可以是 `tenants.status ∈ {provisioning, active, suspended, pending_deletion, deleted}`，外加 `suspended_at`、`delete_after`。commercial state 可以先不建模（没有计费系统），但要保留扩展位。
- 用 JWT 时，「停用后立即登出」需要服务端能撤销：**access token 短 TTL + 刷新时检查租户和成员状态 + 删除或作废 sessions 行**（idm 已有 sessions 表）。另外最好在请求中间件里按 `tenant_id` 检查租户状态（可缓存几秒）。这样 Slack 式的「所有设备立即登出」在 access token TTL 内就能生效。
- 删除建议走「软删 + 延迟硬删」：Linear 是 48 小时可撤销，GitHub 移除成员保留 3 个月，Atlassian 60 天。另外删除前要提供导出，导出动作本身要进审计；审计和计费记录不随租户数据一起删。
- 限流的 key 应当是 `(tenant_id, route_class)`，不能只按 IP 或用户；返回 429 + `Retry-After` 已是行业惯例（Slack、GitHub 都这样做）。

### Gaps
- Atlassian 保留期的原始页面（cancel / reactivate subscription）抓取失败（404 或未直接抓），数字来自搜索摘要，各说法之间有冲突（60 天 vs 两周 vs 起算点）。
- 没找到 GitHub、Linear 关于「停用成员后已签发的 OAuth / API 令牌立即失效与否」的明确文档。
- AWS SaaS Lens 的 REL/PERF 原页没有逐页核对，只看了搜索摘要。

---

## 3. 审计日志、监控、日志按租户区分

### Takeaway
做法高度一致：**租户 ID 作为一等字段写进每条日志、指标和审计事件**，最好由公共库或中间件自动注入，而不是让业务代码手写。运维视图按「租户 / tier」切片，审计日志对租户管理员开放，有固定保留期，能导出（或流式推送）。

### Cited Findings
- AWS SaaS Lens SEC 1 建议把租户逻辑封装进库，不让业务开发者碰：
  - token helper（解析租户属性、校验和续期令牌）；
  - **tenant-aware logging wrapper（把租户上下文注入所有日志）**；
  - metrics wrapper（把租户上下文注入指标和消费事件）；
  - data access library（按租户路由到数据位置并取得受限凭据）；
  - 「Rely on language constructs to intercept and apply isolation policies」。 — [AWS SaaS Lens SEC 1](https://wa.aws.amazon.com/saas.question.SEC_1.en.html)
- AWS 的 Tenant-Aware Operations：「SaaS providers need to be able to view system activity and health through the lens of individual tenants and tenant tiers」。 — [AWS SaaS Lens: Tenant-Aware Operations](https://docs.aws.amazon.com/wellarchitected/latest/saas-lens/tenant-aware-operations.html)
- AWS OPS 1/OPS 2（来自搜索摘要）：在应用日志里加租户上下文，运维仪表盘按租户和 tier 组织，把租户自定义指标和平台指标合并成统一视图。 — [AWS SaaS Lens OPS 1](https://wa.aws.amazon.com/saas.question.OPS_1.en.html)；[OPS 2](https://wa.aws.amazon.com/saas.question.OPS_2.en.html)（**未逐页核对**）
- Azure 认为共享数据库里很难精确算出每个租户的消耗，建议选一个「indicative consumption metric」（例如租户存了多少数据）或「transaction metric」（例如创建的文档数）来代表消耗，并定期实测、校准基线。 — [Azure: Measure consumption of each tenant](https://learn.microsoft.com/en-us/azure/architecture/guide/multitenant/considerations/measure-consumption)
- Azure noisy neighbor 指南：把租户 ID 放进每次请求的遥测，按租户聚合资源用量。 — [Azure: Noisy Neighbor](https://learn.microsoft.com/en-us/azure/architecture/antipatterns/noisy-neighbor/noisy-neighbor)
- Azure Identity：要给租户一个「user audit capability」，让租户能自查谁有访问权限、分别是什么权限。 — [Azure: Identity](https://learn.microsoft.com/en-us/azure/architecture/guide/multitenant/considerations/identity)
- Azure 生命周期：状态转换要留审计轨迹，**offboard 后审计记录仍要保留**。 — [Azure: Tenant life cycle](https://learn.microsoft.com/en-us/azure/architecture/guide/multitenant/considerations/tenant-life-cycle)
- GitHub 组织审计日志：
  - 保留最近 **180 天**，Web 默认只显示 3 个月；
  - **只有 owner 能看**；
  - 事件字段有 org、actor、受影响 user、repo、`action`（`category.operation` 形式，如 `repo.create`）、来源国家、时间；导出键为 `action, actor, user, actor_location.country_code, org, repo, created_at`（毫秒 epoch）和 `data.*`；
  - 可按 `operation: / repo: / actor: / action: / created: / country:` 过滤，**不支持全文搜索**；
  - 导出 JSON/CSV 上限 100 MB 压缩或 10 分钟；
  - Enterprise Cloud 可以用 REST/GraphQL 访问；还建议用 webhooks 替代轮询。 — [GitHub: Reviewing the audit log for your organization](https://docs.github.com/en/organizations/keeping-your-organization-secure/managing-security-settings-for-your-organization/reviewing-the-audit-log-for-your-organization)
- Linear：审计日志由 Workspace owner 管理（Enterprise），导出动作会被记进审计日志。 — [Linear: Members and roles](https://linear.app/docs/members-roles)；[Linear: Exporting data](https://linear.app/docs/exporting-data)

### Inferences
- 对 axum + tracing：在认证中间件里把 `tenant_id`（以及 user_id、request_id）写进根 span，所有子日志自动继承，这就是 AWS 说的 logging wrapper。监控统计（项目已有进程内 /admin/monitoring）可以加 tenant 维度，但租户数多时要限制基数（例如只保留 top-N 租户，或按 tier 聚合）。
- 审计表的最小字段可参考 GitHub：`tenant_id, actor_id, target_user_id?, action('category.operation'), resource, ip/country, created_at, data jsonb`。两层视图：租户管理员只能看本租户，平台管理员看全部。另外明确写出保留期（GitHub 用 180 天作为参照），并且**审计行不随租户数据删除**。
- 审计、日志、指标里一律用不可变 ID（Azure 建议），不要用邮箱或用户名。

### Gaps
- Slack 和 Notion 审计日志的具体字段和保留期这次没有抓（Slack Audit Logs API 只对 Enterprise 开放，未核对）。
- 没找到公开的「每租户日志保留期 / 日志隔离」行业数据，只有原则性指南。

---

## 4. 租户级配置 / 品牌：子域名、自定义域名

### Takeaway
三档做法：①路径或令牌识别（不用域名）；②**子域名** `tenant.provider.com` + 通配 DNS + 通配证书；③**自定义域名**（客户 CNAME 指向平台，平台验证域名所有权后自动签证书）。自定义域名的坑集中在域名所有权验证、悬空 DNS（子域名接管）、证书签发和 Host 头处理上。

### Cited Findings
- 子域名做法：
  - 每个租户一个 `tenant.provider.com`，多区域时用 `tenant.us.provider.com` 这类 stem domain；
  - 用通配 DNS `*.contoso.com`（A 或 CNAME）免去为每个租户建记录；
  - 子域名全局唯一，先到先得。 — [Azure: Domain names](https://learn.microsoft.com/en-us/azure/architecture/guide/multitenant/considerations/domain-names)
- 自定义域名做法：客户建 CNAME，例如 `invoices.fabrikam.com → fabrikam.eu.contoso.com`；后端要能按 `Host` 头识别租户。如果反代改写了 Host，原始值放在 `X-Forwarded-Host` 里（Azure Front Door 就这样做），但改写 Host 本身会带来其他问题（见 Host name preservation）。 — [同上](https://learn.microsoft.com/en-us/azure/architecture/guide/multitenant/considerations/domain-names)
- **域名验证**：防止「parking」别人的域名，接入前要求客户建 CNAME，或者把随机字符串写进 TXT 记录，验证通过才能添加。 — [同上](https://learn.microsoft.com/en-us/azure/architecture/guide/multitenant/considerations/domain-names)
- **悬空 DNS / 子域名接管**：客户解约后忘了删 CNAME，攻击者注册同名租户就能接管这个域名。对策有两条：①要求客户先删除 CNAME，才允许从租户上移除域名；②**禁止重用租户标识**，并且要求 TXT 记录用每次入驻都会变化的随机值。 — [同上](https://learn.microsoft.com/en-us/azure/architecture/guide/multitenant/considerations/domain-names)
- TLS：可以由平台代签（续期省事，但客户如果设了 CAA 记录，就要授权平台的 CA），也可以由客户自带证书（平台要安全保管私钥并提醒续期）。 — [同上](https://learn.microsoft.com/en-us/azure/architecture/guide/multitenant/considerations/domain-names)
- **Caddy On-Demand TLS**（适合单机自托管）：
  - 在第一次 TLS 握手遇到未知 SNI 时现场签发证书，之后缓存并在后台续期；
  - 「On-demand TLS must be both enabled and restricted to prevent abuse」，主要的限制手段是 **`ask` 端点**：Caddy 先 HTTP 询问你的服务，例如查数据库里有没有这个已验证的域名，得到允许才签；这个限制是全局的，不能按站点配置；
  - 内部限速为每个 ACME 账号每 10 秒 10 次；失败后指数退避，最长 1 天一次，最多重试 30 天；
  - 测试时用 Let's Encrypt staging。 — [Caddy: Automatic HTTPS › On-Demand TLS](https://caddyserver.com/docs/automatic-https)
- Cloudflare for SaaS（托管做法）：客户域名作为 custom hostname 加进你的 zone，路由到「fallback origin」；apex 域名需要 Enterprise 附加功能（Apex Proxying / BYOIP）。页面元数据显示更新于 2026-04-29。 — [Cloudflare for SaaS](https://developers.cloudflare.com/cloudflare-for-platforms/cloudflare-for-saas/)
- Atlassian 自定义域名（现行，已 GA）：
  - 需要 Jira Premium / Confluence Premium / JSM Standard，只有 org admin 能加；
  - 域名格式必须是 `<sub>.<sub>.<domain>`，可选一个 redirect URL；
  - Atlassian 约 30 分钟后生成 CNAME 记录，客户加到自己的 DNS；如果有 CAA 记录，要放行 amazon.com；
  - 状态流转为 Provisioned → Inactive → 由管理员手动激活；60 天没完成就删掉请求；
  - 每个 FQDN 一张证书，**不支持自带证书**；
  - 激活后原 URL 继续可用，并重定向到自定义域名；域名地址不能编辑，只能删了重建。 — [Atlassian: Add a custom domain](https://support.atlassian.com/organization-administration/docs/add-a-custom-domain/)
- Auth0 Organizations 不支持每个组织一个自定义登录域名。 — [Auth0: Organizations overview](https://auth0.com/docs/manage-users/organizations/organizations-overview)
- Auth0 建议 API 把令牌里的 `org_id` 和请求 URL（例如子域名）比对校验，也就是「域名推断出的租户」必须等于「令牌里的租户」。 — [Auth0: Work with tokens and Organizations](https://auth0.com/docs/manage-users/organizations/using-tokens)
- Linear：管理员可以改 workspace logo、名称和「domain key」（即 URL 里的短标识）。 — [Linear: Workspaces](https://linear.app/docs/workspaces)
- Azure 开通清单把租户 logo（文件大小和格式）列为入驻信息之一。 — [Azure: Tenant life cycle](https://learn.microsoft.com/en-us/azure/architecture/guide/multitenant/considerations/tenant-life-cycle)

### Inferences
- 单机 compose 场景下最省事的路线：先做**路径或令牌识别（tenant 来自 JWT）+ 可选 `slug`**；子域名需要通配证书（Let's Encrypt 通配证书要 DNS-01，对 nginx 部署是额外负担）；自定义域名用 Caddy 的 on-demand TLS + `ask` 端点去查 `tenant_domains(verified=true)`，比在 nginx 上手工管证书简单得多。不过本项目当前对外只开 nginx:80，要上自定义域名就得换成或增加 Caddy 这类能自动签证书的入口（取舍：多一个组件）。
- 不管用哪种域名方案，都要做「域名推出的租户 == 令牌里的租户」校验（Auth0 的建议），否则 A 租户的会话可能在 B 租户的域名下生效。
- 租户 slug 和子域名一旦释放，就要有冷却期，或者干脆永不复用（GitHub 组织名 90 天冷却，Azure 建议禁止重用租户标识）。

### Gaps
- Slack（`xxx.slack.com`）、Notion、Linear 的子域名或自定义域名实现细节没有官方技术文档，只有 UI 层的说明。
- Cloudflare for SaaS 的主机名验证和 DCV 细节页面这次没有抓取。

---

## 5. 从单租户改造成多租户：回填 tenant_id、默认租户，以及 PostgreSQL 数据隔离机制

### Takeaway
官方能给出可执行步骤的主要是 Citus 文档：加列（全表类型一致）→ 从父表 join **分批回填**（不要一次 UPDATE 全表）→ 新写入由应用或库自动带 tenant_id → 回填完成后加 NOT NULL → 主键、唯一键和外键改成包含 tenant_id 的复合键 → 测试期记录所有缺少 tenant 过滤的查询。隔离层面，PostgreSQL RLS 是 shared-tables 模型的标配兜底，但有几个会悄无声息失效的坑：表 owner 绕过、BYPASSRLS、连接池串租户上下文、引用完整性绕过。「默认租户」做法只见于社区经验文章，没有找到官方权威来源。

### Cited Findings

**迁移步骤**
- Citus（13.0.1 文档）：
  - 每张表先归类为「已有 key / 需要回填 / reference 表 / local 表」；
  - 缺 key 的表加列，例如 `ALTER TABLE line_items ADD COLUMN store_id uuid;`，「Be sure to check that the distribution column has the same type in all tables」；
  - 回填从父表 join 取值；「Doing the whole table at once may cause too much load on the database and disrupt other queries」，因此建议写批处理函数，用 pg_cron 定时跑，追平后再停掉。 — [Citus: Identify Distribution Strategy (migration_mt_schema)](https://docs.citusdata.com/en/stable/develop/migration_mt_schema.html)
- Citus（来自搜索摘要，覆盖多个版本的文档）：唯一索引和主键必须包含分布列，所以 PK/FK 要改成含 tenant_id 的复合键；缺 tenant_id 过滤的查询会扇出到所有分片，测试时应记录这类查询。Rails 的 `activerecord-multi-tenant` gem 在新记录上自动设置 tenant id，同时后台回填旧记录，回填完再加 NOT NULL；Django 有类似的 TenantModel。 — [Citus docs (migration_mt_schema / migration_mt_ror / migration_mt_django)](https://docs.citusdata.com/en/v9.3/develop/migration_mt_ror.html)（**摘要来源，未逐页核对**）
- Azure 建议无论选哪种隔离模型，都要测试「one tenant's data isn't accidentally leaked to another」，以及 noisy neighbor 的后果是否可以接受。 — [Azure: Tenancy models › Test your isolation model](https://learn.microsoft.com/en-us/azure/architecture/guide/multitenant/considerations/tenancy-models)
- Azure 的租户定义：B2B 下通常一个客户组织对应一个租户，但客户也可能要多个租户，例如部门不同或 dev/prod 分开，所以不要假定「一个客户 = 一个租户」。还要考虑客户会合并或拆分（并购、剥离），设计时要想清数据归属。 — [Azure: Tenancy models](https://learn.microsoft.com/en-us/azure/architecture/guide/multitenant/considerations/tenancy-models)；[Azure: Tenant life cycle › Merge and split](https://learn.microsoft.com/en-us/azure/architecture/guide/multitenant/considerations/tenant-life-cycle)

**PostgreSQL 隔离模型和 RLS 机制**
- Azure 的 PostgreSQL 隔离模型对比：
  - server-per-tenant：隔离最高，也是唯一能按租户做服务器级控制（例如客户自管密钥）的模型；
  - db/schema-per-tenant：用数据库权限隔离，「Your application doesn't filter rows」，消除了漏写 WHERE 的风险，但 schema 变更要对每个租户执行；
  - shared tables：成本和运维最低、租户密度最高，但隔离靠应用加 RLS。
  - 这三种模型的备份都是整机的，**恢复单个租户要先把备份恢复到新服务器，再把这个租户的数据拷回来**。 — [Azure: PostgreSQL multitenant](https://learn.microsoft.com/en-us/azure/architecture/guide/multitenant/service/postgresql)
- RLS 的绕过风险：
  - 有 `BYPASSRLS` 的角色读全部行；
  - **表 owner 默认不受策略约束，除非 `FORCE ROW LEVEL SECURITY`**；
  - 「don't let your application roles own the tables that they query. Otherwise, a routine permission change can remove your tenant isolation boundary without any visible error」；
  - RLS 可能影响性能，要补索引并做压测。 — [Azure: PostgreSQL multitenant › Row-level security](https://learn.microsoft.com/en-us/azure/architecture/guide/multitenant/service/postgresql)
- **连接池串租户**：session 级的租户上下文属于服务器连接，不属于逻辑客户端，走连接池时会把上一个租户的上下文带进下一个工作单元。在 transaction pooling 下，要在每个事务里用 `SET LOCAL`（事务结束自动恢复）设置租户 ID，并让 RLS 策略读这个设置；schema-per-tenant 则在每个事务里 `SET LOCAL search_path`；用 session pooling 时，连接还回池之前要重置。 — [Azure: PostgreSQL multitenant › Tenant context / Connection pooling](https://learn.microsoft.com/en-us/azure/architecture/guide/multitenant/service/postgresql)
- PostgreSQL 官方（current 版，抓取时为 PG 19 文档）：
  - 开启 RLS 但没有策略时 default-deny；
  - TRUNCATE 和 REFERENCES 不受 RLS 约束；
  - 超级用户和 `BYPASSRLS` 角色总是绕过；
  - owner 默认绕过，可以用 `FORCE ROW LEVEL SECURITY` 强制约束；
  - **「Referential integrity checks, such as unique or primary key constraints and foreign key references, always bypass row security」**，要提防由此产生的 covert channel（例如通过唯一约束冲突推断出别的租户有某条记录）；
  - 省略 WITH CHECK 时沿用 USING；permissive 策略之间是 OR，`AS RESTRICTIVE` 是 AND；
  - `row_security=off` 不是绕过，而是在结果会被过滤时直接报错（防止备份不完整）。 — [PostgreSQL: Row Security Policies](https://www.postgresql.org/docs/current/ddl-rowsecurity.html)
- Clerk 的提醒：「Store the Organization ID with each Organization-owned resource」，并且「按组织过滤本身不等于授权」。 — [Clerk: Organizations overview](https://clerk.com/docs/organizations/overview)

**默认租户 / 渐进式迁移（社区经验，权威性低）**
- 社区文章（dev.to 等）提到的做法有：先建一个默认租户，把存量数据都回填到它名下；对 9 张表用 ORM 全局查询过滤器做租户限定，不改调用点；新旧并行、按批迁移；等等。这些都是个人经验贴，**没有官方来源背书**。 — [dev.to: Migrating a single-tenant SaaS to multi-tenant workspaces with EF Core global query filters](https://dev.to/neojuridico/migrating-a-single-tenant-saas-to-multi-tenant-workspaces-with-ef-core-global-query-filters-396o)；[dev.to: 37 Alembic migrations, zero downtime](https://dev.to/grommash9/37-alembic-migrations-zero-downtime-how-we-moved-a-live-saas-from-single-tenant-to-multi-tenant-4i6n)（**仅搜索摘要，未抓原文**）

### Inferences
- 对本脚手架（sqlx + PG，单机），可执行的迁移顺序：
  1. 建 `tenants` 表并插入一个固定 ID 的默认租户；
  2. 每张业务表 `ADD COLUMN tenant_id uuid NULL`（类型全库统一）；
  3. 分批 `UPDATE ... SET tenant_id = <default>`，大表用批处理，小表一次完成；
  4. 应用层所有写入带上 tenant_id；
  5. `SET NOT NULL`，加 FK 到 tenants；
  6. 唯一约束改为 `(tenant_id, …)`，例如「用户名唯一」变成「租户内唯一」；这是最容易遗漏的语义变化，**也是 RLS 挡不住的信息泄露渠道**；
  7. 开 RLS + `FORCE`，应用用非 owner、非 BYPASSRLS 的角色连接，迁移用 owner 角色；
  8. 每个请求的事务开头执行 `SELECT set_config('app.tenant_id', $1, true)`，第三个参数 true 相当于 SET LOCAL；
  9. 加跨租户泄露测试。
- sqlx 的连接池和 PgBouncer transaction pooling 一样会复用连接，所以租户上下文必须是**事务级**的（`set_config(..., true)`），不能是会话级的 `SET`。这和项目现有的「事务」约定直接相关。
- idm 库（users / sessions）是否也要按租户隔离，取决于第 1 节的选择：选「全局用户 + 成员关系」时，users 表不加 tenant_id，成员关系表才有 tenant_id；idm 的 roles 要么变成「租户内角色」（`user_roles` 加 tenant_id），要么拆成平台角色和租户角色两层。

### Gaps
- 没找到 Microsoft 或 AWS 官方的「单租户 → 多租户迁移」分步指南（AWS re:Invent 有 SaaS migration 演讲 PDF，ARC371、SAS306，这次未抓取）。
- 「默认租户」做法没有权威来源，只有社区经验。
- Citus 文档里「回填后加 NOT NULL」「复合主键」这两点来自搜索摘要，抓到的 stable 页面本身只覆盖加列和回填部分。
