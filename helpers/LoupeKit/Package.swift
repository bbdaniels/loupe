// swift-tools-version:5.9
import PackageDescription

/// Code the Topaz helpers share (Loupe and Topaz Launcher).
let package = Package(
    name: "LoupeKit",
    platforms: [.macOS(.v14)],
    products: [.library(name: "LoupeKit", targets: ["LoupeKit"])],
    targets: [.target(name: "LoupeKit")]
)
