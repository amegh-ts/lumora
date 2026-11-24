// swift-tools-version: 6.0
import Foundation
import PackageDescription

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let lgplPrefix = "\(root)/.build/deps/prefix"
let homebrewPrefix = "/opt/homebrew"
let sparkleFrameworks = "\(root)/.build/deps/sparkle"

// Prefer the LGPL libmpv built by Scripts/build-deps.sh; fall back to Homebrew for quick local builds.
let mpvPrefix = FileManager.default.fileExists(atPath: "\(lgplPrefix)/lib/libmpv.dylib") ? lgplPrefix : homebrewPrefix

let package = Package(
    name: "Lumora",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Lumora", targets: ["LumoraApp"])
    ],
    targets: [
        .systemLibrary(
            name: "CMPV",
            path: "Sources/CMPV"
        ),
        .executableTarget(
            name: "LumoraApp",
            dependencies: ["CMPV"],
            path: "Sources/LumoraApp",
            swiftSettings: [
                .unsafeFlags([
                    "-Xcc", "-I\(mpvPrefix)/include",
                    "-F", sparkleFrameworks
                ])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L\(mpvPrefix)/lib",
                    "-F", sparkleFrameworks,
                    "-framework", "Sparkle",
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                    "-Xlinker", "-rpath", "-Xlinker", sparkleFrameworks
                ]),
                .linkedFramework("OpenGL")
            ]
        )
    ]
)
