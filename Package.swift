// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "SmartBeePixel",
    platforms: [
        .iOS(.v13),
        // macOS yalnız `swift test` üçündür: nüvə məntiqi simulyatorsuz yoxlanır.
        .macOS(.v10_15),
    ],
    products: [
        .library(name: "SmartBeePixel", targets: ["SmartBeePixel"]),
    ],
    targets: [
        .target(
            name: "SmartBeePixel",
            path: "mobile/ios/Sources/SmartBeePixel",
            resources: [.copy("PrivacyInfo.xcprivacy")]
        ),
        .testTarget(
            name: "SmartBeePixelTests",
            dependencies: ["SmartBeePixel"],
            path: "mobile/ios/Tests/SmartBeePixelTests"
        ),
    ]
)
