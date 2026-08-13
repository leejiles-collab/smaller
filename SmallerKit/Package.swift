// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SmallerKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v14)
    ],
    products: [
        .library(name: "SmallerKit", targets: ["SmallerKit"])
    ],
    targets: [
        .target(
            name: "SmallerKit",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "SmallerKitTests",
            dependencies: ["SmallerKit"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
