// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "TranscriptionKit",
    platforms: [.iOS(.v15)],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(name: "TranscriptionKit", targets: ["TranscriptionKit"]),
        .library(name: "TranscriptionKitAWS", targets: ["TranscriptionKitAWS"])
    ],
    dependencies: [
        .package(url: "https://github.com/awslabs/aws-sdk-swift", from: "1.0.0")
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "TranscriptionKit",
        ),
        .target(
            name: "TranscriptionKitAWS",
            dependencies: [
                "TranscriptionKit",
                .product(name: "AWSTranscribeStreaming", package: "aws-sdk-swift")
            ]
        ),
        .testTarget(
            name: "TranscriptionKitTests",
            dependencies: ["TranscriptionKit"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
