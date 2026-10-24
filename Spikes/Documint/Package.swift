// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "GistPadDocumintSpike",
    platforms: [.iOS("27.1")],
    products: [.library(name: "GistPadDocumintSpike", targets: ["GistPadDocumintSpike"])],
    dependencies: [
        .package(path: "../../Packages/GistPadEditor"),
        .package(path: "../../Packages/GistPadPreview"),
        .package(path: "../../Packages/GistPadAppearance")
    ],
    targets: [
        .target(
            name: "GistPadDocumintSpike",
            dependencies: ["GistPadEditor", "GistPadPreview", "GistPadAppearance"],
            resources: [.copy("Resources/Web")]
        ),
        .testTarget(
            name: "GistPadDocumintSpikeTests",
            dependencies: ["GistPadDocumintSpike", "GistPadEditor"]
        )
    ],
    swiftLanguageModes: [.v6]
)
