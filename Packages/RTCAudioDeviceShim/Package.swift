// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "RTCAudioDeviceShim",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "RTCAudioDeviceShim", targets: ["RTCAudioDeviceShim"]),
    ],
    dependencies: [
        .package(url: "https://github.com/stasel/WebRTC.git", exact: "156.0.0"),
    ],
    targets: [
        .target(
            name: "RTCAudioDeviceShim",
            dependencies: [.product(name: "WebRTC", package: "WebRTC")]
        ),
    ]
)
