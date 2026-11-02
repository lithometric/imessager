// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "iMessager",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "iMessager",
            path: "Sources/iMessager",
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ],
    swiftLanguageModes: [.v5]
)
