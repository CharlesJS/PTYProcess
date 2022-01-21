// swift-tools-version:5.5

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
    ],
    dependencies: [
        .package(url: "https://github.com/CharlesJS/CSErrors", from: "0.4.1"),
    ],
    targets: [
        .target(
            name: "PTYProcess",
            dependencies: ["CSErrors"]
        ),
    ]
)
