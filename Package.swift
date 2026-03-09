// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BandwidthRTC",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "BandwidthRTC", targets: ["BandwidthRTC"]),
    ],
    dependencies: [
        .package(url: "https://github.com/stasel/WebRTC.git", exact: "114.0.0"),
    ],
    targets: [
        // Build plugin — generates SDKVersion+Generated.swift before compiling BandwidthRTC
        .plugin(
            name: "GenerateSDKVersion",
            capability: .buildTool()
        ),
        .target(
            name: "BandwidthRTC",
            dependencies: [.product(name: "WebRTC", package: "WebRTC")],
            plugins: ["GenerateSDKVersion"]
        ),
        .testTarget(
            name: "BandwidthRTCTests",
            dependencies: ["BandwidthRTC"]
        ),
    ]
)
