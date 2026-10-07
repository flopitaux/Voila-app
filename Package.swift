// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Voila",
    platforms: [.macOS("26.0")],
    dependencies: [
        // Auto-updates (download, verify, "Install and Relaunch").
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    ],
    targets: [
        .executableTarget(
            name: "Voila",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Voila",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                // Sparkle.framework is embedded in Voilà.app/Contents/Frameworks.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        )
    ]
)
