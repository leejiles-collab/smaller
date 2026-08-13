// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "smallercli",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "smallercli", targets: ["smallercli"])
    ],
    dependencies: [
        // Local package in this repo, not a fetched dependency.
        .package(path: "../../SmallerKit")
    ],
    targets: [
        .executableTarget(
            name: "smallercli",
            dependencies: [
                .product(name: "SmallerKit", package: "SmallerKit")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
