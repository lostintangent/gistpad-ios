// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GistPadPreview",
    platforms: [.iOS("27.1"), .macOS(.v14)],
    products: [.library(name: "GistPadPreview", targets: ["GistPadPreview"])],
    dependencies: [.package(path: "../GistPadAppearance")],
    targets: [
        .target(
            name: "GistPadPreview",
            dependencies: ["GistPadAppearance"],
            resources: [.copy("Resources/Web"), .copy("Resources/Fixtures")]
        ),
        .testTarget(name: "GistPadPreviewTests", dependencies: ["GistPadPreview", "GistPadAppearance"])
    ],
    swiftLanguageModes: [.v6]
)
