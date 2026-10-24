// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "GistPadEditor",
  platforms: [.iOS("27.1"), .macOS(.v15)],
  products: [.library(name: "GistPadEditor", targets: ["GistPadEditor"])],
  dependencies: [.package(path: "../GistPadInterface")],
  targets: [
    .target(
      name: "GistPadEditor", dependencies: ["GistPadInterface"],
      resources: [.process("Resources")]),
    .testTarget(name: "GistPadEditorTests", dependencies: ["GistPadEditor"]),
  ]
)
