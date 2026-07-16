// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "MeatPadKit",
    platforms: [.macOS(.v14)],
    products: [.library(name: "MeatPadKit", targets: ["MeatPadKit"])],
    targets: [
        .target(name: "MeatPadKit"),
        .testTarget(name: "MeatPadKitTests", dependencies: ["MeatPadKit"]),
    ]
)
