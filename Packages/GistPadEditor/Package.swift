// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "GistPadEditor",
  platforms: [.iOS("27.2"), .macOS(.v15)],
  products: [.library(name: "GistPadEditor", targets: ["GistPadEditor"])],
  dependencies: [
    .package(path: "../GistPadAccent"),
    .package(path: "../GistPadComments"),
  ],
  targets: [
    .target(
      name: "GistPadEditor",
      dependencies: ["GistPadAccent", "GistPadComments"],
      resources: [.process("Resources")]),
    .testTarget(
      name: "GistPadEditorTests",
      dependencies: ["GistPadEditor", "GistPadComments"]),
  ]
)
