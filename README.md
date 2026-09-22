# OctopusSeed — 人机协作软件工程过程模板

> 一套可一键落地的**人机协作软件工程过程规范**：用单一编号体系把「需求 ↔ 工作包 ↔ 代码」串成可双向追溯的链条，
> 用**阶段执行计划**保证"下一步永远有出处"，并把约束**编进构建与钩子**（而不是只写在文档里）。
>
> 种子取自 **OctopusCtrlBridge**（其规范本身由 **OctopusSynapse** 移植并通用化）。本仓只保留**可迁移内核**，
> 已剥离全部项目专属内容（需求条目、阶段计划、代码、历史事件编号、看板配色演进史）。

## 一、它解决什么

| 常见病 | 本模板的机制 |
|---|---|
| 「接下来做什么」靠记忆或口头交接 | **阶段执行计划 §3/§4** 是唯一开工入口（`R-Plan-3`）；回填是硬流程 |
| 需求 / 任务 / 提交对不上号 | 单一编号体系（`§xx` / `R-xx` / `Px-y`），提交与分支强制前缀 |
| 文档写了没人验、引用越陈越旧 | CI **规范文档线**校验提交前缀 / 文档引用 / 编号登记 |
| 约束写在文档里被绕过 | 能用**构建期错误**表达的约束就编进构建；本地钩子 + CI 是第二、第三道 |
| 需求无限膨胀、计划永远超载 | **两清单 + 三闸门**：候选池不设上限，排期表必须封顶（`R-Plan-9`） |

> **正在决定是否采用？** 先读 [`PROCESS-COMPARISON.md`](./PROCESS-COMPARISON.md)：它逐维度对比了本过程与主流框架
> （谁更硬、谁更轻、谁有度量），并诚实列出**全部缺口与补强成本**（含明确"不做"的项及其理由）；再看 [`MANIFEST.md`](./MANIFEST.md) §3
> （通用内核 vs 需定制项）判断要付出多少迁移成本。

## 二、目录结构

```
OctopusSeed/
├─ README.md                ← 本文件：模板使用说明
├─ MANIFEST.md              ← 资产清单 / 占位符表 / 定制点清单（★ 迁移前必读）
├─ PROCESS-COMPARISON.md    ← 过程横向评估：与瀑布 / RUP / Scrum / Kanban / XP / Shape Up / SAFe / DevOps / CMMI
│                             / spec-driven 的逐维度对比，含强度快照、缺口与补强建议、适用性判定
├─ manifest.json            ← 机器可读清单（init.ps1 与 template-check.ps1 消费）
├─ init.ps1                 ← 生成器：按参数渲染到目标目录并输出启用清单
├─ template-check.ps1       ← 模板自检：占位符 / 清单双向一致性 / 文档引用 / 冒烟生成
├─ .gitignore               ← 本仓自身的忽略规则（它是模板仓，不含构建产物）
├─ .codebuddy/rules/        ← 本仓自身的 AI 规则：改模板的纪律（"吃自己的狗粮"）
├─ template/                ← 栈无关内核（占位符化，可直接拷进任何新仓）
│  ├─ CONTRIBUTING.md       ← 规范正文（§1~§11）
│  ├─ README.md .gitignore  ← 仓库入口与忽略规则
│  ├─ .githooks/commit-msg  ← 提交前缀硬校验（本地）
│  ├─ .codebuddy/rules/     ← AI 预防层（阶段计划驱动 / 编号 / 追溯 / 质量门禁）
│  ├─ .github/workflows/    ← CI：变更范围判定 + 规范文档线（栈作业由变体注入）
│  ├─ docs/                 ← 文档骨架：README 地图 + 四份常驻单例 + 三份文档模板
│  └─ tools/                ← verify（判据单命令入口）+ governance-check（规范门禁）+ 看板工具（只读派生视图）
└─ variants/                ← 技术栈专属门禁（可插拔，按需叠加）
   ├─ dotnet/               ← Directory.Build.props/.targets + global.json + 可空红线 + 最新 C# 语法规则 + 存量台账 assets.ps1
   ├─ typescript/           ← strict 门禁落地指引（tsconfig / eslint / vitest）
   └─ go/                   ← vet / staticcheck / go test 门禁落地指引
```

## 三、快速开始

```powershell
# 1) 生成（-Stack 决定叠加哪个变体；generic = 只有栈无关内核）
powershell -ExecutionPolicy Bypass -File init.ps1 `
  -Target C:\work\MyApp -ProjectName MyApp -Stack dotnet

# 2) 想看会写什么、不落盘
powershell -ExecutionPolicy Bypass -File init.ps1 -Target C:\work\MyApp -ProjectName MyApp -Stack dotnet -DryRun

# 3) 模板自身自检（改了模板后必跑）
powershell -ExecutionPolicy Bypass -File template-check.ps1 -Smoke
```

生成后的**人工动作**（生成器会再次打印，共 6 步）：

1. `git init` + 切集成分支：`git init -b main && git switch -c develop`（分支名以 `-IntegrationBranch` 为准）；
2. 启用钩子：`git config core.hooksPath .githooks`；
3. 填**基线文档**：`docs/01-需求规格说明书.md`、`docs/02-总体设计.md`（生成器只建骨架）；
4. 由 `docs/模板/阶段执行计划模板.md` 建 `docs/03-P0执行计划.md`，**先填 §3 与 §8**，决议后再开工；
5. 本地自检：`powershell -ExecutionPolicy Bypass -File tools/governance-check.ps1`；
6. 接 CI：推送后设 `CI_RUNNER_LABELS` 仓库变量（默认 `["windows-latest"]`），确认各作业行为符合预期。

## 四、三种使用方式

| 方式 | 适用 | 做法 |
|---|---|---|
| **一键生成**（推荐） | 新项目从零起步 | `init.ps1`，参数化替换 + 变体叠加 |
| **整目录拷贝** | 已有仓库、不想跑脚本；或想把本模板抽成独立仓 | 直接拷 `template/**`（外加需要的 `variants/<stack>/**`），按 `MANIFEST.md` §1 的占位符表全局替换 |
| **只读清单** | 只想借鉴机制、不想引入整套流程 | 读 `MANIFEST.md` §3「通用内核 vs 需定制项」与 `template/CONTRIBUTING.md` |

> **不要引入整套流程的场景**：单人、无 AI 协作、无追溯诉求的短周期脚本仓。本规范的重量换的是**可追溯与可交接**，
> 前提是机械劳动（读计划、回填、写文档、对齐前缀）由 AI 承担、人只做决策与合并批准（见 `template/CONTRIBUTING.md` §11）。

## 五、栈无关内核 vs 技术栈变体

- **内核**（`template/`）只依赖一件事：**能把约束编进"某个执行点"**。它自带的是**流程门禁**（提交前缀 / 文档引用 / 编号登记 / 看板一致性）。
- **变体**（`variants/`）提供**编译/测试期门禁**与该栈的 CI 作业片段。`init.ps1 -Stack <name>` 会：
  1. 叠加变体文件（含把变体的 CI 作业注入 `verify-clean-build.yml` 的锚点）；
  2. 替换 `{{BUILD_CMD}}` / `{{TEST_CMD}}` / `{{STACK_NAME}}` 等占位符。
- `-Stack generic` 时，CI 只跑「变更范围判定」与「规范文档线」——**流程门禁仍然成立**，只是没有编译期门禁。

## 六、维护本模板

模板一旦被复制出去，就与源项目**解耦**（源项目会继续演进）。因此：

1. 改**内核**文件后，跑 `template-check.ps1 -Smoke`（占位符、清单一致性、文档引用、生成冒烟）；
2. `MANIFEST.md` §5 记录各文件的来源与最后对账日期，避免"以为同步过"；
3. 看板工具与文档形态**强耦合**（`template/CONTRIBUTING.md` §10 的「文档信号 = 接口」）：改动文档结构时，
   必须同步改判据（`kanban-data.ps1` 的解析与 `kanban-check.ps1` 的断言），否则看板会静默少块；
4. **源项目经验要回收**：解耦 ≠ 不回收——**回写窗口 = 源项目阶段收口评审时**，把本阶段的过程类教训按
   「内核 / 变体 / 项目专属」三分类裁决，前两类回写并更新 §5「最后对账」列与 §5.1；
   **回写一律逐块合并，禁止整文件覆盖**——两侧会**同时**分叉（源项目可能在覆盖判据上领先，
   模板可能在几何 / 配色断言上更厚），覆盖等于删掉另一侧。

## 七、已知边界

- **规范较重是刻意的**：它的前提是人机协作；非 AI 协作团队建议只取 §1~§6，砍掉看板与任务治理。
- **看板工具**（`template/tools/`，约 160 KB）功能强但不轻：它按**文档结构**解析，迁移后需按 §10 的接口表逐项校准。
- **PowerShell 脚本**（`tools/*.ps1`）**刻意全 ASCII**：Windows PowerShell 5.1 会把无 BOM 的 UTF-8 当 ANSI 读，
  脚本内出现非 ASCII 字节可能乱码甚至解析失败。HTML/文档是 UTF-8，中文安全（此纪律**不**适用于它们）。
- **平台差异**：CI 示例以 GitHub Actions 表达，`CI_RUNNER_LABELS` 由仓库变量驱动；换平台需重写 workflow，但门禁语义不变。
