// swift-tools-version:5.7

import PackageDescription

let package = Package(
    name: "PTYProcess",
    platforms: [
        .macOS(.v10_15),
        .macCatalyst(.v13),
        .iOS(.v13),
        .tvOS(.v13),
        .watchOS(.v6),
    ],
    products: [
        .library(
            name: "PTYProcess",
            targets: ["PTYProcess"]
        ),
        .library(
            name: "PTYProcess+Foundation",
            targets: ["PTYProcess_Foundation"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-async-algorithms", from: "0.0.2"),
        .package(url: "https://github.com/CharlesJS/CSErrors", from: "0.4.1"),
        .package(url: "https://github.com/CharlesJS/XCTAsyncAssertions", from: "0.1.1")
    ],
    targets: [
        .target(
            name: "PTYProcess",
            dependencies: [
                .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
                "CSErrors"
            ]
        ),
        .target(
            name: "PTYProcess_Foundation",
            dependencies: ["PTYProcess"]
        ),
        .testTarget(
            name: "PTYProcessTests",
            dependencies: ["PTYProcess_Foundation", "XCTAsyncAssertions"]
        )
    ]
)
