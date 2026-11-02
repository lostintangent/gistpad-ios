// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "GistPadIntelligence",
  platforms: [.iOS("27.2"), .macOS("27.0")],
  products: [.library(name: "GistPadIntelligence", targets: ["GistPadIntelligence"])],
  dependencies: [.package(path: "../GistPadEditor")],
  targets: [
    .target(
      name: "GistPadIntelligence", dependencies: ["GistPadEditor"],
      resources: [.process("Resources")]),
    .testTarget(name: "GistPadIntelligenceTests", dependencies: ["GistPadIntelligence"]),
  ]
)
