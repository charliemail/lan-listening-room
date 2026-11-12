// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WebRTCProbe",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/stasel/WebRTC.git", exact: "156.0.0"),
        .package(path: "../../Packages/RTCAudioDeviceShim"),
    ],
    targets: [
        .executableTarget(
            name: "webrtc-loopback",
            dependencies: [
                .product(name: "RTCAudioDeviceShim", package: "RTCAudioDeviceShim"),
                .product(name: "WebRTC", package: "WebRTC"),
            ]
        ),
    ]
)
