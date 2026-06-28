// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "TailRDP",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "TailRDP",
            path: "Sources/TailRDP",
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .unsafeFlags(["-strict-concurrency=minimal"])
            ]
        ),
        .testTarget(
            name: "TailRDPTests",
            dependencies: ["TailRDP"],
            path: "Tests/TailRDPTests",
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .unsafeFlags(["-strict-concurrency=minimal"])
            ]
        )
    ]
)
