// swift-tools-version: 5.7
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package: Package = .init(
    name: "Jinx",
    products: [
        .library(
            name: "Jinx",
            targets: ["Jinx"]
        ),
    ],
    targets: [
        .target(
            name: "Jinx",
            swiftSettings: [
                .unsafeFlags(["-I/Users/cupcake/theos/include"])
            ]
        )
    ]
)
