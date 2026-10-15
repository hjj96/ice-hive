// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "IceHiveCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "IceHiveCore", targets: ["IceHiveCore"]),
    ],
    targets: [
        .target(name: "IceHiveCore", path: "Sources/IceHiveCore"),
        .testTarget(name: "IceHiveCoreTests", dependencies: ["IceHiveCore"], path: "Tests/IceHiveCoreTests"),
    ],
    swiftLanguageVersions: [.v5]
)
