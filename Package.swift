// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TailRPD",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "TailRPD",
            path: "Sources/TailRPD"
        )
    ]
)
