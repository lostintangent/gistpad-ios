// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "GistPadInterface",
    platforms: [.iOS("27.2"), .macOS(.v15)],
    products: [.library(name: "GistPadInterface", targets: ["GistPadInterface"])],
    dependencies: [
        .package(path: "../GistPadAppearance"),
        .package(path: "../GistPadComments")
    ],
    targets: [
        .target(
            name: "GistPadInterface", dependencies: ["GistPadAppearance", "GistPadComments"],
            resources: [.process("Resources")]),
        .testTarget(name: "GistPadInterfaceTests", dependencies: ["GistPadInterface"])
    ]
)
