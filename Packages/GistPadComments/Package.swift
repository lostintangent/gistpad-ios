// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "GistPadComments",
    platforms: [.iOS("27.1"), .macOS(.v15)],
    products: [.library(name: "GistPadComments", targets: ["GistPadComments"])],
    targets: [
        .target(name: "GistPadComments"),
        .testTarget(
            name: "GistPadCommentsTests", dependencies: ["GistPadComments"],
            resources: [.copy("Fixtures")])
    ]
)
