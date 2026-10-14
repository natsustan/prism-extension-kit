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
    ],
    targets: [
        .target(name: "PrismExtensionProtocol"),
        .target(name: "PrismExtensionKit", dependencies: ["PrismExtensionProtocol"]),
        .testTarget(name: "PrismExtensionKitTests", dependencies: ["PrismExtensionKit"]),
    ],
    swiftLanguageModes: [.v6]
)
