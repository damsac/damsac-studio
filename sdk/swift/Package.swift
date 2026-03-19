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
            dependencies: []
        ),
        .testTarget(
            name: "StudioAnalyticsTests",
            dependencies: ["StudioAnalytics"]
        )
    ]
)
