# {{PROJECT_NAME}}

> 本仓库内置一套**人机协作软件工程过程规范**（由 OctopusSeed 模板生成），规范入口见 [`CONTRIBUTING.md`](./CONTRIBUTING.md)，文档入口见 [`docs/README.md`](./docs/README.md)。

## 开工前必读（★）

1. **当前阶段执行计划**的 `§3 工作包全景` 与 `§4 当前进度与下一步`（见 `docs/` 下最新的 `NN-Px执行计划.md`）；
2. 该工作包对应的**能力专题** `docs/NN-Px-y-<主题>设计.md`；
3. `CONTRIBUTING.md` §9（推进机制）· §5（文档同步）· §6（质量门禁）。

> 该入口为**人与 AI 共用**；AI 侧由 `.codebuddy/rules/` 强制同一套路。

## 过程资源一览（已内置）

| 层 | 资源 | 作用 |
|---|---|---|
| 规范 | `CONTRIBUTING.md` | 编号 / 分支 / 提交 / PR / 回填 / 门禁 / `R-Plan-1~11` / 任务治理 / 看板 |
| 预防层 | `.codebuddy/rules/*` | 把规范内建为 AI 默认行为 |
| 强制层 | `.githooks/commit-msg` | 提交信息必须带 `[Px-y]` 前缀，否则本地拒绝 |
| 强制层 | `.github/workflows/verify-clean-build.yml` | 变更范围判定 + 构建测试 + 规范文档线 |
| 强制层 | `tools/governance-check.ps1` | 提交前缀 / 文档引用 / 编号登记三项校验 |
| 骨架 | `docs/README.md` · `docs/模板/*` | 文档地图 + 阶段计划 / 能力专题 / 收口评审模板 |
| 工具 | `tools/kanban*.ps1` · `tools/kanban.template.html` | 只读派生看板（可选，删则同步删 `CONTRIBUTING.md` §10） |

## 构建与测试

```sh
{{BUILD_CMD}}     # 要求 0 警告 0 错误
{{TEST_CMD}}      # 单测全绿（基线数字见 docs/项目时间线.md §1）
```

本仓技术栈：**{{STACK_NAME}}**；栈无关门禁见 `CONTRIBUTING.md` §6。

{{STACK_GATE}}

## 首次启用（一次性）

```sh
git config core.hooksPath .githooks
```

## 看板（可选）

```sh
powershell -ExecutionPolicy Bypass -File tools/build-kanban.ps1   # 生成静态快照 tools/kanban.html
powershell -ExecutionPolicy Bypass -File tools/serve-kanban.ps1   # 本地实时看板
```

> 看板是**只读派生视图**，不是第二真源；它按文档结构解析（「文档信号 = 接口」，见 `CONTRIBUTING.md` §10）。

## 本仓库的起点

- 文档基线：`docs/01-需求规格说明书.md`、`docs/02-总体设计.md`（**骨架，待填**）；
- 第一个阶段计划：由 `docs/模板/阶段执行计划模板.md` 复制为 `docs/NN-P0执行计划.md`，**先填 §3 与 §8 再开工**。
