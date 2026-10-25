// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GistPadPreview",
    platforms: [.iOS("27.1"), .macOS(.v15)],
    products: [.library(name: "GistPadPreview", targets: ["GistPadPreview"])],
    dependencies: [
        .package(path: "../GistPadAppearance"), .package(path: "../GistPadComments")
    ],
    targets: [
        .target(
            name: "GistPadPreview",
            dependencies: ["GistPadAppearance", "GistPadComments"],
            resources: [.copy("Resources/Web"), .copy("Resources/Fixtures")]
        ),
        .testTarget(
            name: "GistPadPreviewTests",
            dependencies: ["GistPadPreview", "GistPadAppearance", "GistPadComments"])
    ],
    swiftLanguageModes: [.v6]
)
