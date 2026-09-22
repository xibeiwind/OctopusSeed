# 变体：.NET

`-Stack dotnet` 时被叠加。它把 **质量门禁编进构建**，而不是写在文档里（`template/CONTRIBUTING.md` §8）。

## 落地内容

| 文件 | 作用 |
|---|---|
| `Directory.Build.props` | 统一 TFM / `ImplicitUsings` / `Nullable=disable` / `WarningsAsErrors=CS8632` / 程序集属性；本目录及所有子项目自动继承，避免逐个 csproj 重复声明 |
| `Directory.Build.targets` | **构建期断言**：任何 csproj 私自把 `Nullable` 覆盖为非 `disable` 即编译失败，迫使团队走显式评审 |
| `global.json` | 钉 SDK 版本与 `rollForward` 策略（避免"我这能跑"式差异） |
| `.codebuddy/rules/nullable-gate/RULE.mdc` | AI 预防层：禁止引用类型可空注解 `T?`、保持零新增警告 |
| `.codebuddy/rules/modern-csharp-syntax/RULE.mdc` | AI 预防层：按项目实际设置取语法版本上限（C# 12）、C# 13+ 禁用清单、反射 / 可空例外 |
| `tools/assets.ps1` | **存量台账**（只读、**非判据**）：零消费者的工程必须有台账授权行；条件已触发须标 `EXPIRED` 并持续报 finding |
| `jobs/dotnet.yml` | CI 主门禁线：还原 / 构建 / 测试（含 `--blame-hang` 挂起看门狗） |

## 为什么用 `CS8632` 而不是 `Nullable=enable`

- `Nullable=disable` + **禁止 `T?`** 是一条**可机械断言**的红线：它把"引用类型可空注解"从"风格偏好"变成编译错误，
  且不会强迫存量代码全量迁移到可空分析。
- 需要**局部**开启可空分析时，用 `#nullable enable` 在**单个文件**内开启并自洽，而不是改全局设置。
- 值类型可空（`int?`、`enum?`，即 `Nullable<T>`）**始终合法**。

> 若你的项目**本就**使用 `Nullable=enable` 全量可空分析，那是另一种（更严格的）策略：
> 请改 `Directory.Build.props` 与 `.targets` 的断言、并同步 `nullable-gate` 规则——**不要**两套策略并存，
> 否则"红线"会退化成"看哪个文件"。

## 迁移注意

1. **TFM**：`Directory.Build.props` 里的 `TargetFramework` 是统一默认值；需要分层（如核心层不带 OS 后缀）时，
   在子项目 csproj 里**显式覆盖**并在 `docs/02-总体设计.md` 说明分层理由。
2. **编码**：`Directory.Build.props/.targets` 为 UTF-8 无 BOM + 中文注释——MSBuild 能正确读取；
   但 `tools/*.ps1` 是**纯 ASCII** 纪律（PowerShell 5.1 按本地码页解析），两者不要互相套用。
3. **程序集属性**：`Authors` / `Company` / `Product` 已替换为 `{{PROJECT_NAME}}`，按需改成真实值。
4. **测试工程命名**：`tests/<Project>.Tests` 是本模板沿用的约定；CI 命令不依赖它，可自行调整。
5. **`dotnet new` 生成的项目要被清理一次**：现代模板会往 csproj 里写 `<Nullable>enable</Nullable>`，它会被本变体的
   构建期断言直接拦下（报错明确指向 `Directory.Build.targets`）。删掉该行即可——**这是断言在起作用，不是配置错了**：
   红线要的是"只有一个地方决定可空策略"。同理，模板写进 csproj 的 `<TargetFramework>` / `<LangVersion>` 也按第 1 条处理。
