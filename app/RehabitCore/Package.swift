// swift-tools-version:5.9
import PackageDescription

// Everything the app knows that is not a screen: records, storage, the tissue
// ledger and the pain follow-up schedule. It imports nothing from Apple beyond
// Foundation, so it builds and is tested on Linux and can be reused on Android.
let package = Package(
    name: "RehabitCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "RehabitCore", targets: ["RehabitCore"])],
    targets: [
        .systemLibrary(name: "CSQLite", providers: [.apt(["libsqlite3-dev"])]),
        .target(
            name: "RehabitCore",
            dependencies: [.target(name: "CSQLite", condition: .when(platforms: [.linux, .android]))],
            resources: [.process("Resources")]),
        .testTarget(
            name: "RehabitCoreTests",
            dependencies: ["RehabitCore"],
            resources: [.copy("Fixtures")]),
    ]
)
