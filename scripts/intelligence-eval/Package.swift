// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "IntelligenceEval",
  platforms: [.macOS("27.0")],
  dependencies: [
    .package(name: "GistPad", path: "../.."),
  ],
  targets: [
    .executableTarget(
      name: "IntelligenceEval",
      dependencies: [.product(name: "Intelligence", package: "GistPad")]),
    .testTarget(
      name: "IntelligenceEvalTests",
      dependencies: ["IntelligenceEval"]),
  ]
)
