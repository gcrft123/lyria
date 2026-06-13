// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DynamicIsland",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "DynamicIsland", targets: ["DynamicIsland"])
    ],
    targets: [
        .executableTarget(
            name: "DynamicIsland",
            path: "Sources/DynamicIsland"
        )
    ]
)
