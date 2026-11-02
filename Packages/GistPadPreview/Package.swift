// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GistPadPreview",
    platforms: [.iOS("27.2"), .macOS(.v15)],
    products: [.library(name: "GistPadPreview", targets: ["GistPadPreview"])],
    dependencies: [
        .package(path: "../GistPadAccent"), .package(path: "../GistPadComments")
    ],
    targets: [
        .target(
            name: "GistPadPreview",
            dependencies: ["GistPadAccent", "GistPadComments"],
            resources: [.copy("Resources/Web"), .copy("Resources/Fixtures")]
        ),
        .testTarget(
            name: "GistPadPreviewTests",
            dependencies: ["GistPadPreview", "GistPadAccent", "GistPadComments"])
    ],
    swiftLanguageModes: [.v6]
)
