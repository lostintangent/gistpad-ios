// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "GistPadAccent",
    platforms: [.iOS("27.2"), .macOS(.v14)],
    products: [.library(name: "GistPadAccent", targets: ["GistPadAccent"])],
    targets: [
        .target(name: "GistPadAccent"),
        .testTarget(name: "GistPadAccentTests", dependencies: ["GistPadAccent"])
    ]
)
