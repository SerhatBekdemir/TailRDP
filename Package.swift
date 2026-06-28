// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TailRDP",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "TailRDP",
            path: "Sources/TailRDP"
        ),
        .testTarget(
            name: "TailRDPTests",
            dependencies: ["TailRDP"],
            path: "Tests/TailRDPTests"
        )
    ]
)
