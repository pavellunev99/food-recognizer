// swift-tools-version: 6.1
import PackageDescription

// MARK: - FoodEval (macOS-only)
//
// Изолированный SwiftPM executable для оффлайн-оценки качества VLM
// (см. план в .claude/plans/vlm-eval-harness.md). Не входит в Xcode-проект
// FoodRecognizer; ревизии MLX / mlx-swift-lm / swift-huggingface / swift-transformers
// зеркалят те, что зафиксированы в
// `FoodRecognizer.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.
//
// Цель Wave 1 — gate: подтвердить, что эти пакеты собираются под macOS 14+
// как чистый SwiftPM-таргет (без UIKit / iOS-only API).
let package = Package(
    name: "FoodEval",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "FoodEval", targets: ["FoodEval"]),
    ],
    dependencies: [
        // Те же ревизии, что в Package.resolved app'а.
        .package(
            url: "https://github.com/ml-explore/mlx-swift",
            exact: "0.31.3"
        ),
        .package(
            url: "https://github.com/ml-explore/mlx-swift-lm.git",
            branch: "main"
        ),
        .package(
            url: "https://github.com/huggingface/swift-huggingface.git",
            branch: "main"
        ),
        .package(
            url: "https://github.com/huggingface/swift-transformers.git",
            branch: "main"
        ),
        .package(
            url: "https://github.com/apple/swift-argument-parser",
            from: "1.5.0"
        ),
    ],
    targets: [
        .executableTarget(
            name: "FoodEval",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Transformers", package: "swift-transformers"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/FoodEval"
        ),
        .testTarget(
            name: "FoodEvalTests",
            dependencies: [
                "FoodEval",
            ],
            path: "Tests/FoodEvalTests"
        ),
    ]
)
