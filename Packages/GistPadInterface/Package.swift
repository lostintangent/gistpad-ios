// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "GistPadInterface",
    platforms: [.iOS("27.1"), .macOS(.v15)],
    products: [.library(name: "GistPadInterface", targets: ["GistPadInterface"])],
    dependencies: [.package(path: "../GistPadAppearance")],
    targets: [
        .target(name: "GistPadInterface", dependencies: ["GistPadAppearance"], resources: [.process("Resources")]),
        .testTarget(name: "GistPadInterfaceTests", dependencies: ["GistPadInterface"])
    ]
)
