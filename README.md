# Flashcat SDK for iOS and tvOS

[![Swift](https://img.shields.io/badge/Swift-5.9+-orange.svg)](https://swift.org)
[![Platform](https://img.shields.io/badge/Platform-iOS%2012%2B%20%7C%20tvOS%2012%2B-blue.svg)](https://developer.apple.com)
[![License](https://img.shields.io/badge/License-Apache%202.0-green.svg)](LICENSE)

> Swift and Objective-C libraries to interact with Flashcat on iOS and tvOS.

## About

This SDK is forked from [Datadog iOS SDK](https://github.com/DataDog/dd-sdk-ios) and customized for Flashcat Cloud. It provides observability features including Real User Monitoring (RUM), distributed tracing, and crash reporting.

### Key Differences from Datadog SDK

- **Endpoint**: Data is sent to Flashcat Cloud (`flashcat.cloud`) instead of Datadog
- **Site Configuration**: Uses `FlashcatSite` with `.cn` and `.staging` options
- **Naming**: Distribution names are renamed (e.g., `FlashcatCore`, `FlashcatRUM`, `FlashcatTrace`), while Swift module imports remain `Datadog*`
- **Disabled Modules**: `DatadogLogs`, `DatadogSessionReplay`, `DatadogFlags`, `DatadogProfiling` are currently not available

## Available Modules

| Module | Description |
|--------|-------------|
| `FlashcatCore` | Core SDK functionality and initialization |
| `FlashcatRUM` | Real User Monitoring for views, actions, resources, and errors |
| `FlashcatTrace` | Distributed tracing with OpenTelemetry support |
| `FlashcatCrashReporting` | Crash detection and reporting |
| `FlashcatWebViewTracking` | WebView tracking for hybrid mobile applications |

## Installation

### Swift Package Manager

Add the following to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/flashcatcloud/fc-sdk-ios.git", from: "0.4.0")
]
```

Then add the products you need:

```swift
.target(
    name: "YourApp",
    dependencies: [
        .product(name: "FlashcatCore", package: "fc-sdk-ios"),
        .product(name: "FlashcatRUM", package: "fc-sdk-ios"),
        .product(name: "FlashcatTrace", package: "fc-sdk-ios"),
        .product(name: "FlashcatCrashReporting", package: "fc-sdk-ios"),
        .product(name: "FlashcatWebViewTracking", package: "fc-sdk-ios"),
    ]
)
```

### CocoaPods

Add to your `Podfile`:

```ruby
pod 'FlashcatCore'
pod 'FlashcatRUM'
pod 'FlashcatTrace'
pod 'FlashcatCrashReporting'
pod 'FlashcatWebViewTracking'
```

## Getting Started

### Initialization

```swift
import DatadogCore

Datadog.initialize(
    with: Datadog.Configuration(
        clientToken: "<YOUR_CLIENT_TOKEN>",
        env: "production",
        site: .cn  // or .staging
    ),
    trackingConsent: .granted
)
```

### RUM (Real User Monitoring)

```swift
import DatadogRUM

RUM.enable(with: RUM.Configuration(applicationID: "<YOUR_APP_ID>"))
```

### Trace (Distributed Tracing)

```swift
import DatadogTrace

Trace.enable()
```

### Crash Reporting

```swift
import DatadogCrashReporting

CrashReporting.enable()
```

### WebView Tracking

Track web views in hybrid mobile applications:

```swift
import DatadogWebViewTracking
import WebKit

let webView = WKWebView(...)
WebViewTracking.enable(webView: webView)
```

## Documentation

- [Changelog](CHANGELOG.md)
- [Migration Guide](MIGRATION.md)
- [Upstream Datadog Documentation](https://docs.datadoghq.com/real_user_monitoring/ios)

## Contributing

Pull requests are welcome. First, open an issue to discuss what you would like to change. For more information, read the [Contributing Guide](CONTRIBUTING.md).

## License

[Apache License, v2.0](LICENSE)

This project is forked from [Datadog iOS SDK](https://github.com/DataDog/dd-sdk-ios) which is also licensed under Apache 2.0.

## Acknowledgments

This SDK is based on the excellent work of the [Datadog](https://www.datadoghq.com/) team. We are grateful for their open-source contribution.
