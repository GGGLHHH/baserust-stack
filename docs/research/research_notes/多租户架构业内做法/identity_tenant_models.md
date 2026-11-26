# 身份认证系统 / IdP 里的租户（组织）建模 —— 业内做法事实笔记（2024–2026）

> 调研日期 2026-11-25。资料以各产品官方文档为主（Keycloak 文档取自 GitHub main 分支 asciidoc 源文件，对应 26.x 当前版本）。
> 标注「社区/二手」的条目不是官方文档，仅作参考。

## Q1 各产品怎么建模租户（Keycloak / Auth0 / Clerk / Zitadel / Logto / WorkOS / Cognito / Entra / Casdoor / authentik）

### Takeaway
业内分成两大派：**「硬隔离派」**——每个租户一套独立用户池/目录（Keycloak realm、Cognito user-pool-per-tenant、Entra tenant、GCIP tenant、Casdoor organization、Zitadel organization、authentik tenancy），用户归属唯一租户；**「全局用户 + 组织成员关系派」**——一个全局用户池，组织是用户之上的一层，用户通过 membership 加入 0..N 个组织（Auth0 / Clerk / WorkOS / Logto Organizations、Keycloak 26 Organizations）。2024–2026 年新做的 B2B SaaS 身份产品几乎都选了后者；Keycloak 也在 26.0（2024-10）把 Organizations 转正，作为 realm-per-tenant 之外的「realm 内多租户」方案。

### Cited Findings

**Keycloak —— realm 隔离（老做法）**
- 「A user belongs to and logs into a realm」「Realms are isolated from one another and can only manage and authenticate the users that they control」；master realm 只用来创建和管理其它 realm — [Keycloak Server Admin Guide](https://www.keycloak.org/docs/latest/server_admin/index.html)
- realm 数量没有官方硬上限。2022 年维护者 ahus1 在 GitHub 讨论里说「A Keycloak instance with more than 100-200 realm will slow down significantly」，并引用 3000 realm 时登录耗时约 50 秒（sticky session）/110 秒（无 sticky）的报告 — [keycloak discussion #12332](https://github.com/keycloak/keycloak/discussions/12332)
- 搜索摘要称 2025-10 对同一讨论的更新提到 Keycloak 26.4 配合调大 `--cache-embedded-realms-max-count` 可以跑 1000+ realm；但直接抓取该讨论页时只看到 2022 年的评论，**未能核实**这条 2025 说法 — [keycloak discussion #12332](https://github.com/keycloak/keycloak/discussions/12332)（矛盾/未核实，见 Gaps）

**Keycloak —— Organizations（realm 内多租户，新做法）**
- Keycloak 25（2024-06）以 technology preview 引入，需 `--features organization` 启动并在 Realm Settings 打开；模型：组织存在于 realm 内，「Users belong to the realm first and can be members of zero or more organizations」，组织可有 domains 并关联 IdP — [Keycloak 博客 2024-06](https://www.keycloak.org/2024/06/announcement-keycloak-organizations)
- 「Starting with Keycloak 26, the Organizations feature is fully supported.」— [Keycloak 26.0.0 发布说明](https://www.keycloak.org/2024/10/keycloak-2600-released)
- 官方定位：「It enables multi-tenancy within a realm so that users can have access to protected resources from a realm but with a more restricted and controlled context」；当前能力含成员管理、组织内层级 groups、邀请链接、IdP 联邦入组、多组织共享 IdP、identity-first 登录、token 里传播组织 claim — [Keycloak organizations/intro.adoc (main)](https://github.com/keycloak/keycloak/blob/main/docs/documentation/server_admin/topics/organizations/intro.adoc)
- 「An organization member is basically a realm user but with a link to one or more organizations」；成员分 **Managed**（经 IdP 以 managed 类型联邦进来，生命周期归组织，删组织/删成员会把账号从 realm 删掉）与 **Unmanaged**（本来就是 realm 用户，后加入组织，删组织不删账号）— [managing-members.adoc](https://github.com/keycloak/keycloak/blob/main/docs/documentation/server_admin/topics/organizations/managing-members.adoc)
- 组织功能有部分路线图项目（组织级 admin/user events、SCIM、自助服务）在跟踪 issue 中当时仍未勾选 — [keycloak issue #30180](https://github.com/keycloak/keycloak/issues/30180)（较旧，状态可能已变）

**Auth0 Organizations**
- 用户存在 connection（数据库/社交/企业）里；「A user can have one identity and be a member of several organizations」（示例 Emilio 在 Travel0 数据库连接中，同时是两个组织的成员）；企业连接需要逐组织启用 — [Auth0 Organizations overview](https://auth0.com/docs/manage-users/organizations/organizations-overview)
- 限制：仅 Universal Login；不支持 ROPG（密码模式）、Device Flow、WS-Fed；**不支持按组织的自定义域名，需要不同登录域名只能拆成不同 Auth0 tenant**；与 Delegated Administration / Authorization Extension 不集成 — 同上
- 应用访问：默认「implicit」模型（成员可访问所有启用了 Organizations 的应用）；可按组织开启 explicit access — 同上
- Auth0 自身还有一层「tenant」（Auth0 账号下的环境），Organizations 是 tenant 内的二级租户 — 同上（「Distinct login domains require separate tenants」）

**Clerk Organizations**
- 「Each application can contain multiple Organizations, and each Organization can have multiple users」；用户可属于多个组织；Clerk 在 session 中提供 memberships、Roles、Active Organization；组织所属资源应存 Organization ID 来过滤，但官方强调这种过滤「doesn't itself authorize access to a resource」— [Clerk Organizations overview](https://clerk.com/docs/guides/organizations/overview)
- 设置「Membership required (default)」（每个用户必须属于组织，未加入时通过 session tasks 强制创建/加入）vs「Membership optional」（开启 Personal Accounts 个人工作区）；官方建议多数 B2B 应用关闭个人账户；用户可加入的组织数**不限**；每组织默认 5 成员，无 B2B 加购时全局上限 20；每用户默认最多创建 100 个组织 — [Clerk configure organizations](https://clerk.com/docs/guides/organizations/configure)

**Zitadel**
- 层级：Instance → Organization → Project。Organization 是「the vessel where your projects and users live」，每个组织有自己的用户池（含 service account），组织之间用户和数据隔离 — [Zitadel organizations](https://zitadel.com/docs/concepts/structure/organizations)
- 「Users exist within one organization」「It is currently not possible to move users between organizations」；跨组织访问通过 External User Grants（邀请别组织用户访问本组织项目）及 Project Grants（把项目授权给客户组织，让其自己管理用户）— [Zitadel users](https://zitadel.com/docs/concepts/structure/users)

**Logto Organizations**
- 定位于多租户 SaaS / B2B；成员可通过邀请或 JIT 预配加入 — [Logto organizations](https://docs.logto.io/organizations)
- 用户全局：ID token 的 `organizations` claim 列出用户所属的**所有**组织 ID（即一个用户可属多个组织）— [Logto organization-level API resources](https://docs.logto.io/authorization/organization-level-api-resources)

**WorkOS AuthKit**
- 「Users are global」；邮箱是唯一键（存储时 trim + 小写）；一个用户可有多种登录方式；用户可属多个组织，同时支持 single-workspace 与 multi-workspace 两种产品模型；membership 状态 `pending` / `active` / `inactive`，停用 membership 会吊销其活动会话 — [WorkOS users & organizations](https://workos.com/docs/authkit/users-organizations)

**AWS Cognito**（官方给出 4+1 种模式）
- user-pool-per-tenant：隔离最强、可按租户不同配置（MFA、密码策略）；同一个人在不同租户是不同 profile，「each user must sign up individually for each tenant」；开发和运维成本「high」，需要自己做入口路由 UI — [Cognito user-pool multi-tenancy](https://docs.aws.amazon.com/cognito/latest/developerguide/bp_user-pool-based-multi-tenancy.html)
- app-client-per-tenant、group-per-tenant（`cognito:groups` claim，主要用于选 IAM role，维护成本 low）、custom-attribute（`custom:tenantID`，「When tenancy is surface-level」，不适合强隔离）、custom scope — [Cognito multi-tenant best practices](https://docs.aws.amazon.com/cognito/latest/developerguide/multi-tenant-application-best-practices.html)；[group-based](https://docs.aws.amazon.com/cognito/latest/developerguide/group-based-multi-tenancy.html)；[custom-attribute](https://docs.aws.amazon.com/cognito/latest/developerguide/custom-attribute-based-multi-tenancy.html)
- 共享 user pool 时 managed login 的会话 cookie 对同池所有 app client 有效（1 小时、不可改），要阻止跨租户 app 免登录只能拆 user pool 或改用 API 登录 — [Cognito multi-tenant best practices](https://docs.aws.amazon.com/cognito/latest/developerguide/multi-tenant-application-best-practices.html)

**Microsoft Entra ID（B2B guest）**
- 每个 tenant 是独立目录。B2B 协作时在资源租户里**创建一个新的 user object** 代表外部用户（UserType 通常为 Guest，UPN 含 `#EXT#`），认证由用户的 home 租户/外部 IdP 完成，资源租户里的这个对象没有凭据 — [Entra B2B overview](https://learn.microsoft.com/en-us/entra/external-id/what-is-b2b)；[B2B guest user properties](https://learn.microsoft.com/en-us/entra/external-id/user-properties)
- 四类：External guest / External member / Internal guest / Internal member（多租户集团常用 External member 让跨租户用户获得成员级权限）— [B2B guest user properties](https://learn.microsoft.com/en-us/entra/external-id/user-properties)

**Casdoor**
- 「Each user belongs to exactly one organization and can sign in to every application of that organization」；API 用户标识 `<organization>/<username>`（如 `built-in/admin`），另有 UUID `id`；「An application belongs to one organization」— [Casdoor core concepts](https://casdoor.ai/docs/basic/core-concepts/)
- 支持「shared application」：别的组织用户通过共享应用登录时，会话上限等设置按用户**自己所属组织**的配置 — [Casdoor organization overview](https://casdoor.ai/docs/organization/overview/)

**authentik**
- 「Tenancy」是 Enterprise 功能，2024.2 引入，**标为 alpha（"Use at your own risk"）**：每个 tenant 是独立的 authentik 安装（独立 Install ID 与 license），数据放在**独立 PostgreSQL schema**，文件按 tenant 目录分开；只能用 API 管理；不支持 embedded outpost；expression policy 能访问所有 tenant（官方标为危险）— [authentik tenancy](https://docs.goauthentik.io/docs/sys-mgmt/tenancy)
- 「Brands」以前叫 tenants（2024.2 改名），只是按域名的品牌/默认流程配置，不是数据隔离 — 同上

**Google Cloud Identity Platform（补充）**
- 多租户需 GCIP（非普通 Firebase Auth），需先在 Cloud Console 允许 tenants；tenant ID 在 ID token 的 `firebase.tenant`；TenantAwareAuth 拒绝别的 tenant 的 token（mismatching-tenant-id 错误）— [GCIP multi-tenancy authentication](https://docs.cloud.google.com/identity-platform/docs/multi-tenancy-authentication)（官方页面本次直接抓取被拒，内容来自搜索摘要中引用的官方示例）

### Inferences
- 「每租户独立用户池」的产品（Keycloak realm、Cognito pool、Entra、GCIP、Casdoor、Zitadel、authentik tenancy）本质是把 IdP 当成多套实例；「全局用户 + membership」的产品把租户当作授权上下文。对一个「单机、idm 库 + app 库、一套实例服务多个组织」的脚手架，后者与现有 users/roles/user_roles 表结构更接近：加一张 organizations 表 + 一张 memberships(user_id, org_id, …) 表即可，不需要按租户拆 schema 或拆实例。
- authentik 的 schema-per-tenant 与 Keycloak 的 realm-per-tenant 都显示：硬隔离在 IdP 层的运维成本会随租户数线性上升（realm 数过百即有性能报告、authentik 每租户需单独 license），这对单机部署不友好。

### Gaps
- Keycloak 26.x 对 realm 数量的最新官方建议未能从一手来源核实（搜索摘要与实际抓到的页面不一致）。
- Logto 是否有「全局（非组织）用户角色」与组织角色同时进入 token 的完整说明未抓到全文。
- GCIP 官方页面被代理拒绝，tenant 数量上限与计费未核实。

## Q2 一个账号属于一个租户 vs 多个租户（membership）；登录后怎么选/切换；切换是否重签 token

### Takeaway
**单租户归属**：Casdoor、Zitadel（用户属于一个 org，跨 org 靠 grant）、Cognito pool-per-tenant、GCIP、Keycloak realm、Entra（跨租户靠在资源租户建 guest 对象，本质还是「每租户一个账号」）。**多租户 membership**：Auth0、Clerk、WorkOS、Logto、Keycloak Organizations。多 membership 的产品**一律是「切换 = 拿一张新的、只含当前组织的 token」**：Auth0 重新走 /authorize（可静默）、WorkOS/Logto 用 refresh token 换带 organization_id 的新 access token、Clerk setActive 后刷新 session token、Keycloak 通过 scope 请求。

### Cited Findings
- **Auth0**：多组织成员登录后进入 **Organization Picker**，显示其加入的前 20 个组织（应用的「Type of Users」= Business Users 或 Both 时）— [Auth0 login flows for organizations](https://auth0.com/docs/manage-users/organizations/login-flows-for-organizations)
- **Auth0 切换（社区/二手）**：切换做法是带目标 `organization` 再调 /authorize，配 `prompt=none` 做静默认证；用户须已是目标组织成员且连接已对其启用；有用户报告静默认证会报「authentication required」；refresh token 与组织绑定 — [Auth0 Community: Switch user organisation without re-login](https://community.auth0.com/t/switch-user-organisation-without-re-login/84183)；[Get new Access Token for a different organization](https://community.auth0.com/t/get-new-access-token-for-a-different-organization/68426)
- **WorkOS**：切换组织 = 调「authenticate with refresh token」并传 `organization_id`；若 session 对该组织已授权，新 token 的 `org_id`、`role`、`permissions` 换成该 membership 的；未授权则报认证错误，需用 Get Authorization URL 带 `organization_id` 重新认证 — [WorkOS sessions](https://workos.com/docs/authkit/sessions)
- **WorkOS 登录时选组织**：属于多个组织的用户登录时返回错误 `organization_selection_required`，带 `pending_authentication_token`、`organizations`（id、name 列表）、`user`；前端展示列表，再用 pending token + 所选组织完成认证 — [WorkOS authentication errors](https://workos.com/docs/reference/authkit/authentication-errors)；若 access token 里没有 `org_id`，官方建议为用户创建组织或提示其选择 — [WorkOS users & organizations](https://workos.com/docs/authkit/users-organizations)
- **Logto**：不支持从授权码流程直接拿组织 token；先拿 refresh token（scope 含 `urn:logto:scope:organizations` 与 `offline_access`），再用 refresh token grant + `organization_id` + `resource` 换「组织 token」；M2M 用 client_credentials + organization_id — [Logto organization-level API resources](https://docs.logto.io/authorization/organization-level-api-resources)
- **Clerk**：Active Organization **按浏览器标签页**选择，每个 tab 独立；session cookie 是浏览器级单值，可能反映另一个 tab 的组织，所以后台请求要 `getToken()` 放 Authorization 头 — [Clerk Organizations overview](https://clerk.com/docs/guides/organizations/overview)；切换用 `setActive({ organization: id })` / `<OrganizationSwitcher/>` — [Clerk organization switching](https://clerk.com/docs/organizations/organization-switching)
- **Clerk token 刷新**：session token 是短效 JWT，约每 60 秒刷新；可用 `getToken({ skipCache: true })` 强制刷新 — [Clerk force token refresh](https://clerk.com/docs/guides/sessions/force-token-refresh)（setActive 后需立即刷新以免拿到旧组织 token 的说法来自社区 PR，非官方）
- **Keycloak Organizations**：scope `organization` —— 用户只属一个组织时直接映射；属多个组织时**登录过程中提示用户选择**；`organization:<alias>` 指定组织（可多个），不是成员则拒绝请求；`organization:*` 映射全部组织；混用格式报错 — [mapping-organization-claims.adoc](https://github.com/keycloak/keycloak/blob/main/docs/documentation/server_admin/topics/organizations/mapping-organization-claims.adoc)
- **Zitadel**：用户属于单一组织，不能迁移；访问其它组织的项目靠 External User Grants / Project Grants — [Zitadel users](https://zitadel.com/docs/concepts/structure/users)
- **Entra**：「If a single user exists in multiple tenants, the user contains a different object ID in each tenant. Even though the user logs into each account with the same credentials, the accounts are different.」— [Entra access token claims reference](https://learn.microsoft.com/en-us/entra/identity-platform/access-token-claims-reference)；token 的 `tid` 是「the tenant that the user is signing in to」，即每个租户一张 token — 同上
- **Cognito pool-per-tenant**：同一人在多个租户要分别注册 — [Cognito user-pool multi-tenancy](https://docs.aws.amazon.com/cognito/latest/developerguide/bp_user-pool-based-multi-tenancy.html)

### Inferences
- 只要支持多组织，「当前组织」就必须进 token 并在切换时重签，否则后端无法在不查库的情况下判断请求属于哪个组织；业内没有一家采用「token 里放全部组织、请求头另带 X-Org-Id 自选」作为默认（Keycloak `organization:*` 与 Logto ID token 的 `organizations` 是例外，但它们是用于展示/选择，Logto 的 API access token 仍是单组织）。
- 对自建 idm：切换组织可以实现为一个 `POST /auth/switch-org {org_id}` 接口：校验 membership → 用当前 session/refresh token 签一张新 access token（org_id 换掉），与 WorkOS/Logto 做法一致，不必重新输密码。
- 「一个账号只属一个租户」实现最简单，但同一个人加入第二个组织就得注册第二个账号（Cognito/Casdoor/Entra 都是这个代价）。

### Gaps
- Auth0 官方文档中关于「切换组织」的权威说明本次未找到，仅有社区回答。
- Clerk 官方未明确说明 setActive 是否立即签发新 token。

## Q3 登录时怎么确定租户（子域名 / 租户代码 / 邮箱域名 HRD / 登录后选择）

### Takeaway
主流组合是 **identifier-first（先输邮箱）+ 已验证邮箱域名映射到组织（HRD）+ 多组织时登录后选择**；「输入组织名」作为可选入口；按组织的独立子域名/URL 在 Auth0 需要拆 tenant，在 Casdoor 用 `/login/<org>` 路径，在 Zitadel 用登录名后缀里的组织域。

### Cited Findings
- **Auth0** 三种 login flow：「Prompt for Organization」（用户输入组织名或组织邮箱）、「Prompt for Credentials」（官方说「Most organizations should choose Prompt for Credentials」，配 Identifier First，输邮箱后按 HRD 路由到企业 IdP，无匹配则显示密码框）、「No Prompt」（应用已知组织，在 /authorize 传 `organization`）；可选 Organization Domain Discovery，且「does not restrict who can sign up or log in」；API 字段 `organization_usage` 与 `organization_require_behavior` — [Auth0 login flows for organizations](https://auth0.com/docs/manage-users/organizations/login-flows-for-organizations)；/authorize 参数 `organization` — [Auth0 work with tokens and organizations](https://auth0.com/docs/manage-users/organizations/using-tokens)
- **Auth0** 不支持每个组织一个自定义域名 — [Auth0 Organizations overview](https://auth0.com/docs/manage-users/organizations/organizations-overview)
- **Keycloak Organizations**：realm 存在组织时 browser flow 自动变成 identity-first login；identity-first 负责「Matching an email domain to an organization」，域名配置了 IdP 路由且 auto-redirect 时自动跳转企业 IdP；但若账号已有本地凭据（密码/passkey/kerberos）则不自动跳转；「each domain belongs to exactly one organization」；不存在的用户用组织域名邮箱登录会直接报用户名无效 — [authenticating-members.adoc](https://github.com/keycloak/keycloak/blob/main/docs/documentation/server_admin/topics/organizations/authenticating-members.adoc)
- **Keycloak** broker 登录入组的判定顺序：邀请链接优先 → identity-first 解析出的组织 → 邮箱域名匹配 → 该 IdP 只关联一个组织时兜底 → 否则不加入 — 同上
- **Zitadel**：组织由输入的登录名自动确定，「Users cannot pick their organization manually」；开启「User Loginname must contain orgdomain」后登录名形如 `john.doe@acme.zitadel.cloud`，验证过的自定义域名可作额外登录名；未指定组织时进默认组织；可用保留 scope `urn:zitadel:iam:org:id:{id}` 强制某组织的设置与品牌 — [Zitadel organizations](https://zitadel.com/docs/concepts/structure/organizations)
- **Clerk**：Verified Domains 会对邮箱域名匹配的用户自动邀请或建议加入（需管理员批准）— [Clerk Organizations overview](https://clerk.com/docs/guides/organizations/overview)
- **WorkOS**：多个组织验证同一域名时，用户可能需在 SSO 前选择组织；超过 50 个组织验证同一域名时跳过 discovery；一个域名在一个环境内只能出现在一个组织的 domain policy 中 — [WorkOS organization policies](https://workos.com/docs/authkit/organization-policies)
- **Casdoor**：通过 `/login/<organization-name>` 登录时记住组织 — [Casdoor organization overview](https://casdoor.ai/docs/organization/overview/)
- **Cognito**：pool-per-tenant 需要自己做「初始决策」UI 把用户路由到正确的资源；custom-attribute 模式可以只发一个登录 URL — [Cognito user-pool multi-tenancy](https://docs.aws.amazon.com/cognito/latest/developerguide/bp_user-pool-based-multi-tenancy.html)；[custom-attribute](https://docs.aws.amazon.com/cognito/latest/developerguide/custom-attribute-based-multi-tenancy.html)
- **安全建议（Cognito）**：只能用**已验证**邮箱按域名匹配授权租户；不信任未验证的邮箱/手机号 — [Cognito multi-tenancy security recommendations](https://docs.aws.amazon.com/cognito/latest/developerguide/multi-tenancy-security-recommendations.html)

### Inferences
- 对「全局用户 + membership」模型，租户其实可以**登录后再定**：账号认证与租户无关，登录成功后按 membership 数量决定直接进入（1 个）/ 弹选择（多个）/ 引导创建或报错（0 个）。子域名、租户代码只是「预选」提示（相当于 Auth0 No Prompt 或 Keycloak `organization:<alias>`），不是认证必需。
- 只有在「每租户独立用户池、同一邮箱可在多个租户各有一个账号」的模型下，登录前就必须知道租户（否则无法定位是哪个账号），这也是 Cognito/GCIP/Casdoor 都需要租户路由入口的原因。

### Gaps
- 未找到各产品对「子域名 → 组织」的官方内建支持说明（Auth0 明确不支持按组织自定义域名；其余产品多由应用自行把子域名翻译为 organization 参数）。

## Q4 用户名 / 邮箱唯一性：全局还是租户内；同一个人多个账号、账号合并的坑

### Takeaway
「全局用户」派：邮箱/用户名**全局唯一**（WorkOS、Logto；Auth0 以 connection 为单位，同邮箱在不同 connection 默认是不同用户、需账号关联）。「每租户用户池」派：唯一性**在租户内**，同一邮箱可在多个租户各有一个账号（Zitadel 邮箱可跨组织复用、Casdoor `org/username`、Cognito 多池、Entra 每租户不同 oid）。租户内唯一的代价是「同一个人多个账号」，后续合并困难；全局唯一的代价是租户管理员不能随意「创建」一个已被别处占用的邮箱，需要走邀请/加入流程。

### Cited Findings
- **WorkOS**：邮箱是唯一键，存储前 trim + 小写，WorkOS 自动关联身份所以不会出现重复邮箱；但「A user may not map to one individual, since a person can hold several identities」— [WorkOS users & organizations](https://workos.com/docs/authkit/users-organizations)
- **Logto**：用户表 `username` 与 `primary_email` 标为 Unique — [Logto user data](https://docs.logto.io/user-management/user-data)（官方未明说范围是整个 Logto tenant，属推断）
- **Zitadel**：默认用户名在整个 instance 唯一；开启「User Loginname must contain orgdomain」后变为组织内唯一 — [Zitadel organizations](https://zitadel.com/docs/concepts/structure/organizations)；「Email addresses can be reused across organizations」— [Zitadel users](https://zitadel.com/docs/concepts/structure/users)
- **Casdoor**：用户 API 标识为 `<organization>/<username>`，即用户名在组织内命名 — [Casdoor core concepts](https://casdoor.ai/docs/basic/core-concepts/)
- **Auth0**：「Auth0 treats all identities as separate by default」（数据库登录 + Google 登录 = 两个用户）；账号关联把两个 profile 合并，主账号保留 `user_id`，次账号进 `identities` 数组；「Insecurely linking accounts can allow malicious actors to access legitimate user accounts」，建议关联前对两个账号都要求认证 — [Auth0 user account linking](https://auth0.com/docs/manage-users/user-accounts/user-account-linking)
- **Entra**：同一人在多个租户各有一个不同 `oid`；`sub` 还是按应用 pairwise 的 — [Entra access token claims reference](https://learn.microsoft.com/en-us/entra/identity-platform/access-token-claims-reference)
- **Cognito**：pool-per-tenant「You can create multiple profiles for the same user. However, each user must sign up individually for each tenant」— [Cognito user-pool multi-tenancy](https://docs.aws.amazon.com/cognito/latest/developerguide/bp_user-pool-based-multi-tenancy.html)
- **Keycloak**：realm 之间完全隔离，所以唯一性按 realm；Organizations 模式下成员仍是 realm 用户，因此用户名/邮箱按 realm（全局）唯一 — [Keycloak Server Admin Guide](https://www.keycloak.org/docs/latest/server_admin/index.html)；[managing-members.adoc](https://github.com/keycloak/keycloak/blob/main/docs/documentation/server_admin/topics/organizations/managing-members.adoc)

### Inferences
- 坑 1（租户内唯一）：同一个人在 A、B 两个组织各一个账号 → 两套密码/MFA、改邮箱要改两处、后续想合并需要账号关联流程（Auth0 那套「主账号 + identities」）并且必须双方都验证才安全。
- 坑 2（全局唯一）：租户管理员「新建用户」时邮箱已存在于别的组织 → 不能新建，应改为「邀请已有账号加入本组织」（Keycloak 的 Unmanaged member、WorkOS 的 pending membership 都是这个语义），且不能让 A 组织管理员修改/重置这个全局账号的密码（会越权影响 B 组织）。Keycloak 的 managed/unmanaged 区分正是用来回答「组织管理员对账号生命周期有多大权力」。
- 坑 3（按邮箱域名自动入组）：必须基于已验证邮箱（Cognito 安全建议），否则可注册 `x@victim.com` 冒充进入组织。

### Gaps
- 未找到 Clerk 官方关于邮箱唯一范围的明确说明（推测为应用实例内全局唯一，未核实）。

## Q5 JWT / token 里的租户 claim 怎么设计

### Takeaway
主流 access token 放**单个当前组织**：Auth0 `org_id`(+可选 `org_name`)、WorkOS `org_id` + `role` + `permissions`、Clerk v2 紧凑 `o` 对象、Logto 组织 token 的 `organization_id`、Entra `tid`。放**全部组织**的仅见于 ID token / 可选 scope（Logto ID token `organizations`、Keycloak `organization:*`、Zitadel roles 按 org 展开）。权限 claim 与当前组织绑定，切换组织就换 token。

### Cited Findings
- **Auth0**：`org_id` 默认出现在 ID 与 access token（例 `org_9ybsU1dN2dKfDkBi`）；`org_name` 仅当租户允许在 Authentication API 使用组织名时出现；access token 的 `permissions` 只列**当前活动组织**内组织角色的权限；无组织上下文时 tenant roles 照常生效；API 必须校验 `iss`、把 `org_id` 与已知组织比对，并「segment data and resources by org_id」— [Auth0 work with tokens and organizations](https://auth0.com/docs/manage-users/organizations/using-tokens)
- **Clerk v2（当前）**：单个 `o` claim，仅当用户有活动组织时出现，含 `id`、`slg`（slug）、`rol`（去掉 `org:` 前缀的角色）、`per`（权限名）、`fpm`（与 `fea` 对齐的位掩码）；**v1 于 2025-04-14 废弃**，v1 用顶层 `org_id` / `org_slug` / `org_role`（如 `org:admin`）/ `org_permissions` — [Clerk session tokens](https://clerk.com/docs/guides/sessions/session-tokens)
- **WorkOS**：access token 含 `sid`、`org_id`（登录时选定的组织）、`role`（该 membership 的角色）、`permissions` — [WorkOS sessions](https://workos.com/docs/authkit/sessions)
- **Logto**：ID token `organizations` = 用户所属全部组织 ID；组织 access token 含 `aud`、`organization_id`、按组织角色过滤后的 `scope` — [Logto organization-level API resources](https://docs.logto.io/authorization/organization-level-api-resources)
- **Keycloak**：scope `organization` 产生 claim `"organization": { "<alias>": { "id": ..., "attr1": [...] } }`（以 alias 为 key 的对象，可多个）；id 与属性默认**不**包含，要在 `Organization Membership` mapper 里打开 *Add organization id* / *Add organization attributes* — [mapping-organization-claims.adoc](https://github.com/keycloak/keycloak/blob/main/docs/documentation/server_admin/topics/organizations/mapping-organization-claims.adoc)
- **Zitadel**：`urn:zitadel:iam:user:resourceowner:id|name|primary_domain` 表示用户所属组织；`urn:zitadel:iam:org:project:roles` 结构为「角色 → {组织 ID: 组织主域名}」，例 `{"user": {"id1": "acme.zitade.ch", "id2": "caos.ch"}}`，即一个 token 里可以表达多个组织下的角色 — [Zitadel claims](https://zitadel.com/docs/apis/openidoauth/claims)
- **Entra**：`tid`（登录到的租户 GUID）、`oid`（租户内对象 ID，跨租户不同）、`iss` 含租户、guest 场景 `idp` 指向 home IdP — [Entra access token claims reference](https://learn.microsoft.com/en-us/entra/identity-platform/access-token-claims-reference)
- **Cognito**：`custom:tenantID`（应设为不可变/对 app client 只读）、`cognito:groups` — [custom-attribute](https://docs.aws.amazon.com/cognito/latest/developerguide/custom-attribute-based-multi-tenancy.html)；[security recommendations](https://docs.aws.amazon.com/cognito/latest/developerguide/multi-tenancy-security-recommendations.html)
- **GCIP**：`firebase.tenant` — [GCIP multi-tenancy authentication](https://docs.cloud.google.com/identity-platform/docs/multi-tenancy-authentication)（经搜索摘要）
- Clerk 提醒：按组织 ID 过滤数据本身不等于授权 — [Clerk Organizations overview](https://clerk.com/docs/guides/organizations/overview)

### Inferences
- 建议的最小 claim 集合（对齐 Auth0/WorkOS 命名）：`sub`（全局用户 ID）、`org_id`（当前组织）、`org_role`/`roles`（当前组织内角色）、可选 `permissions`；平台管理员另用独立 claim（见 Q6），不要用「org_id 为空」隐式表示平台管理员。
- 不把全部组织放 access token：token 体积随组织数增长，且后端每次都要再判定「这次请求用哪个组织」，等于把租户选择交给了不可信的请求参数。
- 组织成员关系或角色变更后，旧 token 在过期前仍有效（WorkOS 通过停用 membership 吊销会话来处理）—— 自建时 access token 要短效，或在 session 表上做吊销。

### Gaps
- 无。

## Q6 平台级超级管理员（跨租户）怎么建模；租户内管理员 vs 平台管理员

### Takeaway
普遍是**两层（或三层）管理角色、作用域显式分开**：平台层（Keycloak master realm 管理员、Zitadel `IAM_*`、Casdoor `built-in` 组织成员、Auth0 Dashboard/Management API）与组织层（Keycloak 组织管理员、Zitadel `ORG_*`、Casdoor `isAdmin`、Clerk 组织 Admin 角色）。平台管理员通常**不是普通组织角色的一种**，而是独立的作用域/独立的「系统组织」。

### Cited Findings
- **Zitadel** 管理员分三级：Instance 级 `IAM_OWNER`（管理实例及所有组织）、`IAM_OWNER_VIEWER`、`IAM_ORG_MANAGER`、`IAM_USER_MANAGER`、`IAM_ADMIN_IMPERSONATOR`、`IAM_END_USER_IMPERSONATOR`、`IAM_LOGIN_CLIENT`；组织级 `ORG_OWNER`、`ORG_OWNER_VIEWER`、`ORG_USER_MANAGER`、`ORG_USER_PERMISSION_EDITOR`、`ORG_PROJECT_PERMISSION_EDITOR`、`ORG_PROJECT_CREATOR`、`ORG_ADMIN_IMPERSONATOR` 等；项目级 `PROJECT_OWNER` 等；「Only instance-level administrators can view resources such as users across all organizations」；术语「Administrators」取代旧的 Members/Memberships/Managers — [Zitadel administrators](https://zitadel.com/docs/guides/manage/console/administrators)
- **Casdoor**：首次启动创建 `built-in` 组织、`built-in/admin` 用户；「Every user of the built-in organization is a global administrator」；内建名称不可改不可删；用户的 `isAdmin` 标志表示其所在组织的管理员 — [Casdoor core concepts](https://casdoor.ai/docs/basic/core-concepts/)；部分设置（如 Trusted organization）只有全局管理员能改 — [Casdoor organization overview](https://casdoor.ai/docs/organization/overview/)
- **Keycloak**：master realm 只用于创建/管理其它 realm；管理权限分 Global roles 与 Realm-specific roles（master realm access control）— [Keycloak Server Admin Guide](https://www.keycloak.org/docs/latest/server_admin/index.html)；Organizations 设计上让「a realm or an organization administrator」管理成员生命周期 — [intro.adoc](https://github.com/keycloak/keycloak/blob/main/docs/documentation/server_admin/topics/organizations/intro.adoc)；26.7 加入组织的细粒度管理权限（**二手来源**，未核实官方 release note）— [Keycloak 版本综述（二手）](https://skycloak.io/blog/keycloak-25-released-new-features-and-enhancements/)
- **Auth0**：Management API 只应由 confidential client 访问；Organizations 与 Delegated Administration Extension 不集成 — [Auth0 Organizations overview](https://auth0.com/docs/manage-users/organizations/organizations-overview)（即组织内自助管理需要自己在应用里实现）
- **Clerk**：组织创建者默认 Admin，该角色必须包含三个 System Permission（manage members、read members、delete Organization）— [Clerk configure organizations](https://clerk.com/docs/guides/organizations/configure)
- **authentik**：tenancy 只能通过 API 管理、有默认 tenant；expression policy 能访问所有 tenant（安全隐患）— [authentik tenancy](https://docs.goauthentik.io/docs/sys-mgmt/tenancy)
- **Entra**：B2B guest 默认在资源租户权限受限（limited privileges by default）— [B2B guest user properties](https://learn.microsoft.com/en-us/entra/external-id/user-properties)

### Inferences
- 两种可行建模：(a) **Casdoor 式「系统组织」**——平台管理员 = 某个保留组织（如 `system`）的成员，好处是复用 membership 表；坏处是业务查询要处处排除这个组织。(b) **Zitadel 式「作用域分层角色」**——user_roles 加一列 scope（platform / org），平台角色不挂 org_id。(b) 与现有 users/roles/user_roles 表改动更小，也更不容易让平台管理员数据混进租户业务数据。
- 无论哪种，平台管理员访问某组织数据时最好显式「进入」该组织（签一张带该 org_id 的 token 并记审计），而不是让平台角色绕过 org 过滤——Zitadel 的 impersonator 角色单列也说明「代入」被视为高敏操作。

### Gaps
- Keycloak 26.x 组织管理员（organization admin）具体可授予的权限集合未抓到全文。

## Q7 角色：全局定义 + 租户内授予，还是每个租户自定义角色

### Takeaway
主流默认是**「角色/权限全局定义一次，在每个组织的 membership 上授予」**（Clerk、Logto organization template、Auth0 tenant roles、WorkOS、Zitadel 项目角色）。**租户自定义角色**是较新的进阶能力：Auth0 的「Organization roles」（Early Access，角色作用域限定在某个组织）。Logto 明确不允许单个组织定制角色。

### Cited Findings
- **Clerk**：Roles 和 Permissions 在应用级定义一次、适用于所有组织；默认 admin、member 角色，可自定义；用户的角色在其 Active Organization 内确定 — [Clerk Organizations overview](https://clerk.com/docs/guides/organizations/overview)；默认成员角色可改，用于邀请、域名自动加入 — [Clerk configure organizations](https://clerk.com/docs/guides/organizations/configure)
- **Logto**：organization template 是一套角色+权限，「Each organization created in Logto will have this same set of roles and permissions」；模板改动作用于所有组织；**不能为单个组织定制角色或权限**，只能在各组织给不同用户分配不同角色；全局（用户）角色只能含 API resource 权限，组织角色可含 API 权限与组织权限 — [Logto organization template](https://docs.logto.io/authorization/organization-template)
- **Auth0**：两类角色——tenant roles「Defined at the tenant level」、Organization roles「Scoped to a specific Organization」；**Organization Roles 处于 Early Access，需联系支持开通**；成员仍可被授予 tenant 级角色（须先在 tenant 中创建）— [Auth0 add member roles](https://auth0.com/docs/manage-users/organizations/configure-organizations/add-member-roles)；无组织上下文时 tenant roles 照常生效 — [Auth0 work with tokens and organizations](https://auth0.com/docs/manage-users/organizations/using-tokens)
- **Auth0 概述页**：角色「assigned to members of each organization」，应用用其做访问控制 — [Auth0 Organizations overview](https://auth0.com/docs/manage-users/organizations/organizations-overview)
- **WorkOS**：token 的 `role` / `permissions` 来自所选组织 membership — [WorkOS sessions](https://workos.com/docs/authkit/sessions)
- **Zitadel**：角色定义在 Project 上；通过 Project Grant 把项目角色授权给其它组织，由该组织给自己的用户分配 — [Zitadel organizations](https://zitadel.com/docs/concepts/structure/organizations)；token 里角色按组织展开 — [Zitadel claims](https://zitadel.com/docs/apis/openidoauth/claims)
- **Keycloak Organizations**：组织内可建层级 groups，并可把组织 groups 映射进 token — [intro.adoc](https://github.com/keycloak/keycloak/blob/main/docs/documentation/server_admin/topics/organizations/intro.adoc)；[mapping-organization-claims.adoc](https://github.com/keycloak/keycloak/blob/main/docs/documentation/server_admin/topics/organizations/mapping-organization-claims.adoc)
- **Cognito**：groups 作为 RBAC 机制，可按 group 优先级选 IAM role — [Cognito group-based multi-tenancy](https://docs.aws.amazon.com/cognito/latest/developerguide/group-based-multi-tenancy.html)

### Inferences
- 对脚手架而言，「roles 表全局 + user_roles 增加 org_id（即 membership_roles）」覆盖了 Clerk/Logto/WorkOS 的主流形态；如果将来要支持租户自定义角色，只需给 roles 加可空 org_id（NULL = 全局模板角色，非 NULL = 某组织私有角色），这正是 Auth0 tenant roles + Organization roles 的并存形态。
- 权限点（permission）本身最好始终全局定义（代码里写死的检查点），租户只组合角色；否则代码无法对未知权限点做判断——Logto「组织权限只能在模板中定义」也是这个道理。

### Gaps
- Auth0 Organization Roles 的 GA 时间、每组织角色数量上限未找到。
