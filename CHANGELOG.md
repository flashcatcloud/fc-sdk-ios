# Flashcat iOS SDK - Changelog

> Flashcat SDK 基于 [Datadog iOS SDK](https://github.com/DataDog/dd-sdk-ios) 构建，采用独立版本号体系。  
> 每个版本对应的 upstream Datadog 版本见各版本说明。
> Flashcat SDK is built on [Datadog iOS SDK](https://github.com/DataDog/dd-sdk-ios) with independent versioning.  
> Each version corresponds to an upstream Datadog version as noted in the release description.

---

## [Unreleased]

---

## [0.5.0] - 2026-06-11

**Based on Datadog iOS SDK 3.6.0**（与 0.4.0 同上游，无上游同步）

### Added

- Crash Reporting **进程内符号化**（in-process symbolication）：新增 `CrashReporting.Configuration(symbolicateInProcess:)`（默认 `true`），崩溃栈在设备端直接由 KSCrash `dladdr` 解析的符号生成，并对 Swift 符号做 `swift_demangle` 还原为可读形式（对标 Bugly），无需上传 dSYM。新增 `CrashReporting.enable(with:)` 与 `CrashReporting.enable(symbolicateInProcess:)` 重载；ObjC / C 符号原样透传，未解析帧回退为 `??? 0xADDR 0x0 + 0`。
- Logs 与 Session Replay 的独立 **No-Op pods**：`FlashcatLogs-NoOp`、`FlashcatSessionReplay-NoOp`，便于在不引入完整实现时满足依赖。

### Changed

- Release workflow 与 CI 校验矩阵纳入新的 No-Op 模块。
- README 修正各模块的 Swift module import 名。

### Flashcat Specific

- SDK 版本号更新为 `0.5.0`，所有 `Flashcat*.podspec` 与 `DatadogCore/Sources/Versioning.swift` 的 `__sdkVersion` 同步为 `0.5.0`。

### Breaking Changes

- 无。本版本所有公共 API 变更均为新增（additive），向后兼容 0.4.0。

---

## [0.4.0] - 2026-02-02

**Based on Datadog iOS SDK 3.6.0**

### Added

- Device 硬件信息采集：上报 CPU 逻辑核心数 (`logical_cpu_count`) 和总内存 (`total_ram`)。
- Trace Sampling Decision 机制，支持 manual keep / drop，并在 Datadog、B3、W3C trace headers 中传播采样决策。
- CrossPlatformExtension 与 SharedContext 支持，用于跨平台 SDK 读取 Core 上下文。
- RUM App Launch 指标：新增 TTID（Time To Initial Display）和 TTFD（Time To Full Display），并区分 cold / warm / prewarmed startup。
- RUM Alert、Confirmation Dialog、Action Sheet 自动埋点及对应集成测试。
- Session Replay 的 screen-change based recording 相关内部实现，包括 `ScreenChangeMonitor`、`ScreenChangeScheduler` 和 CALayer 变化聚合。

### Changed

- 同步上游 Datadog iOS SDK 从 3.3.0 到 3.6.0。
- Crash Reporting 默认插件从 PLCrashReporter 迁移到 KSCrash，CocoaPods 依赖更新为 `KSCrash/Recording` 和 `KSCrash/Filters` 2.5.0。
- OpenTelemetryApi 升级到 2.3.0，SPM 改为依赖 `opentelemetry-swift-core`。
- 默认开启 Slow Frames（View Hitches）追踪。
- RUM session、watchdog termination、app hangs、resource tracking 相关内部状态管理随上游重构。
- 公共 API surface、Xcode 工程、SmokeTests、IntegrationTests、BenchmarkTests 随上游 3.6.0 同步更新。

### Fixed

- 修复 Xcode 项目中 `TraceCoreContext.swift` 和 `TraceID.swift` 的重复引用警告。
- 修复 App Hangs backtrace 生成时的崩溃问题。
- 修复 Trace URLSession instrumentation 中 active span 获取和传播状态保存的问题。
- 修复 KSCrash user-info 同步、符号信息解析和 xcframework 校验相关问题。

### Flashcat Specific

- SDK 版本号更新为 `0.4.0`，所有 `Flashcat*.podspec` 使用 `0.4.0`。
- README 和 CHANGELOG 调整为 Flashcat 独立版本体系，并将完整上游变更移到 `CHANGELOG-UPSTREAM.md`。
- SPM products 和 CocoaPods pod 名称保持 `Flashcat*` 命名，Swift module import 仍使用 `Datadog*`。
- Flashcat 发行继续禁用 `DatadogLogs`、`DatadogSessionReplay`、`DatadogFlags`、`DatadogProfiling`，并新增 `disabled/DatadogProfiling.podspec`。

### Breaking Changes

- `DatadogSite` 更名为 `FlashcatSite`，默认 endpoint 使用 Flashcat Cloud。
- Crash Reporting 的默认实现切换到 KSCrash；如接入方自定义 crash plugin，需要关注 `CrashReporting.enable(with:)` 的初始化错误处理变化。

---

## [0.3.0] - 2026-01-26

**Based on Datadog iOS SDK 3.3.0**

### Added

- 初始 Fork 自 Datadog iOS SDK
- FlashcatSite 配置，支持中国区 endpoint
- Flashcat 品牌命名（FlashcatCore, FlashcatTrace, FlashcatRUM 等）
- GitHub Actions Release 工作流

### Changed

- 所有 podspec 重命名为 `Flashcat*.podspec` 格式
- SPM Package 名称改为 `Flashcat`
- 默认 Site 设为 `.cn`
- Initial fork from Datadog iOS SDK
- FlashcatSite configuration for China region endpoints
- Flashcat branding (FlashcatCore, FlashcatTrace, FlashcatRUM, etc.)
- GitHub Actions Release workflow

### Changed

- All podspecs renamed to `Flashcat*.podspec` format
- SPM Package name changed to `Flashcat`
- Default site set to `.cn`

### Disabled Modules

- DatadogLogs
- DatadogSessionReplay

---

## Version Mapping

| Flashcat Version | Datadog Version | Release Date |
| ---------------- | --------------- | ------------ |
| 0.5.0            | 3.6.0           | 2026-06-11   |
| 0.4.0            | 3.6.0           | 2026-02-02   |
| 0.3.0            | 3.3.0           | 2026-01-26   |

---

## Upstream Changelog

完整的 Datadog iOS SDK 变更历史请参见 [CHANGELOG-UPSTREAM.md](./CHANGELOG-UPSTREAM.md)。
For complete Datadog iOS SDK changelog, see [CHANGELOG-UPSTREAM.md](./CHANGELOG-UPSTREAM.md).

---

## Links

- [Flashcat SDK Repository](https://github.com/flashcatcloud/fc-sdk-ios)
- [Datadog iOS SDK (Upstream)](https://github.com/DataDog/dd-sdk-ios)
- [Migration Guide](./MIGRATION.md)
