// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ContextCacheKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ContextCacheKit", targets: ["ContextCacheKit"])
    ],
    targets: [
        .target(name: "ContextCacheKit"),
        .testTarget(name: "ContextCacheKitTests", dependencies: ["ContextCacheKit"])
    ]
)
