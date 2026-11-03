// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TakiKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        // Pure logic shared by the app and the keyboard extension. No heavy dependencies.
        .library(name: "TakiCore", targets: ["TakiCore"]),
        // ASR + cleanup. Main app only — never link this into the keyboard (memory limit).
        .library(name: "TakiEngine", targets: ["TakiEngine"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.2"),
    ],
    targets: [
        .target(name: "TakiCore"),
        .target(
            name: "TakiEngine",
            dependencies: ["TakiCore", .product(name: "FluidAudio", package: "FluidAudio")]
        ),
        .testTarget(name: "TakiCoreTests", dependencies: ["TakiCore"]),
    ],
    swiftLanguageModes: [.v6]
)
