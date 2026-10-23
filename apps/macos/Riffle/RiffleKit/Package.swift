// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "RiffleKit",
    platforms: [.macOS("26.0")],
    products: [.library(name: "RiffleKit", targets: ["RiffleKit"])],
    targets: [
        .target(name: "RiffleKit"),
        .testTarget(name: "RiffleKitTests", dependencies: ["RiffleKit"]),
    ]
)
