// swift-tools-version:6.2

import PackageDescription

let package = Package(
  name: "SwiftEmberPlus",
  platforms: [
    .macOS(.v15),
    .iOS(.v18),
  ],
  products: [
    .library(name: "EmberPlus", targets: ["EmberPlus"]),
    .library(name: "EmberPlusOCABridge", targets: ["EmberPlusOCABridge"]),
  ],
  dependencies: [
    .package(url: "https://github.com/PADL/SwiftOCA", branch: "main"),
    .package(url: "https://github.com/apple/swift-asn1", from: "1.7.3"),
    .package(url: "https://github.com/swhitty/FlyingFox", from: "0.26.2"),
    .package(url: "https://github.com/apple/swift-log", from: "1.6.2"),
  ],
  targets: [
    // Ember+ provider (S101 framing, Glow DTD 2.50 over BER); knows nothing of OCA
    .target(
      name: "EmberPlus",
      dependencies: [
        .product(name: "SwiftASN1", package: "swift-asn1"),
        .product(name: "FlyingSocks", package: "FlyingFox"),
        .product(name: "Logging", package: "swift-log"),
      ]
    ),
    // presents a SwiftOCADevice object model through the EmberPlus target
    .target(
      name: "EmberPlusOCABridge",
      dependencies: [
        "EmberPlus",
        .product(name: "SwiftOCA", package: "SwiftOCA"),
        .product(name: "SwiftOCADevice", package: "SwiftOCA"),
        .product(name: "Logging", package: "swift-log"),
      ]
    ),
    // an AES70 device served over OCP.1 and Ember+
    .executableTarget(
      name: "EmberPlusDevice",
      dependencies: [
        "EmberPlus",
        "EmberPlusOCABridge",
        .product(name: "SwiftOCA", package: "SwiftOCA"),
        .product(name: "SwiftOCADevice", package: "SwiftOCA"),
        .product(name: "Logging", package: "swift-log"),
      ],
      path: "Examples/EmberPlusDevice"
    ),
    .testTarget(
      name: "EmberPlusTests",
      dependencies: [
        "EmberPlus",
        .product(name: "SwiftASN1", package: "swift-asn1"),
      ]
    ),
    .testTarget(
      name: "EmberPlusOCABridgeTests",
      dependencies: [
        "EmberPlus",
        "EmberPlusOCABridge",
        .product(name: "SwiftOCA", package: "SwiftOCA"),
        .product(name: "SwiftOCADevice", package: "SwiftOCA"),
      ]
    ),
  ]
)
