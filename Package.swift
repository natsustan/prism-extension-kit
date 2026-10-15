// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "PrismExtensionKit",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        // What extension authors depend on.
        .library(name: "PrismExtensionKit", targets: ["PrismExtensionKit"]),
        // The protocol types Prism and extensions share.
        .library(name: "PrismExtensionProtocol", targets: ["PrismExtensionProtocol"]),
        // Prism played in memory, for an extension's own tests.
        .library(name: "PrismExtensionTesting", targets: ["PrismExtensionTesting"]),
    ],
    targets: [
        .target(name: "PrismExtensionProtocol"),
        .target(name: "PrismExtensionKit", dependencies: ["PrismExtensionProtocol"]),
        .target(name: "PrismExtensionTesting", dependencies: ["PrismExtensionKit"]),
        .testTarget(name: "PrismExtensionKitTests", dependencies: ["PrismExtensionKit", "PrismExtensionTesting"]),
    ],
    swiftLanguageModes: [.v6]
)
