## 栈专属门禁（.NET）

本仓的栈专属约束**编在构建里**，不是写在文档里（`CONTRIBUTING.md` §8）——软约束会被绕过，硬约束不会。

| 载体 | 约束 |
|---|---|
| `Directory.Build.props` | 统一 TFM / `ImplicitUsings` / `Nullable=disable` / `WarningsAsErrors=CS8632`（引用类型可空注解 `T?` = 编译错误） |
| `Directory.Build.targets` | **构建期断言**：任何 csproj 私自把 `Nullable` 覆盖为非 `disable` 即构建失败 |
| `global.json` | 钉 SDK 版本与 `rollForward` 策略 |
| `.codebuddy/rules/nullable-gate/` | AI 预防层：禁 `T?`、保持零新增警告 |
| `.github/workflows/verify-clean-build.yml` | 主门禁线：还原 / 构建 / 测试（含 `--blame-hang` 挂起看门狗） |

**纪律**

- `dotnet build` 必须 **0 警告 0 错误**；`dotnet test` 全绿；**每个工作包至少一个用例**。
- `T?`（引用类型可空注解）禁止；值类型可空（`int?`、`enum?`，即 `Nullable<T>`）始终合法。
- 需要**局部**可空分析时，用 `#nullable enable` 在**单个文件**内开启并自洽，**不要**改全局设置。
- 不要用 `-warnaserror` 粗暴兜底：把具体红线（`CS8632`）编进 `WarningsAsErrors` 才能定位。

> 本仓的取舍是 **`Nullable=disable` + 禁 `T?`**（可机械断言、不强迫存量全量迁移）。
> 若你要改用 `Nullable=enable` 全量可空分析，请同时改 `Directory.Build.props`、`.targets` 断言与 `nullable-gate` 规则——
> **不要两套策略并存**，否则"红线"会退化成"看哪个文件"。
