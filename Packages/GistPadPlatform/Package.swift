// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "GistPadPlatform",
    platforms: [.iOS("27.1"), .macOS(.v15)],
    products: [.library(name: "GistPadPlatform", targets: ["GistPadPlatform"])],
    dependencies: [
        .package(path: "../GistPadSync"),
        .package(path: "../GistPadAppearance")
    ],
    targets: [
        .target(name: "GistPadPlatform", dependencies: ["GistPadSync", "GistPadAppearance"]),
        .testTarget(name: "GistPadPlatformTests", dependencies: ["GistPadPlatform", "GistPadSync"])
    ]
)
