# MANIFEST — 资产清单 · 占位符表 · 定制点清单

> **迁移前必读**。本文件回答三件事：① 复制出去要替换什么（§1）；② 每个文件属于哪一层、是"直取"还是"改写"（§2）；
> ③ 哪些是通用内核、哪些**必须按项目定制**（§3~§4）。
> 机器可读版本见 `manifest.json`（`init.ps1` 与 `template-check.ps1` 消费它；本文件与它必须一致）。

---

## 1. 占位符表

| 占位符 | 含义 | 示例 | 取值约束 | 出现在 |
|---|---|---|---|---|
| `{{PROJECT_NAME}}` | 项目 / 产品名 | `OctopusCtrlBridge` | 非空；出现在 README、AI 规则、看板标题、`.NET` 程序集属性 | 内核 + 变体 |
| `{{APP_KEY}}` | 小写短标识，用作浏览器 `localStorage` 键与临时文件前缀 | `ocb` | 小写字母数字，建议 3~8 位，**勿含下划线**（模板写作 `{{APP_KEY}}_kanban_theme`） | 内核（看板模板 / 校验脚本） |
| `{{STACK_NAME}}` | 技术栈**显示名**，写进文档与规则 | `.NET` / `TypeScript` / `Go` / `通用` | 由 `-Stack` 决定；**不要用在路径里**（`.NET` 不是合法目录名） | 内核 + 变体 |
| `{{STACK_ID}}` | 技术栈**目录名**，用于路径 | `dotnet` / `typescript` / `go` / `generic` | 由 `-Stack` 决定；路径里必须用它 | 内核 + 变体 |
| `{{BUILD_CMD}}` | 构建命令（门禁的"硬约束"载体） | `dotnet build` / `npm run build` / `go build ./...` | 必须**全绿即 0 警告 0 错误**或等价 | 内核文档 + 变体 |
| `{{TEST_CMD}}` | 测试命令 | `dotnet test` / `npm test` / `go test ./...` | 全绿 | 内核文档 + 变体 |
| `{{SMOKE_CMD}}` | 冒烟命令（**I1 主干可运行**）：构建 → 启动 → 打一次真实请求 | `<your smoke command>` | **留空即"无保障"**——`manifest.json` 的 `stacks.<栈>.smokeCmd` 为空时只渲染这条提示语；**不要接一条"空过"的命令**（§8.1 第 2 条纪律） | 内核文档 + 变体 |
| `{{BUILD_GATE_CMD}}` | 构建判据命令（**判据 1 的"零警告"载体**） | `dotnet build -warnaserror` | 留空则回退到 `{{BUILD_CMD}}`；仍为 `<...>` 提示时该判据打印 **UNGUARDED**（不是 PASS）。取自 `stacks.<栈>.gateBuildCmd` | 内核文档 + 变体 |
| `{{INTEGRATION_BRANCH}}` | 集成分支 | `develop` | 特性分支从此切出；CI 触发分支同步改 | 内核（CI + 规范正文） |
| `{{RELEASE_BRANCH}}` | 发布分支 | `main` | — | 内核（CI + 规范正文） |
| `{{CI_RUNNER}}` | CI 运行器标签（JSON 数组串） | `["windows-latest"]` | 若存在**仅在某 OS 通过**的测试，必须钉死标签 | 内核（CI） |
| `{{STACK_JOB}}` | CI 中「栈作业」的注入锚点 | — | 由变体的 `jobs/<stack>.yml` 替换；`generic` 时整体删除 | 内核（CI） |
| `{{STACK_GATE}}` | 产物 README 中「栈专属门禁」节的注入锚点 | — | 由变体的 `gate.md` 替换；`generic` 时整行删除 | 内核（README） |

> **替换纪律**：占位符形如 `{{大写字母与下划线}}`——刻意**不含 `$`**，因此在 GitHub Actions 里不会与 `${{ ... }}` 表达式冲突。
> 全局替换时必须只匹配 `\{\{[A-Z][A-Z0-9_]*\}\}`，**不要**用宽松的 `\{\{.*?\}\}`（会吃掉 Actions 表达式）。

---

## 2. 资产清单

`transform` 取值：**copy** = 机械拷贝 + 占位符替换（源与模板可机械对账）；**rewrite** = 为通用化而人工改写（源与模板**不**逐字对应，改源时需人工同步）。

### 2.1 内核 `template/`（栈无关，全部随 `-Stack generic` 落地）

| 层 | 文件 | transform | 作用 | 迁移时须检查 |
|---|---|---|---|---|
| 入口 | `README.md` | rewrite | 项目入口 + 过程资源一览 + 一次性启用步骤 | 构建/测试命令、目录名 |
| 规范 | `CONTRIBUTING.md` | rewrite | 编号 / 分支 / 提交 / PR / 回填 / 门禁 / `R-Plan-1~12` / 任务治理 / 结构重构通道 / 看板 / 模板 | §6 门禁命令、§10 文档信号表 |
| 预防 | `.codebuddy/rules/stage-plan-driven/RULE.mdc` | copy | 开工读计划、完工回填（AI 侧强制） | 文档命名形态（`NN-Px执行计划.md`） |
| 预防 | `.codebuddy/rules/coding-conventions/RULE.mdc` | copy | 编号体系与提交/分支/PR 形态 | 分支名、编号示例 |
| 预防 | `.codebuddy/rules/rtm-traceability/RULE.mdc` | copy | 需求 ↔ 工作包追溯与回填 | 登记处文件名 |
| 预防 | `.codebuddy/rules/quality-gate/RULE.mdc` | rewrite | 栈无关质量门禁（零新增警告、每包至少一测、门禁编进构建、判据入口） | 若用变体，追加变体规则 |
| 预防 | `.codebuddy/rules/option-based-input/RULE.mdc` | copy | 交互选项化（`R-Ask-1~5`）：决策一律选项化、互斥单选 / 可并多选、拍板必须落 §8 | — |
| 强制 | `.githooks/commit-msg` | copy | 提交前缀 `[Px-y]` 硬校验（本地） | 前缀形态若改（如 `[P-1]`）三处同改 |
| 强制 | `tools/governance-check.ps1` | copy | 提交前缀 / 文档引用 / 编号登记 三项校验（CI + 本地） | 编号正则、文档根目录 |
| 强制 | `.github/workflows/verify-clean-build.yml` | rewrite | 变更范围判定 + 规范文档线（栈作业由变体注入 `{{STACK_JOB}}`） | 触发分支、运行器变量名 |
| 骨架 | `docs/README.md` | rewrite | 文档地图、分层（L0~L4）、按任务路由、开工入口 | 能力专题索引、阶段索引 |
| 骨架 | `docs/01-需求规格说明书.md` | rewrite | 需求 ID / 范围 / 红线 / 阶段划分总纲（L1 基线骨架） | 需求 ID 形态、阶段划分表 |
| 骨架 | `docs/02-总体设计.md` | rewrite | 架构、工程落位、关键契约、数据配置（L1 基线骨架） | 分层与运行时、未定项标注纪律 |
| 骨架 | `docs/需求跟踪矩阵.md` | rewrite | RTM：需求 → 工作包 → 验收/证据 | 需求 ID 形态 |
| 骨架 | `docs/范围边界清单.md` | rewrite | 候选池 / 遗漏项**单一登记处**（`R-Plan-7`） | 类别与状态取值 |
| 骨架 | `docs/项目时间线.md` | rewrite | 机械事实**单一权威处**（`R-Plan-6`） | 表格列形态（看板判据依赖它） |
| 骨架 | `docs/模板/阶段执行计划模板.md` | copy | 阶段计划固定骨架（`R-Plan-1`，§0~§9） | — |
| 骨架 | `docs/模板/能力专题设计模板.md` | copy | L2 能力专题（含「契约归属」防撒盐节） | — |
| 骨架 | `docs/模板/阶段收口评审模板.md` | copy | 收口评审（`R-Plan-8` 清算 / 摘取 / 审视 + 必答两问：**删掉了什么** / **设计被修订过吗**） | — |
| 工具 | `tools/kanban-data.ps1` | copy | 文档 → 看板模型的**唯一**解析点；源文档一律按**形态**识别（计划 = §3 首行是包号），并读**全部**阶段计划而非最新一份 | §10 的「文档信号 = 接口」逐项对账；`requirements` 字段是需求覆盖判据的比对基准 |
| 工具 | `tools/kanban.template.html` | copy | 看板模板**唯一**来源（静态与实时同源） | 标题、`{{APP_KEY}}` |
| 工具 | `tools/build-kanban.ps1` | copy | 生成静态快照 `tools/kanban.html`（产物不入库） | `.gitignore` |
| 工具 | `tools/serve-kanban.ps1` | copy | 本地实时看板 + 只读 `/docs/<name>` | 端口 |
| 工具 | `tools/kanban-check.ps1` | copy | 看板配色 / 接线 / 几何 / 运行期门禁 + **三项跨册覆盖**（登记条目 / 需求条目 / 页签↔面板；都用行正则独立读源文档）（**对产物运行**） | 断言中的文档形态（登记表与需求表的列数与连续性） |
| 工具 | `tools/verify.ps1` | rewrite | **本地判据单命令入口**（§6.1 的六条）：全跑再汇总、`-Fast`、`UNGUARDED` 不等于通过；命令来自占位符，故**改判据即改此文件与 §6.1** | `{{BUILD_GATE_CMD}}` / `{{TEST_CMD}}` / `{{SMOKE_CMD}}` / `{{INTEGRATION_BRANCH}}`；判据条数须与 `CONTRIBUTING.md` §6.1 一致 |
| 工具 | `tools/claim.ps1` | rewrite | **编号原子占用**：开工前把 `Px-y` 写进阶段计划 §3（已被占用即拒绝），把"先登记后使用"提前到开工期 | 阶段计划文件名形态（`^NN-Px`）与 §3 表结构 |
| 工具 | `tools/metrics.ps1` | rewrite | **可复算过程指标** + 时间线指标自动块（`-Write` 刷新 / `-Check` 断言未陈旧） | 指标口径、自动块锚点 `<!-- METRICS:AUTO -->` |

### 2.2 变体 `variants/<stack>/`

| 变体 | 文件 | transform | 作用 |
|---|---|---|---|
| dotnet | `Directory.Build.props` | copy | 统一 TFM / `Nullable=disable` / `WarningsAsErrors=CS8632`（把质量门禁编进构建） |
| dotnet | `Directory.Build.targets` | copy | 构建期断言：禁止在 csproj 私自覆盖 `Nullable` |
| dotnet | `global.json` | copy | 钉 SDK 版本（`rollForward` 策略） |
| dotnet | `.codebuddy/rules/nullable-gate/RULE.mdc` | copy | 可空红线与零警告（AI 预防层） |
| dotnet | `.codebuddy/rules/modern-csharp-syntax/RULE.mdc` | copy | 最新 C# 语法：以项目实际设置定版本上限（SDK 8.0.400 + `LangVersion=latest` → C# 12）、C# 13+ 禁用清单、可空与反射映射例外 |
| dotnet | `tools/assets.ps1` | rewrite | **存量台账**（只读，非判据）：零消费者的工程必须有台账授权行，条件已触发须标 `EXPIRED` 并持续报 finding |
| dotnet | `jobs/dotnet.yml` | rewrite | CI 栈作业片段（还原 / 构建 / 测试 + 挂起看门狗） |
| dotnet | `gate.md` | rewrite | **注入产物 README** 的「栈专属门禁」节（载体表 + 纪律 + 取舍理由） |
| typescript | `gate.md` | rewrite | 同上（前端线） |
| go | `gate.md` | rewrite | 同上 |
| typescript | `jobs/frontend.yml` + `README.md` | rewrite | 前端线（`npm ci` 严格按 lock / typecheck / test / build）与 strict 落地指引 |
| go | `jobs/go.yml` + `README.md` | rewrite | `go vet` / `staticcheck` / `go test ./...` 与零警告落地指引 |
| 通用 | `generic`（无目录） | — | 只有内核：流程门禁成立，无编译期门禁 |

---

## 3. 通用内核 vs 需定制项

### 3.1 技术栈无关 —— **可直接沿用**

- 单一编号体系（需求 `§xx` / `R-xx` ↔ 工作包 `Px-y` ↔ 代码 `[Px-y]`）与双向追溯；
- 阶段计划驱动 `R-Plan-1~12` 与 7 步工作包推进闭环；
- **设计分级与减法检查点**：契约性设计一次做对、结构性设计够用即止（`R-Plan-12`）；结构重构通道不占包位、不参与价值比价（§9.5.2）；收口评审必答"删掉了什么 / 设计被修订过吗"（`R-Plan-8`）；
- 任务治理「两清单 + 三闸门」与艾森豪威尔矩阵的**客观判据版**（`CONTRIBUTING.md` §9.5）；
- 文档分层 L0~L4 与「契约归属」防撒盐原则、单一权威处（`R-Plan-6` / `R-Plan-7`）；
- 提交前缀钩子、文档引用校验、编号登记校验、看板一致性门禁（含**跨册覆盖三项**）；
- **本地判据单命令入口**（`tools/verify.ps1` + `CONTRIBUTING.md` §6.1 的六条）与 **`UNGUARDED` 语义**（载体缺失不是通过）；
- **人机协作交互规范**（`R-Ask-1~5`：决策选项化、互斥单选 / 可并多选、拍板必须落 §8）；
- 候选池不设上限 / 排期表必须封顶的防膨胀机制。

### 3.2 需按项目定制 —— **不能照抄**

| 项 | 模板中的形态 | 你必须做的 |
|---|---|---|
| 集成分支 / 发布分支名 | `{{INTEGRATION_BRANCH}}` = `develop` | 按团队约定改；同时改 CI 的 `on.branches` |
| CI 运行器 | `{{CI_RUNNER}}` = `["windows-latest"]` | 自托管/其它 OS 按需改；**存在平台专属测试时必须钉死标签** |
| 构建 / 测试命令 | `{{BUILD_CMD}}` / `{{TEST_CMD}}` | 换成该栈命令；**零警告**要求不能放宽 |
| 冒烟命令（**I1 主干可运行**） | `{{SMOKE_CMD}}`（取自 `stacks.<栈>.smokeCmd`，默认空） | 填入本栈的"构建 → 启动 → 打一次真实请求"命令，并取消 CI 里那三行注释；**填不出就承认"无保障"**，不要留一条空过的命令 |
| 门禁严格度 | `-Strict registry`（仅编号登记严格） | 新仓无历史债，**建议一开始就 `-Strict all`**（比"先放水再收紧"干净） |
| 需求编号形态 | `§<章节号>` / `R-<数字>` / `R-N<数字>` | 若团队另有形态，四处同改（规范正文 / RTM / 看板判据 / 钩子正则） |
| 应用短标识 | `{{APP_KEY}}` | 取项目缩写；改了要同步看板模板与校验脚本 |
| 文档编号准入 | 带编号仅 `01`/`02`/阶段计划/专项设计/收口评审；四份常驻单例**刻意不编号** | 保持这条纪律，否则编号空间会被"补号"漂移 |
| 前端线 | 变体 `typescript/jobs/frontend.yml` | 无前端则不加该变体（不要在 CI 里留注释掉的死作业） |
| 看板 | 内核自带（可按需删） | 若不要看板，删 `tools/kanban*` 与 `CONTRIBUTING.md` §10，并同步删 CI 中的看板门禁步骤 |
| 度量与并行工具 | `tools/metrics.ps1`（可复算指标）、`tools/claim.ps1`（编号原子占用） | 若只要最小集可整体删除；删掉后**同步删 CI 里对应的步骤**与 `CONTRIBUTING.md` §9.6 的引用 |

### 3.3 最小可用子集（只想要一部分收益时，该取哪一部分）

不必全盘引入。**三档，每一档都自洽可运行**：

| 档位 | 取什么 | 得到什么 | 放弃什么 |
|---|---|---|---|
| **A 最小**（半天） | `CONTRIBUTING.md` §1~§3（编号 / 分支 / 提交）+ `.githooks/commit-msg` | 需求 ↔ 工作包 ↔ 代码的编号对齐；提交前缀**硬校验** | 无阶段计划驱动、无文档门禁、无看板 |
| **B 标准**（1~2 天） | A + `docs/` 骨架（四份常驻单例 + 三份模板）+ `tools/governance-check.ps1` + CI 的 `governance` 作业 + `.codebuddy/rules/*` | 阶段计划驱动（`R-Plan-1~12`）、文档引用与编号登记门禁、AI 侧预防层 | 看板、栈专属门禁、度量 |
| **C 完整** | B + 看板（`tools/kanban*`）+ 栈门禁（`variants/<stack>`）+ `tools/claim.ps1` / `metrics.ps1` | 全量：多维视图、并行安全、可复算度量、门禁自证 | 复杂度代价（文档重、依赖工具链） |

**选档口诀**：**A 用于"能把编号对齐就行"**；**B 用于"要有'下一步'的唯一出处"**；**C 用于"要可审计、可度量"**。

> 无论取哪一档，都**保留** `template/CONTRIBUTING.md` §8.1 的要求：写不出机械判据的约束，明确标为**软约束或无保障**，不要假装有门禁。

---

## 4. 迁移后必做的校准（一次性 checklist）

1. **占位符**：确认仓内已无 `{{` 残留（`template-check.ps1` 会扫）；
2. **看板文档信号**：逐项对照 `CONTRIBUTING.md` §10 的接口表——阶段计划 §3/§8 表列、RTM 行、时间线 §一/§二首列形态、范围边界清单三张表的列数；
3. **CI**：`on.branches`、`CI_RUNNER_LABELS`、栈作业是否已注入、`governance` 的 `-Strict` 取值；
4. **钩子**：`git config core.hooksPath .githooks` 已启用（否则本地不拦）；
5. **门禁自证**：跑一次 `{{BUILD_CMD}}` / `{{TEST_CMD}}` / `tools/governance-check.ps1`，并**刻意制造一次违规**确认会被拦下
   （门禁没被"撞"过就不算生效）；
6. **首份文档**：`01` / `02` 基线 + `03-P0执行计划.md`（先填 §3 与 §8，决议后再开工）。

---

## 5. 模板自身的维护记录

| 文件 | 来源 | 抽取日期 | 最后对账 |
|---|---|---|---|
| `template/tools/*`（5 个看板工具 + governance-check） | OctopusCtrlBridge `tools/` | 2026-09-15 | 2026-09-15 |
| `template/.codebuddy/rules/{stage-plan-driven,coding-conventions,rtm-traceability}` | OctopusCtrlBridge `.codebuddy/rules/` | 2026-09-15 | 2026-09-15 |
| `template/.githooks/commit-msg` | OctopusCtrlBridge `.githooks/` | 2026-09-15 | 2026-09-15 |
| `template/docs/模板/*` | OctopusCtrlBridge `docs/模板/` | 2026-09-15 | 2026-09-20 |
| `variants/dotnet/{Directory.Build.props,.targets,global.json}` | OctopusCtrlBridge 仓库根 | 2026-09-15 | 2026-09-15 |
| `variants/dotnet/.codebuddy/rules/nullable-gate` | OctopusCtrlBridge `.codebuddy/rules/` | 2026-09-15 | 2026-09-15 |
| `template/CONTRIBUTING.md`、`template/README.md`、`template/docs/{README,需求跟踪矩阵,范围边界清单,项目时间线}.md`、`template/.github/workflows/verify-clean-build.yml` | 由源项目对应文件**通用化改写** | 2026-09-15 | 2026-09-20 |
| `template/docs/{01-需求规格说明书,02-总体设计}.md`、`template/.codebuddy/rules/quality-gate/` | 源项目有对应实体但**内容是项目专属**：抽取为**骨架**与**栈无关规则** | 2026-09-15 | 2026-09-15 |
| `variants/*/gate.md` | **本次新设**：变体说明必须**随产物走**（变体目录本身不拷进目标），故拆出可注入产物 README 的门禁节 | 2026-09-15 | 2026-09-15 |
| `OctopusSeed/{.gitignore,.codebuddy/rules/seed-maintenance/}` | 模板仓**自身**的忽略规则与维护纪律（"吃自己的狗粮"） | 2026-09-15 | 2026-09-15 |
| `template/tools/{claim,metrics}.ps1`、`governance-check.ps1` 的 `claim`/`provenance`/`hotdocs` 三项、`template/docs/项目时间线.md` 的指标自动块 | **本次新设**（"保障分层"设计的产物）：编号原子占用、可复算度量、未定项归属与热点文档可见性 | 2026-09-15 | 2026-09-15 |
| `template/CONTRIBUTING.md`（§1 / §6 / §8.2 / §9.1 / §9.2 / §9.5.2 / §10）、`template/docs/模板/*`、`variants/*/jobs/*.yml`、`manifest.json` 与 `init.ps1` 的 `SMOKE_CMD`、`.codebuddy/rules/stage-plan-driven/` | **本次新设**（"设计可变更性"评审的产物）：主干可运行不变量 **I1**、`R-Plan-12` 设计两级、结构重构通道（§9.5.2）、收口必答两问（减法检查点 / 设计是否被修订）、失效信号（§8.2，**软层，刻意不可机械复算**） | 2026-09-20 | 2026-09-20 |
| `template/tools/verify.ps1`、`template/.codebuddy/rules/option-based-input/`、`template/CONTRIBUTING.md` 的 §6（metrics 非确定性例外 / `docrefs` 前瞻引用 / 载体失效降级）/ §6.1 / §8.1 注 / §9.2 / §9.6 注 / §10 工具表与禁令 ⑬⑭ / §11 / §12、`template/README.md`、`template/docs/README.md`、`template/.codebuddy/rules/quality-gate/` | **经验回收批次**（源项目逐文件对账后按「内核 / 变体 / 项目专属」三分类裁决） | 2026-09-22 | 2026-09-22 |
| `template/tools/{kanban-data,kanban.template.html,kanban-check}.ps1` | **经验回收批次**：把源项目的**跨册覆盖三项**（登记条目 I16 / 需求条目 I18 / 页签↔面板 1:1）与**需求维度**（模型 `requirements` 字段 + 页签 + 面板 + 反向链接）合并进本模板既有看板——**逐块合并，未覆盖模板原有的几何与配色断言** | 2026-09-22 | 2026-09-22 |
| `variants/dotnet/.codebuddy/rules/modern-csharp-syntax/`、`variants/dotnet/tools/assets.ps1` | **经验回收批次**（通用化改写：去掉项目名 / 案例与硬编码的解决方案名，保留撞测纪律与 `EXPIRED` 约定） | 2026-09-22 | 2026-09-22 |
| `manifest.json` / `init.ps1` / `template-check.ps1` | 随同批次更新：新占位符 `{{BUILD_GATE_CMD}}`、四个新登记文件、`tools/*.ps1` 解析改为**枚举**并断言判据入口存在 | 2026-09-22 | 2026-09-22 |

> **改模板的流程**：改内核 → 跑 `template-check.ps1 -Smoke` → 更新本表「最后对账」列 → 提交。
> **源项目继续演进不影响本模板**：本模板是**快照 + 抽取**，不是源的镜像；两者解耦后靠上表记录血缘，而不是靠同步脚本。

### 5.1 源项目经验的**回收窗口**（解耦 ≠ 不回收）

解耦没有问题，问题在于**没有回收时点**：源项目会持续积累用真实缺陷换来的教训，而"什么时候该回写"若没有出处，回写就永远不发生——与本规范"任何下一步若没写进文档就等于不存在"是同一条道理。

- **时点**：**源项目阶段收口评审时**（与该阶段收口同批执行，承 `R-Plan-8`）。
- **动作**：把本阶段产生的**过程类**教训（门禁判据、文档形态约定、工具缺陷、交互纪律）按三分类裁决——**内核**（栈无关）→ 回写 `template/**`；**变体**（该栈专属）→ 回写 `variants/<stack>/**`；**项目专属**（事件、具体命令、案例、编号）→ **不入**。
- **记账**：回写后更新本表「最后对账」列；若结论影响评估，同批更新 `PROCESS-COMPARISON.md` 附录 C（**只增不改旧结论**）。
- **禁止整文件覆盖**：两侧会**同时**分叉——源项目可能在覆盖判据上领先，模板可能在几何 / 配色断言上更厚，覆盖等于删掉另一侧。一律**逐块合并**（承 `template/CONTRIBUTING.md` §9.6 第 3 条"热点文件禁止整文件重写"）。
- **保障层级**：本条是**软保障**（`§8.1`）——没有机械判据；本表「最后对账」列只让它**可见**，`template-check.ps1` 不校验它的新鲜度。**不要按硬门禁叙述。**
