// swift-tools-version: 5.7.1

import PackageDescription

let package = Package(
    name: "TestUtilities",
    platforms: [
        .iOS(.v11),
        .tvOS(.v11),
    ],
    products: [
        .library(
            name: "TestUtilities",
            targets: ["TestUtilities"]
        ),
    ],
    dependencies: [
        .package(name: "Flashcat", path: ".."),
    ],
    targets: [
        .target(
            name: "TestUtilities",
            dependencies: [
                .product(name: "FlashcatCore", package: "Flashcat"),
                .product(name: "FlashcatRUM", package: "Flashcat"),
                .product(name: "FlashcatLogs", package: "Flashcat"),
                .product(name: "FlashcatTrace", package: "Flashcat"),
                .product(name: "FlashcatCrashReporting", package: "Flashcat"),
                .product(name: "FlashcatSessionReplay", package: "Flashcat"),
                .product(name: "FlashcatWebViewTracking", package: "Flashcat")
            ],
            path: ".",
            sources: ["Sources"],
            swiftSettings: [.define("SPM_BUILD")]
        ),
    ]
)
