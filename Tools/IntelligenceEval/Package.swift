// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "IntelligenceEval",
  platforms: [.macOS("27.0")],
  dependencies: [
    .package(path: "../../Packages/GistPadIntelligence"),
    .package(path: "../../Packages/GistPadEditor"),
  ],
  targets: [
    .executableTarget(
      name: "IntelligenceEval",
      dependencies: [
        .product(name: "GistPadIntelligence", package: "GistPadIntelligence"),
        .product(name: "GistPadEditor", package: "GistPadEditor"),
      ])
  ]
)
