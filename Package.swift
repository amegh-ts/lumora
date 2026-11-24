// swift-tools-version: 6.0
import PackageDescription

let mpvPrefix = "/opt/homebrew"

let package = Package(
    name: "Lumora",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Lumora", targets: ["LumoraApp"])
    ],
    targets: [
        .systemLibrary(
            name: "CMPV",
            path: "Sources/CMPV",
            pkgConfig: "mpv",
            providers: [.brew(["mpv"])]
        ),
        .executableTarget(
            name: "LumoraApp",
            dependencies: ["CMPV"],
            path: "Sources/LumoraApp",
            swiftSettings: [
                .unsafeFlags(["-Xcc", "-I\(mpvPrefix)/include"])
            ],
            linkerSettings: [
                .unsafeFlags(["-L\(mpvPrefix)/lib"]),
                .linkedFramework("OpenGL")
            ]
        )
    ]
)
