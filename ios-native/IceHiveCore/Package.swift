// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "IceHiveCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "IceHiveCore", targets: ["IceHiveCore"]),
        // v1.1 balance runner (README «v1.1 Ставки» → calibration; CI core-tests runs `--preset gate --gate`)
        .executable(name: "icehive-calib", targets: ["IceHiveCalib"]),
    ],
    targets: [
        .target(name: "IceHiveCore", path: "Sources/IceHiveCore"),
        .executableTarget(name: "IceHiveCalib", dependencies: ["IceHiveCore"], path: "Sources/IceHiveCalib"),
        .testTarget(name: "IceHiveCoreTests", dependencies: ["IceHiveCore"], path: "Tests/IceHiveCoreTests"),
    ],
    swiftLanguageVersions: [.v5]
)
