// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "GistPadEditor",
    platforms: [.iOS("27.0"), .macOS(.v15)],
    products: [.library(name: "GistPadEditor", targets: ["GistPadEditor"])],
    targets: [
        .target(name: "GistPadEditor", resources: [.process("Resources")]),
        .testTarget(name: "GistPadEditorTests", dependencies: ["GistPadEditor"])
    ]
)
