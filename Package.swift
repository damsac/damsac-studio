// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "StudioAnalytics",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "StudioAnalytics",
            targets: ["StudioAnalytics"]
        )
    ],
    targets: [
        .target(
            name: "StudioAnalytics",
            dependencies: [],
            path: "sdk/swift/Sources/StudioAnalytics"
        ),
        .testTarget(
            name: "StudioAnalyticsTests",
            dependencies: ["StudioAnalytics"],
            path: "sdk/swift/Tests/StudioAnalyticsTests"
        )
    ]
)
