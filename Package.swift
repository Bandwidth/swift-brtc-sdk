// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BandwidthRTC",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "BandwidthRTC", type: .dynamic, targets: ["BandwidthRTC"]),
    ],
    dependencies: [
        .package(url: "https://github.com/stasel/WebRTC.git", exact: "114.0.0"),
    ],
    targets: [
        .target(
            name: "BandwidthRTC",
            dependencies: [.product(name: "WebRTC", package: "WebRTC")]
        ),
        .testTarget(
            name: "BandwidthRTCTests",
            dependencies: ["BandwidthRTC"]
        ),
    ]
)
