// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "GistPadEditor",
  platforms: [.iOS("27.2"), .macOS(.v15)],
  products: [.library(name: "GistPadEditor", targets: ["GistPadEditor"])],
  dependencies: [
    .package(path: "../GistPadAppearance"),
    .package(path: "../GistPadComments"),
    .package(path: "../GistPadInterface"),
  ],
  targets: [
    .target(
      name: "GistPadEditor",
      dependencies: ["GistPadAppearance", "GistPadComments", "GistPadInterface"],
      resources: [.process("Resources")]),
    .testTarget(
      name: "GistPadEditorTests",
      dependencies: [
        "GistPadEditor", "GistPadComments", "GistPadInterface", "GistPadAppearance",
      ]),
  ]
)
