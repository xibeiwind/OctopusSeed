# 变体：TypeScript

`-Stack typescript` 时被叠加。原则同 `.NET` 变体：**能用构建期错误表达的约束，就不要只写在文档里**。

## 落地内容

| 文件 | 作用 |
|---|---|
| `jobs/frontend.yml` | CI 前端线：`npm ci`（严格按 lock）/ typecheck / test / build |

> 变体**不替你把代码目录建出来**——前端工程结构差异过大，替你生成反而碍事。
> 请按下表把门禁落到**你的**配置文件里；`init.ps1` 只负责注入 CI 作业。

## 把约束编进构建（建议起步值）

1. **类型检查 = 门禁**（等价于 .NET 的 `WarningsAsErrors`）

   ```jsonc
   // tsconfig.json（节选）
   {
     "compilerOptions": {
       "strict": true,                       // 含 strictNullChecks / noImplicitAny 等
       "noUncheckedIndexedAccess": true,     // 索引访问返回 T | undefined，消灭"数组越界也当有值"
       "exactOptionalPropertyTypes": true,
       "noImplicitOverride": true,
       "noFallthroughCasesInSwitch": true,
       "noUnusedLocals": true,
       "noUnusedParameters": true
     }
   }
   ```

   `package.json` 里给出脚本（CI 与之同名，改一处两处同改）：

   ```jsonc
   {
     "scripts": {
       "typecheck": "tsc --noEmit",
       "test": "vitest run",
       "build": "vite build"
     }
   }
   ```

2. **Lint 零警告**：`eslint --max-warnings 0`——"warn 不算 fail"是缓慢失守的典型入口。
3. **测试**：单测框架不限（vitest / jest 皆可）；**每个工作包至少配一个用例**（`CONTRIBUTING.md` §6）。
4. **lock 一体化**：`npm ci` 而不是 `npm install`；workspaces 的每个 `package.json` 都必须与 lock 同步。

## 与流程规范的衔接

- **提交前缀、编号、回填**照旧（与语言无关，见 `CONTRIBUTING.md` §1~§5）；
- 前端线与主门禁线**并列、互不阻塞**：因此"前端改动不触发后端重作业"由 `changes` 作业的范围判定保证
  （判据在 `verify-clean-build.yml` 的 `isFrontend`，**按实际目录改**）；
- 前端目录若要作为 Long-lived 子工程，建议在 `docs/02-总体设计.md` 里写明边界与共享内核归属（防"撒盐"）。
