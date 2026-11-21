// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "HearMeOutCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "HearMeOutCore", targets: ["HearMeOutCore"])],
    targets: [
        .target(name: "HearMeOutCore", path: "Sources/HearMeOutCore"),
        .testTarget(name: "HearMeOutCoreTests", dependencies: ["HearMeOutCore"], path: "Tests/HearMeOutCoreTests"),
    ]
)
