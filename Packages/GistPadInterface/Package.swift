// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "GistPadInterface",
    platforms: [.iOS("27.0"), .macOS(.v15)],
    products: [.library(name: "GistPadInterface", targets: ["GistPadInterface"])],
    targets: [
        .target(name: "GistPadInterface", resources: [.process("Resources")]),
        .testTarget(name: "GistPadInterfaceTests", dependencies: ["GistPadInterface"])
    ]
)
