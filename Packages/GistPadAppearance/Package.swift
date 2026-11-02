// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "GistPadAppearance",
    platforms: [.iOS("27.2"), .macOS(.v14)],
    products: [.library(name: "GistPadAppearance", targets: ["GistPadAppearance"])],
    targets: [
        .target(name: "GistPadAppearance"),
        .testTarget(name: "GistPadAppearanceTests", dependencies: ["GistPadAppearance"])
    ]
)
