## 栈专属门禁（TypeScript）

本仓的栈专属约束**编在构建里**，不是写在文档里（`CONTRIBUTING.md` §8）。

| 载体 | 约束 |
|---|---|
| `tsconfig.json` | `strict` + `noUncheckedIndexedAccess` + `noUnusedLocals` / `noUnusedParameters` |
| `package.json` 脚本 | `typecheck` / `test` / `build`——CI 与本地**同名同源**（改一处两处同改） |
| `package-lock.json` | CI 用 `npm ci` 严格按 lock 安装（lock 与 manifests 失同步即失败） |
| `.github/workflows/verify-clean-build.yml` | 前端线：`npm ci` → typecheck → test → build（与主门禁**并列、互不阻塞**） |

**纪律**

- `tsc --noEmit` 必须**零错误**；lint 用 `--max-warnings 0`——"warn 不算 fail"是失守的典型入口。
- **每个工作包至少一个用例**（vitest / jest 皆可）。
- 前端目录**以实际仓库为准**：`verify-clean-build.yml` 里的 `isFrontend` 判据与作业的 `working-directory` / `cache-dependency-path` 必须同步改。
- 依赖升级属门禁级改动（会动 lock）：单独成批，别混进业务提交。

> 起步配置与理由见模板仓 `variants/typescript/README.md`（含 tsconfig 节选）。
