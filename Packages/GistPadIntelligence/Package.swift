// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "GistPadIntelligence",
  platforms: [.iOS("27.2"), .macOS(.v15)],
  products: [.library(name: "GistPadIntelligence", targets: ["GistPadIntelligence"])],
  targets: [
    .target(name: "GistPadIntelligence", resources: [.process("Resources")]),
    .testTarget(name: "GistPadIntelligenceTests", dependencies: ["GistPadIntelligence"]),
  ]
)
