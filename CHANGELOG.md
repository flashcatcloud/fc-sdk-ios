# Flashcat iOS SDK - Changelog

> Flashcat SDK 基于 [Datadog iOS SDK](https://github.com/DataDog/dd-sdk-ios) 构建，采用独立版本号体系。  
> 每个版本对应的 upstream Datadog 版本见各版本说明。

---

## [Unreleased]

---

## [0.4.0] - 2026-01-30

**Based on Datadog iOS SDK 3.6.0**

### Added

- Device 硬件信息：CPU 逻辑核心数 (`logical_cpu_count`) 和总内存 (`total_ram`)
- Trace Sampling Decision 机制，支持手动 keep/drop
- CrossPlatformExtension 的 SharedContext 支持
- RUM Alert、Confirmation Dialog 和 Action Sheet 自动埋点支持
- TTID（Time To Initial Display）和 TTFD（Time To Full Display）指标

### Changed

- Crash Reporting 插件从 PLCrashReporter 迁移到 KSCrash 2.5.1
- OpenTelemetryApi 升级到 2.3.0
- Session Replay 屏幕变化监控机制优化
- 默认开启 Slow Frames（View Hitches）追踪

### Fixed

- 修复 Xcode 项目中 TraceCoreContext.swift 和 TraceID.swift 的重复引用警告
- 修复 App Hangs backtrace 生成时的崩溃问题

### Flashcat Specific

- Site 配置类型更名为 `FlashcatSite`（支持 `.cn` 和 `.staging`）
- 默认 Site 从 `.us1` 更改为 `.cn`
- 禁用模块：`DatadogLogs`、`DatadogSessionReplay`、`DatadogFlags`、`DatadogProfiling`
- 所有 podspec 和 SPM products 使用 Flashcat 命名

### Breaking Changes

- `DatadogSite` → `FlashcatSite`
- 默认 endpoint 改为 `flashcat.cloud`

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

### Disabled Modules

- DatadogLogs
- DatadogSessionReplay

---

## Version Mapping

| Flashcat Version | Datadog Version | Release Date |
| ---------------- | --------------- | ------------ |
| 0.4.0            | 3.6.0           | 2026-01-30   |
| 0.3.0            | 3.3.0           | 2026-01-26   |

---

## Upstream Changelog

完整的 Datadog iOS SDK 变更历史请参见 [CHANGELOG-UPSTREAM.md](./CHANGELOG-UPSTREAM.md)。

---

## Links

- [Flashcat SDK Repository](https://github.com/flashcatcloud/fc-sdk-ios)
- [Datadog iOS SDK (Upstream)](https://github.com/DataDog/dd-sdk-ios)
- [Migration Guide](./MIGRATION.md)
