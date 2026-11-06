# init.ps1 使用说明（生成新项目）

`init.ps1` 是 OctopusSeed 的**一次性生成器**：把 `template/**`（栈无关内核）与所选 `variants/<stack>/**`（技术栈变体）
渲染到目标目录，替换占位符、注入栈专属 CI 作业与门禁说明，最后打印人工收尾清单。

它是**只写目标目录**的：不会修改本仓，不需要网络，也不依赖目标目录已存在。

---

## 一、前置条件

- Windows PowerShell 5.1 或 PowerShell 7+（脚本刻意保持 ASCII-only，两者都能跑）；
- 在本仓根目录执行（脚本以**自身所在目录**为模板根，所以 `cd` 到别处也能用 `-File <路径>\init.ps1`）；
- 目标路径的父目录可写。

## 二、最小命令

```powershell
powershell -ExecutionPolicy Bypass -File init.ps1 -Target C:\work\MyApp -ProjectName MyApp -Stack dotnet
```

只有两个参数是必填的：`-Target`（生成到哪）与 `-ProjectName`（项目名）。其余都有默认值。

> 建议先加 `-DryRun` 跑一遍：只打印将写入的文件清单，不落盘。

## 三、参数表

| 参数 | 必填 | 默认值 | 作用 |
|---|---|---|---|
| `-Target` | **是** | — | 输出目录。不存在则创建；存在且非空时必须加 `-Force` |
| `-ProjectName` | **是** | — | 项目 / 产品名，替换 `{{PROJECT_NAME}}` |
| `-AppKey` | 否 | 由 `-ProjectName` 推导 | 小写短标识，替换 `{{APP_KEY}}`（localStorage 键、临时文件前缀） |
| `-Stack` | 否 | `generic` | 技术栈：`generic` / `dotnet` / `typescript` / `go`（其它值直接拒绝） |
| `-IntegrationBranch` | 否 | `develop` | 集成分支；特性分支从此切出，CI 也监听它 |
| `-ReleaseBranch` | 否 | `main` | 发布分支 |
| `-CiRunner` | 否 | `["windows-latest"]` | CI 运行器标签，**JSON 数组字符串** |
| `-BuildCmd` | 否 | 按 `-Stack` 取 | 构建命令，替换 `{{BUILD_CMD}}` |
| `-TestCmd` | 否 | 按 `-Stack` 取 | 测试命令，替换 `{{TEST_CMD}}` |
| `-BuildGateCmd` | 否 | 按 `-Stack` 取 | 「零警告」判据命令，替换 `{{BUILD_GATE_CMD}}`；为空时回退到 `-BuildCmd` |
| `-Force` | 否 | 关 | 允许向非空目录写入，**覆盖同名文件**（不删除目标里的其它文件） |
| `-DryRun` | 否 | 关 | 只打印计划，不写任何文件 |

### `-AppKey` 的推导规则

不传时：按非字母数字切分 `-ProjectName` → 各段拼接 → 若段数大于 1 且拼接结果超过 8 个字符，则改取各段首字母 → 全部转小写。

例：`MyApp` → `myapp`；`Octopus Ctrl Bridge` → `ocb`。

### `-CiRunner` 的写法

它是 JSON 数组字符串，**必须带外层引号**，推荐用单引号避免转义：

```powershell
-CiRunner '["ubuntu-latest"]'
-CiRunner '["self-hosted","windows","x64"]'
```

在 cmd.exe 里同样写单引号即可（cmd 不解释单引号，会原样交给 PowerShell）。

## 四、`-Stack` 各栈的默认值

| `-Stack` | 显示名 | 构建 | 测试 | 零警告判据 | 注入的 CI 作业 |
|---|---|---|---|---|---|
| `generic` | `generic` | `<your build command>`（提示语） | `<your test command>`（提示语） | 回退构建命令；仍是提示语 → `UNGUARDED` | 无（只保留流程门禁） |
| `dotnet` | `.NET` | `dotnet build` | `dotnet test` | `dotnet build -warnaserror` | `variants/dotnet/jobs/dotnet.yml` |
| `typescript` | `TypeScript` | `npm run build` | `npm test` | 回退 `npm run build` | `variants/typescript/jobs/frontend.yml` |
| `go` | `Go` | `go build ./...` | `go test ./...` | 回退 `go build ./...` | `variants/go/jobs/go.yml` |

变体还会额外落地其目录下的门禁资产（如 `dotnet` 的 `Directory.Build.props/.targets`、`global.json`、可空/C# 语法规则、`tools/assets.ps1`）。

### 冒烟命令（I1，当前无命令行参数）

`{{SMOKE_CMD}}` 取自 `manifest.json` 的 `stacks.<栈>.smokeCmd`，四个栈默认都为空 → 产物中渲染为
`<your smoke command>`，`tools/verify.ps1` 会把 I1 判据标为 **UNGUARDED（不等于通过）**。

要接真实冒烟，二选一：

1. 生成前改 `manifest.json` 的 `stacks.<栈>.smokeCmd`（会同时影响后续所有生成，属模板仓改动）；
2. 生成后直接改产物 `tools/verify.ps1` 里的冒烟命令（只影响该项目）。

**不要填一条必然通过的空命令**——那只是把「无保障」伪装成「有门禁」。

## 五、常用示例

```powershell
# 1) 先看会写什么（不落盘）
powershell -ExecutionPolicy Bypass -File init.ps1 `
  -Target C:\work\MyApp -ProjectName MyApp -Stack dotnet -DryRun

# 2) 正式生成 .NET 项目
powershell -ExecutionPolicy Bypass -File init.ps1 `
  -Target C:\work\MyApp -ProjectName MyApp -Stack dotnet

# 3) Go 项目，跑在 Ubuntu runner 上，分支名不同
powershell -ExecutionPolicy Bypass -File init.ps1 `
  -Target C:\work\api -ProjectName MyApi -Stack go `
  -IntegrationBranch trunk -ReleaseBranch stable -CiRunner '["ubuntu-latest"]'

# 4) 只有流程门禁、不带任何栈资产
powershell -ExecutionPolicy Bypass -File init.ps1 `
  -Target C:\work\ProcessOnly -ProjectName ProcessOnly -Stack generic `
  -BuildCmd "echo no-build" -TestCmd "echo no-test"

# 5) 覆盖已有目录中的同名文件
powershell -ExecutionPolicy Bypass -File init.ps1 `
  -Target C:\work\MyApp -ProjectName MyApp -Stack dotnet -Force
```

## 六、生成器到底做了什么

1. 递归拷贝 `template/**`；
2. 若 `-Stack` 不是 `generic`，再叠加 `variants/<stack>/**`，但**跳过**：
   - `jobs/`（只作为 CI 片段注入，不落地）；
   - `README.md`、`gate.md`（`gate.md` 的内容改为注入产物 `README.md` 的 `{{STACK_GATE}}` 锚点）；
3. 替换占位符（完整清单见 `MANIFEST.md` §1）：
   `{{PROJECT_NAME}}`、`{{APP_KEY}}`、`{{STACK_NAME}}`、`{{STACK_ID}}`、`{{BUILD_CMD}}`、`{{TEST_CMD}}`、
   `{{BUILD_GATE_CMD}}`、`{{SMOKE_CMD}}`、`{{INTEGRATION_BRANCH}}`、`{{RELEASE_BRANCH}}`、`{{CI_RUNNER}}`；
4. 在 `.github/workflows/verify-clean-build.yml` 的 `{{STACK_JOB}}` 锚点注入栈作业；`generic` 时整行删除；
5. 在产物 `README.md` 的 `{{STACK_GATE}}` 锚点注入栈门禁说明；`generic` 时整行删除；
6. 按扩展名决定编码：`.ps1` 写 UTF-8 **带 BOM**（PS 5.1 需要），其余文本写 UTF-8 **无 BOM**，非文本原样拷贝；
7. 打印参数摘要、写入文件数 / 清单，以及 6 步人工收尾。

`-DryRun` 只执行第 1~4 步的**计划部分**：打印清单，不创建目录、不写文件。

## 七、生成后的人工收尾（6 步）

生成器会再打印一遍；顺序不要颠倒：

```powershell
cd C:\work\MyApp

# 1) 建仓并切到集成分支（名字以 -IntegrationBranch 为准）
git init -b main
git switch -c develop

# 2) 启用提交前缀硬校验（不启用 = 本地不拦）
git config core.hooksPath .githooks

# 3) 填基线文档：docs/01-需求规格说明书.md、docs/02-总体设计.md（生成器只建骨架）

# 4) 由 docs/模板/阶段执行计划模板.md 建 docs/03-P0执行计划.md，先填 §3 与 §8，再开工

# 5) 本地自检
powershell -ExecutionPolicy Bypass -File tools/governance-check.ps1

# 6) 推送后设置仓库变量，确认 CI 各作业行为
#    GitHub → Settings → Variables → CI_RUNNER_LABELS = ["windows-latest"]
```

然后**刻意制造一次违规**（例如提交不带 `[Px-y]` 前缀），确认钩子确实拦下——没被撞过的门禁不算生效。

## 八、常见问题

| 现象 | 原因 / 处理 |
|---|---|
| `target '...' is not empty. Pass -Force ...` | 目标目录非空。换空目录，或加 `-Force`（只覆盖同名文件，不清理旧文件） |
| `Cannot validate argument on parameter 'Stack'` | `-Stack` 只能是 `generic` / `dotnet` / `typescript` / `go` |
| `stack job not found: ...` | 变体目录缺失或被移动；确认 `variants/<stack>/jobs/*.yml` 存在 |
| `core root not found: ...` | 没有从完整模板仓运行；`init.ps1` 必须与 `template/`、`manifest.json` 同处一仓 |
| 产物里仍有 `{{XXX}}` | 不该发生，说明模板或清单有问题；回模板仓跑 `template-check.ps1 -Smoke` |
| 执行脚本被策略拦截 | 保留 `-ExecutionPolicy Bypass` |
| 路径含空格 | 给 `-Target` 加引号，例如 `-Target "C:\work\My App"` |
| PowerShell 5.1 中文乱码 | 脚本本身是 ASCII-only；若看到乱码，通常是**你自己改过产物脚本**并写入了中文，去掉中文字面量而非加 BOM |

## 九、改模板的人看这里

`init.ps1` 的输入只有 `manifest.json`：新增占位符或随模板分发的文件，必须同步 `manifest.json` 与 `MANIFEST.md`，
然后跑：

```powershell
powershell -ExecutionPolicy Bypass -File template-check.ps1 -Smoke
```

检查项：必需文件双向一致、未知占位符 / 禁词、占位符文档漂移、文档相对引用、四栈生成冒烟、随包脚本 ASCII-only。
