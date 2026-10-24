// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "GistPadSync",
    platforms: [.iOS("27.1"), .macOS(.v15)],
    products: [.library(name: "GistPadSync", targets: ["GistPadSync"])],
    dependencies: [
        .package(url: "https://github.com/supabase/supabase-swift.git", exact: "2.55.4")
    ],
    targets: [
        .target(
            name: "GistPadSync",
            dependencies: [.product(name: "Auth", package: "supabase-swift")]
        ),
        .testTarget(name: "GistPadSyncTests", dependencies: ["GistPadSync"])
    ]
)
