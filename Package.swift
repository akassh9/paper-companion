// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PaperCompanion",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "PaperCompanion",
            path: "Sources/PaperCompanion",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
