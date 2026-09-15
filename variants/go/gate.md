## 栈专属门禁（Go）

本仓的栈专属约束**编在构建里**，不是写在文档里（`CONTRIBUTING.md` §8）。

| 载体 | 约束 |
|---|---|
| `go vet ./...` | 静态检查——**输出必须让 CI 失败**（不进 CI 就等于没有门禁） |
| `gofmt -l .` | 格式零漂移：**有输出即失败** |
| `.github/workflows/verify-clean-build.yml` | 主门禁线：gofmt → vet → build → `go test ./... -count=1` |

**纪律**

- 测试一律带 `-count=1`（否则"上次过了"会伪装成"这次也过"）。
- **每个工作包至少一个用例**；并发代码建议按需开启 `-race`（耗时翻倍）。
- 可选加强：`staticcheck ./...` / `golangci-lint run`——**阈值一律"零 finding"**，"暂不修的清单"写进 `docs/范围边界清单.md`，而不是就地放宽。
- 模块路径 / 包名与「能力归属」的对应关系写进 `docs/02-总体设计.md`，否则专题设计与代码会各说各话（`R-Plan-6`）。

> 起步配置与理由见模板仓 `variants/go/README.md`。
