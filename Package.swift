// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Lumora",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Lumora", targets: ["LumoraApp"])
    ],
    targets: [
        .executableTarget(
            name: "LumoraApp",
            path: "Sources/LumoraApp"
        )
    ]
)
