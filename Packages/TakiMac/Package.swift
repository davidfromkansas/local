// swift-tools-version: 6.2
import PackageDescription

// The Mac app's speech + cleanup engine: Qwen3-ASR and a Qwen LLM on MLX (Apple GPU). macOS only,
// so the iOS targets never build it.
let package = Package(
    name: "TakiMac",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "TakiMacEngine", targets: ["TakiMacEngine"]),
    ],
    dependencies: [
        .package(path: "../TakiKit"),
        // No tagged releases; pinned to the commit that was benchmarked.
        .package(url: "https://github.com/soniqo/speech-swift", revision: "468db5f29e1304a140e3b8d9bb9ec8f2162c13bc"),
        .package(url: "https://github.com/ml-explore/mlx-swift", from: "0.31.4"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.31.4"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.1.6"),
    ],
    targets: [
        .target(
            name: "TakiMacEngine",
            dependencies: [
                .product(name: "TakiCore", package: "TakiKit"),
                .product(name: "Qwen3ASR", package: "speech-swift"),
                .product(name: "AudioCommon", package: "speech-swift"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
