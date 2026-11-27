# 三个仓库按 Google Rust 风格指南全面修正（2026-11-27）

- 来源：code-fd 会话转达的用户决定：「全面贴合,所有都是」。7 项全部按指南改，rust-idm、rust-content 一起改。
- 指南：https://google.github.io/styleguide/rustguide.html（[chrome]/[Fuchsia] 条目不适用）。
- 三个仓库各在本地分支 `style/google-rust-guide` 上。**全部未提交、未推送、未打 tag。**

| 仓库 | 基准 | 改动 | 版本 |
|---|---|---|---|
| rust-idm | master 00f4e4d | 20 个文件改动 + 17 个新增/改名，+4552 / −4551 | 0.6.0 → **0.7.0** |
| rust-content | master fa3e600 | 19 个文件改动 + 18 个新增/改名，+961 / −3737 | 0.4.0 → **0.5.0** |
| baserust | master 857f671 | 195 个文件，+17195 / −13324，另有 47 个新增/改名 | — |

## 依赖怎么联调（提交前必读）
- baserust 的 Cargo.toml **还是**按 git rev 引用旧版库（idm 00f4e4d、content fa3e600），Cargo.lock 也和 HEAD 一致。所以**直接编译 baserust 会失败**：代码已经在用新版库的 API。
- 联调用的是 `baserust/.cargo-local-patch.toml`：用 [patch] 把两个库指到本地路径（绝对路径）。这个文件已加进 `.git/info/exclude`，不会被提交。
  - 用法：`cargo <子命令> --config .cargo-local-patch.toml …`，`--config` 要放在子命令后面。
  - 第一次用之前先跑 `cargo update --config .cargo-local-patch.toml -p idm -p content`。
- 机器上的 rust-analyzer 会把 baserust 的 Cargo.lock 改回 git 版本，所以 baserust 的编译和测试是在镜像目录里跑的（源码同步过去，Cargo.lock 不同步）。镜像目录已经删了。
- **正式发布的顺序：**
  1. 提交并推送 rust-idm 和 rust-content，打 tag `v0.7.0` / `v0.5.0`；
  2. baserust 的 Cargo.toml 改成按这两个 tag 引用，再 `cargo update -p idm -p content`；
  3. 提交 baserust；
  4. 在 stack 更新四个子模块指针。stack 的 CI 会核对子模块和 Cargo.lock 锁的提交是否一致。

## 工具守的部分（三个仓库一致）
- **格式：** `rustfmt.toml` 设 max_width = 100；nightly rustfmt 用 `--config imports_granularity=Module,hex_literal_case=Lower,format_macro_matchers=true`。`just fmt` / `just lint` 和 CI 都跑这两种检查。需要先装 nightly rustfmt。
- **lint：**
  - 三个仓库都开了：absolute_paths（路径最多两段）、must_use_candidate、return_self_not_must_use、missing_panics_doc、redundant_clone，产品代码另开 unwrap_used。
  - 两个库额外开了 `missing_docs`、`exhaustive_enums`、`exhaustive_structs`。
- `clippy.toml`：测试里允许 unwrap / expect。

## 用户 7 项决定的落实
1. **构造函数命名**：返回 Result 的构造函数改为 `try_new`（有多个时用 `try_new_with_xxx`），例如 TenantId、AppState、AppTokenSigner/Verifier、NatsEventBus、JetStreamPublisher、两个 Projector、Config、SeedData、MockData、ContentScope。不会失败的具名构造函数改成 `new` / `new_with_xxx`；值到值的转换保留 `from_xxx`，并补了 From 实现；已有 FromStr 的删掉自定义的 parse 方法。
2. **借用参数**：`emit_auth_event` 改收 `Option<&dyn OutboxRepo>`；公开签名里已经没有 `&Option` / `&Arc` / `&Box` / `&Vec` / `&String`；idm 和 content 写方法的审计主体参数都改成 `by: Option<&str>`。
3. **具名结构体**：多字段元组返回值和同类型的位置参数都改成了具名结构体，例如 UpsertedProfile、PutProfileOutcome、ResolvedMember、Instance*Totals、LogPage、AssembledApp、SuccessEventData / FailureEventData、IpSources、S3Settings、TimeRange、PermissionCheck、OffsetPosition、AccountCreated / AccountUpdated、OutboundEvent、LogOrigin、ConsumerBacklog、Watermarks、DurableConsumer，以及 idm 的 MemberKey、NewUser、NewRole、NewTenant、RoleGrant，content 的 ObjectLocation。bool 参数改成了 enum：PresignUrlStyle、MetricsEndpoint、ProjectorOutcome。
4. **缩写改全称**：例如 Perm→Permission、PermReq→PermissionRequirement、OpAuthz→OperationAuthorization、Hist→Histogram、op_perms→operation_permissions、authz→authorization、tenant_tx→tenant_transaction、PwHasher→PasswordHasher、SortDir→SortDirection、ObjectMeta→StoredObjectMetadata；字段 q/t/ts/*_secs/open_fds 等也改了。局部变量里约 300 处单字母名和删字母缩写都改成了全称。线上的 JSON / 查询参数 / 环境变量名用 serde rename 保持原样，有测试钉住；OpenAPI 快照**一个字节都没变**。
5. **文件按主要条目命名**：baserust 改名 40 多个、拆分 3 个，例如 app/state.rs→app_state.rs、各 feature 的 service.rs→<x>_service.rs、postgres.rs→pg_<x>_repo.rs，完整对照表见 baserust 的 agent 报告和 CLAUDE.md。两个库的 repo/mod.rs、service.rs、error.rs 等也拆分或改了名。
6. **既定例外重新判断**（写进 baserust CLAUDE.md，标题是「符合指南条款的例外情形」，并附条款原文）：
   - `Arc<dyn Port>`：**保留**。按「Apply API design rules in context」，baserust 是应用代码，「Generics versus dyn Trait」只约束库；另有「Avoid Rc and Arc」的 *unreasonably complex* 例外。
   - 按层命名的文件：**改了**。只剩没有单一主要条目的叶子模块（model / ports / dto / routes 等），依据 *can be named as desired*。
   - features/*/mod.rs 的 glob 再导出：**改了**，改成按名再导出。被导出的是另一个 crate 的模块，不是本模块的子模块，不在例外里。architecture 测试加了守卫。
   - baserust 不加 `#[non_exhaustive]`：**条款不适用**，前提是 *used by other teams*。
   - CatchPanicLayer：**保留**，属于 catch_unwind 的 defense in depth 例外。
7. **两个库按库代码强制规则改**：
   - 服务改成泛型：`AuthService<U,S,R,M>`、`ContentService<C,O,S,K>`；所有端口 trait 都有 `Arc<T>` / `Box<T>` 转发实现，全部方法都转发，有测试证明。
   - `#[non_exhaustive]` 加在约 20 + 10 个公开类型上，配了构造函数。例外都写了条款依据：两态枚举、FRU 选项结构体、复合主键 / 既有本体。
   - `missing_docs` 补齐；错误类型和 builder 加了 `#[must_use]`。
   - 迭代器条款：仓储返回 Vec 属于 *naturally constructs a vector* 例外；仓储参数收切片，是为了让端口保持 dyn 兼容。

## 不兼容变更清单
- **rust-idm 0.7.0**：见 rust-idm/README.md 的「0.7.0」节（旧 → 新对照表）。要点：
  - AuthService 改成泛型 + builder，不再 Clone；
  - switch_tenant 和成员仓储改用 MemberKey；
  - NewUser / NewRole / NewTenant / RoleGrant；
  - PwHasher→PasswordHasher，SortDir→SortDirection，sharing_with→new_shared_with；
  - TTL 改用 Duration；by 改为 `Option<&str>`；
  - 约 20 个类型加了 non_exhaustive；`idm::password` 改成私有模块；
  - SessionRepo::revoke 返回 bool（00f4e4d 起）。
- **rust-content 0.5.0**：见 rust-content/README.md 的「0.5.0」节。要点：
  - ContentService 泛型化，builder(c, o, s)；
  - by 改为 `Option<&str>`；
  - ObjectMeta→StoredObjectMetadata，UploadParams→UploadRequest；
  - get_by_key→get_by_location（PG 监控的 span 名同步改了）；
  - ContentScope::tenant→try_new_tenant，from_db→FromStr；
  - non_exhaustive 类型改用构造函数。
- **baserust**：不改对外 HTTP 契约（OpenAPI 快照不变）。Rust 内部 API 的变化见上面的改名和结构体清单，测试和文档都同步了。

## 只在异常路径上的行为变化
- 锁中毒统一为「丢弃中毒状态并重置」：监控重置后不虚高，SSE 计数不会变负。
- `LOG_FILE` 打不开时返回带上下文的错误，不再 panic。
- unix 下 SIGTERM handler 装不上时不再一启动就退出（原来就有的 bug）。
- 日志分页的 offset 用饱和乘法。
- idm 输入结构体的 Debug 输出把密码打成 `<redacted>`。
- content 的 builder 要求三个端口都必填（原来漏传会在运行时 panic）。
- 依赖库里 non_exhaustive 枚举的未知变体：错误映射成 500；登录审计的未知失败原因记成 bad_password 并打 warn。

## 验证（主控最后亲自重跑，全部通过）
| | rust-idm | rust-content | baserust（带补丁） |
|---|---|---|---|
| 稳定版 + nightly 两种 fmt --check | ✓ | ✓ | ✓ |
| clippy -D warnings | ✓ | ✓ | ✓（--all-features 和默认各一遍） |
| 单元 / 契约测试 | 65 | 39 | 569（openapi_snapshot 不变） |
| PG conformance | 40 | 21 | 45 |
| NATS / 端到端 | — | — | 6 / 2 |
| cargo doc -D warnings | ✓ | ✓ | — |

## 后续补修（同日，用户「现在能够修复吗,可以的话就直接修复」）
- **OpenAPI 描述里的过时注释**：dto.rs 的 `ContentStatusView` 说成 `From` 穷尽匹配，实际是 `TryFrom` + 通配 → 500；widget 路由 4 处旧名 `OP_PERMS` / `PermReq` / `None`。都改成了现名。快照已接受，差异**只有这 5 条描述**；basereact 从临时后端重新生成了 `src/generated/api-types.d.ts`，差异同样只有这 5 处注释（basereact 工作区现在有这一处未提交改动）。CLAUDE.md / AGENTS.md 的对应说明已同步。
- **rust-content 注入时钟不生效**：时间戳改成一律由 service 经 `Clock` 决定，仓储按传入值落库。
  - `NewContent::new(owner_id, created_at)` / `NewObject::new(content_id, location, created_at)`；仓储写方法 `update` / `set_status` / `soft_delete` 加参数 `at`（在 `by` 前）；`set_metadata` 用传入的 `updated_at`，已有行保留原 `created_at`。
  - 新迁移 `0004_explicit_timestamps`（rust-content 与 baserust `migrations/content` 各一份，LF）：`set_updated_at_utc()` 只在 UPDATE 没改 `updated_at` 时置 `now()`；仓储事务另设事务级开关 `app.explicit_updated_at = 'on'`，开着时一律保留传入值（同一个 now 先建行再翻状态时新旧值相等，光比较分不清）。已有迁移一个字节没动。
  - 兼容性：新代码配旧库（没跑 0004）时，`updated_at` 仍会被触发器改成 DB 时间，其余正常；旧代码配新库时，触发器行为与原来相同。
  - README「已知问题」整节删除，0.5.0 节补了对照表和升级步骤（拷 0004）。
- **验证（全部重跑）**：rust-content fmt 两种 ✓、clippy 0、测试 43、PG 23（含新契约 `timestamps_follow_input_contract`）；baserust（带补丁）fmt 两种 ✓、clippy 两遍 0、569、PG 45（测试库按 baserust 的 `migrations/` 迁移，含 content 0004）、NATS 6、端到端 2（content 也接 PG）。临时容器和镜像目录已删除。

## 已知、没改的
- 触发器沿用 0001 的 `now() at time zone 'utc'`：会话时区不是 UTC 时有偏差（原有问题；仓储写入已不经过它）。
- content 迁移 0003 会改写旧行的 updated_at（上一轮已记录）。
- 我曾误把工作区里原本是 CRLF 换行的文件（含已执行的迁移）转成了 LF，已全部按原字节恢复。git 差异里只有真正改动的文件，迁移校验和不受影响。
## 陈旧代码清理（同日，用户「不要有任何遗漏,修复或清理掉陈旧不再需要的代码」）
四个仓库各由一个代理按同一份清单清查：死代码、过渡 / 兼容机制、依赖、陈旧文档注释、工具链配置、测试。主控最后统一复验。
- **rust-idm**：删掉多余的 derive 和 allow；依赖 feature 收窄（tokio 只留 `rt`，测试用的放进 dev-dependencies；uuid 去掉 `v4`，time 改用 `serde`，argon2 去掉 `std`）；纠正过时的文档注释（token claim 示例、`emit_outbox`、spec 引用、「Task / 复审 #n」这类编号）。
- **rust-content**：删掉从没被调用的 `check_uploadable` / `check_downloadable` 守卫和 `DerivedContent` 占位类型（`content_derived` 表和迁移保留）；测试里的两处 `allow(dead_code)` 去掉了；tokio 改为 dev 依赖，sqlx 关掉默认 feature，只开用到的；清理「v0.1 / SCAFFOLD-CORE / spec §6」这类过时说法。
- **baserust**：
  - 删掉 `InMemoryAppOutbox::new`、投影器 `Envelope` 里两个从不读取的字段、多余的 `allow(dead_code)`；
  - `rls_audit` 的 `PENDING_TABLES` 过渡清单已经为空，整套机制删除；
  - 根 Cargo.toml 删掉 argon2 / sha2 / rand / thiserror，core 去掉 uuid `v4` 和 tokio `rt`；
  - 约 20 处注释、测试名、seed 配置、compose、nginx 注释里的旧名或旧路径改正；
  - stack 的 README、`docs/new-project.md`、`scripts/check-git-deps.sh` 里「按 tag」改成「tag / rev」，端口说法也改正了。
- **OpenAPI 描述另改了两处**：`/health` 的说明（它是生产 nginx 唯一的探活入口，不是「兼容别名」），以及 `Permission` schema 说明里的 `Perm::WidgetWrite`。快照已接受，差异只有这两条描述；basereact 的 `api-types.d.ts` 已经重新生成，累计差异只有 7 处注释。
- **basereact**：删掉 54 个没人用的 shadcn ui 文件，以及其它无引用的文件、导出、i18n key、public 资源和 16 个依赖；`#/` 路径别名删除，3 个 loader 换成新的 `query` 写法；README 从模板内容重写；.claude/skills 和注释里过时的说法改正。共 118 个文件，+205 / −9582。
- **查过、有意保留的**：
  - `/health` 接口：生产探活用；
  - `repair_legacy_avatars`：老库升级要跑；
  - seed 旧格式兼容：已部署实例的 seed.prod.toml 可能还在用旧写法；
  - 投影器对缺 `tenant_id` 旧消息的兼容：JetStream 里可能还留着旧消息；
  - idm 对旧 token 的兼容；
  - basereact 里只有测试在用的认证 / 上传 hook：脚手架 API 层，对应后端现有接口，今天的提交还改过；
  - `route-guard.ts` 里 3 处弃用的 `ensureQueryData`：新 API 没有「过期也先放行、后台再验」的写法。
- **复验（主控）**：
  - rust-idm：fmt 两种 ✓，clippy 0 警告，测试 65，PG 40（代理跑）；
  - rust-content：fmt 两种 ✓，clippy 0 警告，测试 43，PG 23（代理跑）；
  - baserust（带补丁）：fmt 两种 ✓，clippy 两遍 0 警告，测试 569，PG 45，NATS 6，端到端 2；
  - basereact：lint 0 错误（3 个警告就是上面保留的 `ensureQueryData`），tsc ✓，测试 227，build ✓（代理跑）。
  - 已有迁移一个字节没改；临时容器和镜像目录都已删除。
