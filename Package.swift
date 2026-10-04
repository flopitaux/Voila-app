// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Voila",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "Voila",
            path: "Sources/Voila",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
