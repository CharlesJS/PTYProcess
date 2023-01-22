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
        .package(url: "https://github.com/CharlesJS/CSErrors", from: "1.1.0"),
        .package(url: "https://github.com/CharlesJS/XCTAsyncAssertions", from: "0.2.0"),
        .package(url: "https://github.com/mattgallagher/CwlPreconditionTesting.git", from: Version("2.0.0"))
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
            dependencies: [
                "PTYProcess",
                .product(name: "CSErrors+Foundation", package: "CSErrors")
            ]
        ),
        .testTarget(
            name: "PTYProcessTests",
            dependencies: ["PTYProcess_Foundation", "XCTAsyncAssertions", "CwlPreconditionTesting"]
        )
    ]
)
