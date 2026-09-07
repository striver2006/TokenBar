// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TokenBar",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "TokenBar",
            targets: ["TokenBar"]
        )
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "TokenBar",
            dependencies: [],
            path: "Sources/TokenBar"
        ),
        .testTarget(
            name: "TokenBarTests",
            dependencies: ["TokenBar"],
            path: "Tests/TokenBarTests"
        )
    ]
)
