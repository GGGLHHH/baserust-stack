# 单机多租户 · 完成报告

> 日期：2026-11-25（夜间完成）。设计：`docs/superpowers/specs/2026-11-25-multi-tenant-design.md`；计划：`docs/superpowers/plans/2026-11-25-multi-tenant.md`；调研：`docs/research/reports/多租户架构业内做法.md`。
> 执行记录（每个任务的简报、实现报告、评审 diff、裁定账本）：`.superpowers/sdd/2026-11-25-multi-tenant/`（git 忽略，确认提交后可删）。

## 一句话

按设计文档做完了全部 12 个任务 + 1 个补充后端任务 + 终审修复，**所有改动都在各仓库 `feat/multi-tenant` 分支的工作区里，没有 commit、没有 push、没有打 tag**（你的规则）。下面「待你批准」一节列了要做的远端动作。

## 做了什么

- **rust-idm（版本号改为 0.6.0）**：`tenants` / `tenant_members` / `member_roles` 三张表；角色分平台/租户两类；会话记当前租户；登录进最近用过的组织；`switch_tenant`、`my_tenants`、`login_with`（后台按条件挑组织）；注册自动加入默认组织（同一事务）；token 带 `tenant_id` / `tenant_roles`；迁移 0004 把老账号、老角色、老会话都归入默认组织。
- **rust-content（版本号改为 0.4.0）**：`ContentScope { Tenant, Personal }`；每个方法在自己事务里 `set_config('app.tenant_id', …, true)` + SQL 显式租户条件；五张表 ENABLE + FORCE RLS；新对象 key `tenants/{tenant}/…`、个人内容 `personal/{owner}/…`；迁移 0003 把旧数据归入默认组织。
- **baserust**：
  - PG 账号拆成 `<schema>_owner`（迁移）/ `<schema>`（运行时，非 owner、不能绕过 RLS）/ `<schema>_system`（后台任务）；升级脚本 `scripts/initdb/10-tenancy-roles.sh` 幂等；`tests/rls_audit.rs` 守护「每张业务表都开了 RLS、运行时账号不是 owner」。
  - 内核 `TenantId`（拒 nil）、`CurrentTenant` 提取器（缺租户 403 `tenant_required`）、权限分平台级/组织级。
  - widget、content、搜索成员索引、认证审计、事件和后台任务全部按组织隔离；个人资料全局一份，头像走个人作用域，旧头像启动时自动修复。
  - 新接口：`GET /frontend/auth/tenants`、`POST /frontend/auth/switch-tenant`、平台组织管理 `/admin/platform/tenants…`、组织成员管理 `/admin/auth/members…`、`PUT /profiles/me`、`POST /profiles/me/avatar`。
  - seed 支持 `[[tenants]]` 和成员关系，默认组织固定 id `00000000-0000-0000-0000-000000000001`。
- **basereact**：后台组织切换器（≥2 个组织才显示；2026-11-26 起前台不再提供切换，跟随当前组织）、多标签页同步、「还没加入任何组织」页（有组织时可直接选择进入）、平台「组织管理」、组织「成员」页、「账号管理」页；界面统一叫「组织」。
- **部署 / 文档**：`deploy.sh` 升级时跑账号拆分脚本和 `rebuild_search`；`init.sh --add-missing` 补新密码；`scripts/prod/README.md`、`docs/new-project.md`（含「同步多租户版本后要做的事」）、baserust CLAUDE.md 与 skills、两个库的 README 和发版说明都已更新。

## 2026-11-26 角色补充：superadmin 独占 + 平台管理员

- **角色 4 级**：`superadmin`（只有一个，用户本人，只由 seed 声明，任何接口都授不出 / 撤不掉）/ `platform_admin` 平台管理员（新增，可多个，superadmin 在「账号」页任命）/ 组织角色 `admin` / `user`。
- **superadmin 独占**：系统监控（`ops:read`）、登录日志（`audit:read`）、任命 / 撤销平台管理员与管理持平台角色的账号（`platform:roles`）；superadmin 账号本身没人能改。
- **平台管理员**：组织管理（开、停、改名、指定成员与组织管理员）、普通账号管理（建号、重置密码、删除）都能做；碰不到 superadmin 和其他平台管理员；看组织业务数据仍要先成为该组织成员。
- **防接管**：动持平台角色的账号（账号接口、平台成员接口、组织内成员接口）都要 `platform:roles`——修掉了一个真实漏洞：之前默认组织的 admin 能把 superadmin 在默认组织里降成 user 或移出。
- **升级必看**：库里若已有多个 superadmin（以前能在后台授给别人），idm 进程会拒绝启动并列出用户名，按 `scripts/prod/README.md`「清理多余的 superadmin」删掉多余授予；回滚到之前版本前先跑同一节的回滚 SQL。
- 演示账号（非 prod 的 mock）：`platform_admin` / `pwd`。
- 细节见设计文档 §7；执行记录 `.superpowers/sdd/2026-11-25-multi-tenant/task-pa-report.md`。

## 验证结果（最后一轮）

| 仓库 | 结果 |
|---|---|
| rust-idm | `cargo test` 46 通过；PG 30 通过；lint 通过 |
| rust-content | `cargo test` 28 通过；PG 17 通过；lint 通过 |
| baserust | `just check` / `just lint` 通过；`just test` 522 通过；PG 41 通过（含 rls_audit）；NATS 6、搜索投影 e2e 1、持久事件 e2e 1 通过 |
| basereact | lint 0 错误（6 条原有弃用警告）；tsc 通过；183 个用例通过 |

- **升级演练**：用 origin/master 的旧结构建库造数据，再按新流程升级——老账号登录直接进默认组织，原来的 widget、内容、头像都在，RLS 审计通过。
- **整栈走查**（浏览器）：登录、切换组织、跨组织访问 404、组织管理、成员页都正常；截图在 `.superpowers/sdd/2026-11-25-multi-tenant/shots-final/`。
- 每个任务都有独立评审，最后做了一次整分支评审，发现的 5 个重要问题里能本地修的都修了并复审通过。

## 待你批准（每一项都是远端或提交动作，按你的规则没做）

1. 各仓库在 `feat/multi-tenant` 分支本地提交（rust-idm 16 个文件、rust-content 16、baserust 139、basereact 59、总仓库 12 个）。提交 baserust 时先 `git add` 再执行 `git -C baserust update-index --chmod=+x scripts/initdb/10-tenancy-roles.sh`（Windows 上新脚本默认没有可执行位）。
2. 推送 rust-idm、rust-content，打 tag `v0.6.0` / `v0.4.0`（发版说明里写了公开 API 变化）。
3. baserust `Cargo.toml` 把 idm / content 从本地 path 依赖改回这两个 tag，更新 `Cargo.lock`。**不改回去 baserust 单独构建和 CI 会失败。**
4. 推送 baserust、basereact，再更新总仓库的子模块指针并推送；需要的话开 PR。

## 我替你做的决定（请过目，不同意的告诉我）

1. 库的测试自己建一个只用于测试的非 owner 账号来验证 RLS，不依赖 baserust。
2. `TenantId` 类型提前到账号拆分那一步定义。
3. 注册「建账号 + 加入默认组织」做成同一个事务（新增 `create_with_membership`）。
4. 保留额外的 `tenant.deleted` / `tenant.member_updated` 事件和组织软删方法。
5. idm 构建时成员仓储必填，不允许「不启用多租户」的悄悄降级（对应你说的不加开关）。
6. 认证审计表 `auth_event` 作为平台级全局表，只给 superadmin 看（2026-11-26 起是 superadmin 独占的 `audit:read`；以后要做组织自己的登录日志页再加策略）。
7. 迁移用的 owner 账号允许绕过 RLS（它本来就能关 RLS，没有安全损失；否则修数据的迁移会悄悄改 0 行）。
8. 后台「账号管理」只授平台角色；组织内角色只能通过成员关系授予。
9. 原来公开的 `/widgets/stats` 改成需登录、按当前组织计数（公开接口会泄露全平台总量，widget 又是照抄样板）。
10. 重新上传头像后自动软删上一张（防止零权限接口无限堆积）；代价是被替换的头像不能再绑回。
11. 后台 `/users` 始终是全部账号列表；组织成员用新的「成员」页。
12. 成员管理放在新的 tenants 模块；成员角色按名字传，只能是 admin / user。
13. 追加了一个后端任务：后台登录优先进「有后台权限的那个组织」，没有组织的账号返回 `tenant_required`，组织管理员能看到「组件」菜单。
14. 界面上统一叫「组织 / Organization」，不叫「租户」。
15. 升级时把老会话回填到默认组织，用户无感；旧 content 里客户端随便传过的 `tenant_id` 一律归入默认组织。
16. 暂不做「公开注册加入哪个组织可配置」，按设计固定加入默认组织（多组织部署时要留意：注册用户会进入承载旧数据的默认组织）。

## 已知限制 / 后续可做

- 停用组织、移除成员对已发出的 access token 最长延迟 15 分钟生效（设计如此）；改成员角色也是下次刷新才生效。
- 部署时开 RLS 的迁移运行期间，旧容器会短暂读到空、写入失败；README 建议迁移前先停 app/idm。
- 被替换的头像只软删了数据库记录，对象存储里的文件还在。
- 已打开的 SSE 流不会因切换组织而断开（前端目前没用 widget SSE）。
- 分进程部署下，idm 进程的权限策略来自 seed，运行时改 `role_permissions` 不会同步到 idm 进程。
- 没有「切回平台上下文」的界面入口（平台权限在组织里同样有效，不影响使用）。
- baserust 工作区有 148 个文件是 CRLF 换行（以前就有，不是这次改的），会让从 git 源码建的库迁移校验和不符；以后统一成 LF 前先想好本机开发库怎么处理。
- 「组织选择」空状态页只有组件测试，没在浏览器里实际点过。

## 环境

- 我起的测试容器 `mt-test-pg`（15821）、`mt-test-nats`（14222）已删除。
- 编译缓存留在 `C:\Users\Administrator\code\.mt-target`（可能有几 GB），sqlx-cli 在 `C:\Users\Administrator\code\.mt-tools`；不需要了可以直接删这两个目录。
- 测试过程中没有动你的 `baserust-*` 容器、开发库和其他进程。
