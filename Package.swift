// swift-tools-version: 6.2
import PackageDescription

// GistPad.xcodeproj builds the app and its extensions from Sources/App and Sources/Extensions,
// and links these modules. Shared is the core that features build on.
let shared = ["Appearance", "Comments", "Store"]
let features = ["Editor", "Intelligence", "Model", "Platform", "Preview", "Screens"]
// The UI modules and their tests run on the main actor by default, like Xcode's app template.
let mainActor: [SwiftSetting] = [.defaultIsolation(MainActor.self)]

let package = Package(
    name: "GistPad",
    platforms: [.iOS("27.2"), .macOS("27.0")],
    products: (shared + features).map { .library(name: $0, targets: [$0]) },
    dependencies: [
        .package(url: "https://github.com/supabase/supabase-swift.git", exact: "2.55.4")
    ],
    targets: [
        .target(name: "Appearance", path: "Sources/Shared/Appearance"),
        .target(name: "Comments", path: "Sources/Shared/Comments", exclude: ["README.md"]),
        .target(
            name: "Store", dependencies: ["Comments", .product(name: "Auth", package: "supabase-swift")],
            path: "Sources/Shared/Store", exclude: ["README.md"]),

        .target(
            name: "Editor", dependencies: ["Appearance", "Comments"], path: "Sources/Features/Editor",
            resources: [.process("Resources")], swiftSettings: mainActor),
        .target(
            name: "Intelligence", dependencies: ["Editor"], path: "Sources/Features/Intelligence",
            resources: [.process("Resources")], swiftSettings: mainActor),
        .target(
            name: "Screens", dependencies: ["Appearance", "Store"],
            path: "Sources/Features/Screens", exclude: ["README.md"], resources: [.process("Resources")],
            swiftSettings: mainActor),
        .target(
            name: "Model", dependencies: ["Comments", "Editor", "Screens", "Store"],
            path: "Sources/Features/Model", exclude: ["README.md"], swiftSettings: mainActor),
        .target(
            name: "Platform", dependencies: ["Store", "Appearance"], path: "Sources/Features/Platform",
            exclude: ["README.md"]),
        .target(
            name: "Preview", dependencies: ["Appearance", "Comments"], path: "Sources/Features/Preview",
            resources: [.copy("Resources/Web"), .process("Resources/Localizable.xcstrings")],
            swiftSettings: mainActor),

        .testTarget(name: "AppearanceTests", dependencies: ["Appearance"], path: "Tests/Shared/AppearanceTests"),
        .testTarget(
            name: "CommentsTests", dependencies: ["Comments"], path: "Tests/Shared/CommentsTests",
            resources: [.copy("Fixtures")]),
        .testTarget(
            name: "StoreTests", dependencies: ["Store", "Comments"], path: "Tests/Shared/StoreTests"),

        .testTarget(
            name: "EditorTests", dependencies: ["Editor", "Comments"], path: "Tests/Features/EditorTests",
            swiftSettings: mainActor),
        .testTarget(
            name: "IntelligenceTests", dependencies: ["Intelligence"],
            path: "Tests/Features/IntelligenceTests", swiftSettings: mainActor),
        .testTarget(
            name: "ScreensTests", dependencies: ["Screens"], path: "Tests/Features/ScreensTests",
            swiftSettings: mainActor),
        .testTarget(
            name: "ModelTests", dependencies: ["Model", "Editor", "Screens", "Store"],
            path: "Tests/Features/ModelTests", swiftSettings: mainActor),
        .testTarget(
            name: "PlatformTests", dependencies: ["Platform", "Store", "Editor"],
            path: "Tests/Features/PlatformTests"),
        .testTarget(
            name: "PreviewTests", dependencies: ["Preview", "Appearance", "Comments"],
            path: "Tests/Features/PreviewTests", swiftSettings: mainActor),

        // The on-device Intelligence eval, which reaches the pipeline through `package` access.
        .executableTarget(
            name: "IntelligenceEval", dependencies: ["Intelligence"],
            path: "scripts/intelligence-eval/Sources/IntelligenceEval"),
        .testTarget(
            name: "IntelligenceEvalTests", dependencies: ["IntelligenceEval"],
            path: "scripts/intelligence-eval/Tests/IntelligenceEvalTests"),
    ]
)

// Every module takes Swift's approachable concurrency, like Xcode's project template. The modules
// have to agree, because it changes how their async function types are mangled.
for target in package.targets {
    target.swiftSettings = (target.swiftSettings ?? []) + [
        .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
        .enableUpcomingFeature("InferIsolatedConformances"),
    ]
}
