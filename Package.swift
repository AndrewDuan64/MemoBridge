// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MemoBridge",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "MemoBridge", targets: ["MemoBridgeApp"])],
    targets: [
        .executableTarget(
            name: "MemoBridgeApp",
            path: "Sources/MemoBridgeApp",
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)
