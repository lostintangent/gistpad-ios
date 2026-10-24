// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "GistPadPlatform",
    platforms: [.iOS("27.1"), .macOS(.v15)],
    products: [.library(name: "GistPadPlatform", targets: ["GistPadPlatform"])],
    targets: [
        .target(name: "GistPadPlatform"),
        .testTarget(name: "GistPadPlatformTests", dependencies: ["GistPadPlatform"])
    ]
)
