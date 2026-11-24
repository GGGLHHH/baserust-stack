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
- **库**(rust-idm、rust-content、cadenza):项目不复制,和底座用同一个仓库、同一个版本(后端按 git tag、
  前端按 npm 版本)。项目需要改库,就去改库本身、发新版。
- 不用 GitHub 的 fork:公开仓库的 fork 不能设成私有。

## 起项目

在底座(本仓库,干净的工作区、子模块已对齐)里:

```bash
gh auth status                                  # 需要 GitHub CLI 已登录
./scripts/new-project.sh shop                   # 当前账号下建 3 个私有仓库;--owner my-org 建在组织下
```

脚本会:
1. 建 `shop-stack`、`shop-backend`、`shop-frontend` 三个仓库,把底座当前版本连同历史推上去;
2. 在 `../shop-stack` 检出总仓库:子模块 `baserust/`、`basereact/` 指向项目仓库,库仍指向底座;
   本机开发 compose 的项目名改成 `shop-stack`(和底座同时跑不撞容器);
3. 写 `project.env`(底座各仓库的地址和分支,同步时用),提交并推送。

然后:
- **改品牌**:`basereact/src/brand.tsx`(侧边栏名称 / 图标)、`basereact/src/i18n/locales/*/common.json` 的 `appTitle`、
  `basereact/public/` 下的图标。
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
3. 总仓库的子模块指针:后端 / 前端用刚合并出来的提交,库跟底座走,`.gitmodules` 保留项目自己的;
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
   只在 4 处装配(`features/mod.rs`、`app/state.rs`、`app/router.rs`、`infra/openapi.rs`)各加一两行;
   前端放 `src/business/<模块>/`、`src/routes/admin/_shell/<模块>/`。
3. **项目的迁移从 1000 开始编号**(`migrations/app/1000_create_orders.up.sql`…):底座用 0001–0999,
   两边各加迁移时编号不会撞。sqlx 按编号顺序执行还没跑过的迁移,底座后来加的 00xx 照样会执行。
4. **底座的通用问题回底座修**:发现底座的 bug、想加通用能力,先在底座里改、发版,再同步过来。
   在项目里直接改底座的文件,下次同步就要处理冲突。
5. **示例模块先别删**(`widget`、多级演示菜单):删了以后底座每次改它们都会报「修改 / 删除」冲突。
   一定要删也行,那时冲突选删除(`git rm`)即可。
6. **文案**:项目自己的文案用新的 key,别改底座已有 key 的位置;`common.json` 冲突了按 key 合并就行。

## 本机开发

项目和底座、别的项目在同一台机器上同时跑时,compose 项目名已经各不相同;端口改 `.env.compose`
(总仓库)和 `baserust/.env`、`basereact/.env`。
