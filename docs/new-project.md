# 用底座起新项目,并持续同步底座更新

baserust-stack 是**底座**:新项目从它起,起了以后底座的修复和新功能还能**一直合并过去**。

## 仓库关系

```
底座(GGGLHHH)                          项目 shop(可以在别的账号 / 组织下,默认私有)
baserust-stack ──── 起项目时复制历史 ────▶ shop-stack      (总仓库,多一个 project.env)
  ├─ baserust  ──── 起项目时复制历史 ────▶   ├─ shop-backend   (目录仍叫 baserust/)
  ├─ basereact ──── 起项目时复制历史 ────▶   ├─ shop-frontend  (目录仍叫 basereact/)
  ├─ rust-idm      ┐                         ├─ rust-idm      ┐
  ├─ rust-content  ├ 库:不复制,项目直接用底座的 ├─ rust-content  ├ 同一个仓库,跟着底座的版本走
  └─ cadenza       ┘                         └─ cadenza       ┘
```

- **后端、前端、总仓库**:项目各有一份,带着底座的完整提交历史 —— 有共同历史,git 才能三方合并,
  底座的更新才能一次次合进来。
- **库**(rust-idm、rust-content、cadenza):项目不复制,和底座用同一个仓库、同一个版本(后端按 git tag / rev、
  前端按 npm 版本)。项目需要改库,就去改库本身、发新版。
- 不用 GitHub 的 fork:公开仓库的 fork 不能设成私有。

## 起项目

在底座(本仓库,干净的工作区、子模块已对齐、提交都已推送)里:

```bash
gh auth status                                  # 需要 GitHub CLI 已登录
./scripts/new-project.sh shop                   # 当前账号下建 3 个私有仓库;--owner my-org 建在组织下
```

脚本会:
1. 建 `shop-stack`、`shop-backend`、`shop-frontend` 三个仓库,把底座当前版本连同历史推上去;
2. 在 `../shop-stack` 检出总仓库:子模块 `baserust/`、`basereact/` 指向项目仓库,库仍指向底座;
   本机开发 compose 的项目名改成 `shop-stack`(和底座同时跑,容器、数据卷、镜像都不撞);
3. 写 `project.env`(底座各仓库的地址和分支,同步时用),提交并推送。

然后:
- **改品牌**:`basereact/src/brand.tsx`(侧边栏名称 / 图标)、`basereact/src/i18n/locales/*/common.json` 的 `appTitle`、
  `basereact/public/` 下的图标。
- **CI**:总仓库的 CI 要检出子模块。项目仓库是私有的,默认的 `GITHUB_TOKEN` 读不到另外两个仓库:
  在 `shop-stack` 的 Settings → Secrets 里加 `SUBMODULES_TOKEN`(能读 `shop-backend`、`shop-frontend` 的 fine-grained token)。
- **部署**:`just prod-init --name shop --port 8081` → `just prod-build --all`(见 [scripts/prod/README.md](../scripts/prod/README.md))。
  同一台服务器上多个项目:项目名、端口不同即可,compose 项目名、目录、容器名、镜像名都按项目名区分。

## 同步底座更新

在项目的总仓库里:

```bash
./scripts/sync-base.sh             # 合并 + 检查 + 跑测试
./scripts/sync-base.sh --no-test   # 只合并和做一致性检查
```

1. 取底座总仓库的最新提交,按它钉住的后端 / 前端版本合并(底座每个提交 = 一组能一起跑的版本,不追各仓库的最新提交);
2. 后端、前端、总仓库各开一个 `sync/base-<日期>` 分支合并;
3. 总仓库的子模块指针:后端 / 前端用刚合并出来的提交,库跟底座走;`.gitmodules` 取底座的(底座新加的库也带过来),
   后端 / 前端的地址保留项目自己的;
4. 检查子模块和 `Cargo.lock` 一致、nginx 配置没漂移,再跑后端 lint / test、前端 lint / tsc / test;
5. **不推送**:看过以后按脚本最后打印的命令推(先后端、前端,最后总仓库),再照常打包部署。

**有冲突**:脚本停下并列出文件。进对应目录解决、`git add`、`git commit`,再运行一次脚本,已经合并好的会跳过。
生成的文件冲突了不用手改,随便取一边,再重新生成:

| 文件 | 重新生成 |
|---|---|
| `basereact/src/routeTree.gen.ts` | `pnpm generate-routes` |
| `basereact/src/generated/*` | 起后端后 `pnpm generate` |
| `baserust/tests/snapshots/openapi_snapshot__openapi.snap` | `just openapi-snapshot-accept` |
| `Cargo.lock` / `pnpm-lock.yaml` | `cargo check` / `pnpm install` |

**多久同步一次**:底座每发一版就同步一次。小步多次,每次冲突都很少;攒半年再合,冲突会很多。

## 怎么改,以后才好同步

冲突来自「项目和底座改了同一个地方」。按下面的约定改,大部分同步不会有冲突:

1. **内部名字不改**:目录名(`baserust/`、`basereact/`)、crate 名、schema / role 名、环境变量名、
   脚本里的路径。改名会让底座之后对这些文件的每次改动都冲突。对外的名字全靠参数:项目名(`--name`)、
   品牌文件、`.env.prod` 里的域名和端口。
2. **业务代码放新文件**:后端照 `widget` 加 `crates/core/src/features/<模块>/` + `src/features/<模块>/`,
   只在 4 处装配(`features/mod.rs`、`app/app_state.rs`、`app/router.rs`、`infra/openapi.rs`)各加一两行;
   前端放 `src/business/<模块>/`、`src/routes/admin/_shell/<模块>/`。
3. **项目的迁移从 1000 开始编号**(`migrations/app/1000_create_orders.up.sql`…):底座用 0001–0999,
   两边各加迁移时编号不会撞。sqlx 按编号顺序执行还没跑过的迁移,底座后来加的 00xx 照样会执行。
4. **底座的通用问题回底座修**:发现底座的 bug、想加通用能力,先在底座里改、发版,再同步过来。
   在项目里直接改底座的文件,下次同步就要处理冲突。
5. **示例模块先别删**(`widget`、多级演示菜单):删了以后底座每次改它们都会报「修改 / 删除」冲突。
   一定要删也行,那时冲突选删除(`git rm`)即可。
6. **文案**:项目自己的文案用新的 key,别改底座已有 key 的位置;`common.json` 冲突了按 key 合并就行。

## 同步多租户版本后要做的事

底座从「单租户」升到「单机多租户」(组织 = 租户;rust-idm 0.6.0 / rust-content 0.4.0)。合并本身照上面的流程,
合完以后项目**自己的代码和数据**还要跟着改,否则 `just test-pg` 会拦下来,或上线后数据串到别的组织。
设计依据:`docs/superpowers/specs/2026-11-25-multi-tenant-design.md`。

### 1. 项目自己的表:要么租户隔离,要么登记成全局表

`baserust/tests/rls_audit.rs`(`just test-pg` 里跑)会把每张表过一遍:既没开租户 RLS、又不在 `GLOBAL_TABLES` 里的 → 失败。
这是有意的提醒,二选一:

- **业务数据(默认)→ 租户隔离**:新迁移(编号 1000 起)照 `migrations/app/0006_widget_tenancy.up.sql` 写:
  加 `tenant_id uuid` → **先回填**成默认组织 `00000000-0000-0000-0000-000000000001`(子表从父行回填)→ `not null` +
  `check (tenant_id <> '00000000-0000-0000-0000-000000000000')` → 唯一 / 列表索引以 `tenant_id` 打头 →
  `enable` + `force row level security` + `tenant_isolation` 策略(USING 与 WITH CHECK 都写
  `tenant_id = nullif(current_setting('app.tenant_id', true), '')::uuid`)。**回填必须在开 RLS 之前**。
  代码照 widget 改:repo 方法收 `TenantId`,PG 实现用 `infra::pg::tenant_transaction(&pool, tenant)` 开事务、SQL 里再写
  `tenant_id = $1`;内存实现按租户过滤;handler 用 `CurrentTenant` 提取器取租户(只从 token 来);
  事件带 `tenant_id`、SSE 逐帧过滤;`tests/http_<模块>.rs` 加跨租户黑盒测试(别的组织的 id → 404、列表只见本组织)。
  细节见 `baserust/.claude/skills/adding-a-feature`。
- **确实全局的(字典、配置、按账号而不是按组织的数据)→ 登记**:把 `schema.table` 加进 `rls_audit.rs` 的 `GLOBAL_TABLES`,
  并在注释里写清为什么全局。

### 2. 项目自己的角色和权限:要有作用域

- `RoleName` 新加的角色要在 `RoleName::scope()` 里归类:平台角色(管全站,如 superadmin)或租户角色(在某个组织里生效)。
- `Perm` 新加的权限同样要在 `Perm::scope()` 里归类(穷尽 match,漏了编译不过);`perm_scopes_cover_all_variants` 测试兜底。
  平台角色**不会**自动拿到租户级权限。
- `seed.toml` 里账号的租户角色写在 `tenants = [{ slug = "default", roles = [...] }]`,平台角色写 `roles`。
- 后台组里读写组织数据的接口,闸要用**租户级**权限,别用平台级 `users:admin`,否则组织管理员看不到菜单(见 `authorization` skill)。

### 3. 数据库账号和升级顺序

app / content / search 各拆成三个账号:`<schema>_owner`(跑迁移、拥有表)、`<schema>`(运行时,只有 DML,受 RLS 约束)、
`<schema>_system`(BYPASSRLS,后台任务 / 平台级读)。

- **本机开发库**(老数据卷):先 `just db-ensure-roles`(跑 `10-tenancy-roles.sh`:建账号、把老表转给 owner、授权),
  **再** `just migrate`。顺序反了迁移会失败。`.env` 照 `.env.example` 补上 `*_DB_OWNER_*` / `*_DB_SYSTEM_*`。
- **生产**:本机 `./scripts/prod/init.sh --add-missing` 补新密码 → 重新打包部署;deploy.sh 会在迁移前拆账号、迁移后回填
  search(`rebuild_search`)。详见 [scripts/prod/README.md](../scripts/prod/README.md)「从多租户之前的版本升级」。
- **授权**:运行时 / system 账号的 DML 是靠 owner 上的 `ALTER DEFAULT PRIVILEGES` 自动拿到的 —— 项目迁移(以 owner 身份)
  建的新表不用自己 `grant`。反过来,要收紧的表自己收:比如只许 system 账号写的全局读模型,在迁移里
  `revoke insert, update, delete on <表> from <运行时账号>`。收紧**一直有效**:`10-tenancy-roles.sh`(每次部署 /
  `just db-ensure-roles` 都跑)只给**这次才从别的属主转给 `<schema>_owner` 的表**补授 DML(老库升级那一次),
  已经归 owner 的表不再重授。底座的 search 账号目录 / 认证审计(`account_index`、`auth_event`,schema 名是
  `SEARCH_DB_USER`)在 search 迁移 0003 和脚本第 6 步都收。运行时账号名可配,迁移里别写死,照 search 0003 的写法按
  「非 owner、非 BYPASSRLS 的账号」收。
  项目要是在迁移以外手工建过表 / 改过属主,再跑一次 `just db-ensure-roles` 会把它们转给 owner 并补授 DML(之后要收紧的再收一次)。
  回归测试:`baserust/scripts/tests/tenancy-roles.test.sh`。
- **换 system 账号要手动补授老表**:已经拆过账号的库上改了 `*_DB_SYSTEM_USER`(换名),或者把 system 账号删了重建
  (同名也算:删账号时授权和 default privileges 一起没了),再跑 `just db-ensure-roles` / 部署**不会**给老表补授 ——
  `10-tenancy-roles.sh` 只建账号、给 schema 的 USAGE、补上以后新表的 default privileges,老表早已归 owner,不在
  「这次才转过来」的范围里。新 system 账号拿不到老表的 DML,后台任务 / 投影器一跑就 `permission denied`。
  用 superuser 或 owner,在每个拆过的 schema(app / content / search)上手动补:

  ```sql
  grant select, insert, update, delete on all tables in schema <schema> to <新 system>;
  grant usage, select on all sequences in schema <schema> to <新 system>;
  revoke insert, update, delete on <schema>._sqlx_migrations from <新 system>;  -- 迁移台账照旧只读
  ```

  项目迁移里对 system 账号收紧过的表,补完再收一次。换名时旧账号还留着老授权和 default privileges,不用了就
  `drop owned by <旧 system>; drop role <旧 system>;`。运行时账号(`*_DB_USER`)换名 / 重建同理。
- 旧数据全部归进默认组织(`default`):账号成为它的成员、原有角色复制成成员角色、超管兼任它的管理员。

### 4. 前端

- `basereact/src/brand.tsx` 的导出从 `BRAND_TEAMS`(数组)改成了 `BRAND`(`{ name, logo, tagline }` 单个对象):
  这个文件项目一般改过,合并会冲突 —— 取底座的新结构,再把项目的名称 / 图标填回去。
  账号属于 ≥ 2 个组织时侧栏左上角变成组织切换器(名称显示当前组织,副标题是品牌名)。
- 后台「用户」页改名「账号管理」(平台账号,URL 仍是 `/admin/users`);新加「成员」(本组织成员)和「组织管理」(平台)两页。
- 项目自己的页面:接口返回 403 `tenant_required`(当前没有组织,且账号没有平台角色)时,前端会把人带到所在端的
  「没有当前组织」页(`/admin/no-tenant` / `/frontend/no-tenant`):账号属于组织就列出来选一个进入(只属于 1 个也能选),
  一个都没有才显示「还没加入任何组织」。项目页面里不要自己拼 `tenant_id` 参数,
  租户只从登录态来。改过后端接口就重新 `pnpm generate`。

## 本机开发

项目和底座、别的项目在同一台机器上同时跑时,compose 项目名已经各不相同(容器、数据卷、镜像都按它区分);端口改 `.env.compose`
(总仓库)和 `baserust/.env`、`basereact/.env`。
