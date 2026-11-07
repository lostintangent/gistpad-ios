// swift-tools-version: 6.2
import PackageDescription

// GistPad.xcodeproj builds the app and its extensions from Sources/App and Sources/Extensions,
// and links these modules. Shared is the core that features build on.
let shared = ["Accent", "Comments", "Store"]
let features = ["Editor", "Intelligence", "Model", "Platform", "Preview", "Screens"]

let package = Package(
  name: "GistPad",
  platforms: [.iOS("27.2"), .macOS("27.0")],
  products: (shared + features).map { .library(name: $0, targets: [$0]) },
  dependencies: [
    .package(url: "https://github.com/supabase/supabase-swift.git", exact: "2.55.4")
  ],
  targets: [
    .target(name: "Accent", path: "Sources/Shared/Accent"),
    .target(name: "Comments", path: "Sources/Shared/Comments", exclude: ["README.md"]),
    .target(
      name: "Store", dependencies: ["Comments", .product(name: "Auth", package: "supabase-swift")],
      path: "Sources/Shared/Store", exclude: ["README.md"]),

    .target(
      name: "Editor", dependencies: ["Accent", "Comments"], path: "Sources/Features/Editor",
      resources: [.process("Resources")]),
    .target(
      name: "Intelligence", dependencies: ["Editor"], path: "Sources/Features/Intelligence",
      resources: [.process("Resources")]),
    .target(
      name: "Screens", dependencies: ["Accent", "Comments", "Store"],
      path: "Sources/Features/Screens", exclude: ["README.md"], resources: [.process("Resources")]),
    .target(
      name: "Model", dependencies: ["Comments", "Editor", "Screens", "Store"],
      path: "Sources/Features/Model", exclude: ["README.md"]),
    .target(
      name: "Platform", dependencies: ["Store", "Accent"], path: "Sources/Features/Platform",
      exclude: ["README.md"]),
    .target(
      name: "Preview", dependencies: ["Accent", "Comments"], path: "Sources/Features/Preview",
      resources: [.copy("Resources/Web"), .copy("Resources/Fixtures")]),

    .testTarget(name: "AccentTests", dependencies: ["Accent"], path: "Tests/Shared/AccentTests"),
    .testTarget(
      name: "CommentsTests", dependencies: ["Comments"], path: "Tests/Shared/CommentsTests",
      resources: [.copy("Fixtures")]),
    .testTarget(
      name: "StoreTests", dependencies: ["Store", "Comments"], path: "Tests/Shared/StoreTests"),

    .testTarget(
      name: "EditorTests", dependencies: ["Editor", "Comments"], path: "Tests/Features/EditorTests"),
    .testTarget(
      name: "IntelligenceTests", dependencies: ["Intelligence"],
      path: "Tests/Features/IntelligenceTests"),
    .testTarget(
      name: "ScreensTests", dependencies: ["Screens"], path: "Tests/Features/ScreensTests"),
    .testTarget(
      name: "ModelTests", dependencies: ["Model", "Editor", "Screens", "Store"],
      path: "Tests/Features/ModelTests"),
    .testTarget(
      name: "PlatformTests", dependencies: ["Platform", "Store", "Editor"],
      path: "Tests/Features/PlatformTests"),
    .testTarget(
      name: "PreviewTests", dependencies: ["Preview", "Accent", "Comments"],
      path: "Tests/Features/PreviewTests"),

    // The on-device Intelligence eval, which reaches the pipeline through `package` access.
    .executableTarget(
      name: "IntelligenceEval", dependencies: ["Intelligence"],
      path: "scripts/intelligence-eval/Sources/IntelligenceEval"),
    .testTarget(
      name: "IntelligenceEvalTests", dependencies: ["IntelligenceEval"],
      path: "scripts/intelligence-eval/Tests/IntelligenceEvalTests"),
  ]
)
