// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "RoomCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "RoomCore", targets: ["RoomCore"]),
    ],
    targets: [
        .target(name: "RoomCore"),
        .testTarget(name: "RoomCoreTests", dependencies: ["RoomCore"]),
    ]
)
