// swift-tools-version: 6.2
import PackageDescription

// The app's modules. GistPad.xcodeproj builds the app and the widget extension and links these products.
let modules = [
  "GistPadAccent", "GistPadComments", "GistPadEditor", "GistPadIntelligence",
  "GistPadInterface", "GistPadPlatform", "GistPadPreview", "GistPadSync",
]

let package = Package(
  name: "GistPad",
  platforms: [.iOS("27.2"), .macOS("27.0")],
  products: modules.map { .library(name: $0, targets: [$0]) },
  dependencies: [
    .package(url: "https://github.com/supabase/supabase-swift.git", exact: "2.55.4")
  ],
  targets: [
    .target(name: "GistPadAccent"),
    .target(name: "GistPadComments", exclude: ["README.md"]),
    .target(
      name: "GistPadEditor", dependencies: ["GistPadAccent", "GistPadComments"],
      resources: [.process("Resources")]),
    .target(
      name: "GistPadIntelligence", dependencies: ["GistPadEditor"],
      resources: [.process("Resources")]),
    .target(
      name: "GistPadInterface", dependencies: ["GistPadAccent", "GistPadComments", "GistPadSync"],
      exclude: ["README.md"], resources: [.process("Resources")]),
    .target(
      name: "GistPadPlatform", dependencies: ["GistPadSync", "GistPadAccent"],
      exclude: ["README.md"]),
    .target(
      name: "GistPadPreview", dependencies: ["GistPadAccent", "GistPadComments"],
      resources: [.copy("Resources/Web"), .copy("Resources/Fixtures")]),
    .target(
      name: "GistPadSync",
      dependencies: ["GistPadComments", .product(name: "Auth", package: "supabase-swift")],
      exclude: ["README.md"]),

    .testTarget(name: "GistPadAccentTests", dependencies: ["GistPadAccent"]),
    .testTarget(
      name: "GistPadCommentsTests", dependencies: ["GistPadComments"],
      resources: [.copy("Fixtures")]),
    .testTarget(name: "GistPadEditorTests", dependencies: ["GistPadEditor", "GistPadComments"]),
    .testTarget(name: "GistPadIntelligenceTests", dependencies: ["GistPadIntelligence"]),
    .testTarget(name: "GistPadInterfaceTests", dependencies: ["GistPadInterface"]),
    .testTarget(name: "GistPadPlatformTests", dependencies: ["GistPadPlatform", "GistPadSync"]),
    .testTarget(
      name: "GistPadPreviewTests",
      dependencies: ["GistPadPreview", "GistPadAccent", "GistPadComments"]),
    .testTarget(name: "GistPadSyncTests", dependencies: ["GistPadSync", "GistPadComments"]),
  ]
)
