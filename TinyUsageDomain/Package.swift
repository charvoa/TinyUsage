// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TinyUsageDomain",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "TinyUsageDomain", targets: ["TinyUsageDomain"])],
    targets: [
        .target(name: "TinyUsageDomain"),
        .testTarget(name: "TinyUsageDomainTests", dependencies: ["TinyUsageDomain"])
    ]
)
