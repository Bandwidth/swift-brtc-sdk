// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BandwidthBRTC",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "BandwidthBRTC", targets: ["BandwidthBRTC"]),
    ],
    dependencies: [
        .package(url: "https://github.com/stasel/WebRTC.git", exact: "114.0.0"),
    ],
    targets: [
        .target(
            name: "BandwidthBRTC",
            dependencies: [.product(name: "WebRTC", package: "WebRTC")]
        ),
        .testTarget(
            name: "BandwidthBRTCTests",
            dependencies: ["BandwidthBRTC"]
        ),
    ]
)
