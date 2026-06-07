// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SayItCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SayItCore", targets: ["SayItCore"]),
    ],
    targets: [
        .target(name: "SayItCore"),
        .testTarget(name: "SayItCoreTests", dependencies: ["SayItCore"]),
    ]
)
