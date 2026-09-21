// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "switchboard-agent",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "switchboard-agent",
            path: "Sources/switchboard-agent"
        )
    ]
)
