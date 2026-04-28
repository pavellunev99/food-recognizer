// swift-tools-version: 6.1
import PackageDescription

// MARK: - NutriLensEval (macOS-only)
//
// Изолированный SwiftPM executable для оффлайн-оценки качества VLM
// (см. план в .claude/plans/vlm-eval-harness.md). Не входит в Xcode-проект
// NutriLens; ревизии MLX / mlx-swift-lm / swift-huggingface / swift-transformers
// зеркалят те, что зафиксированы в
// `NutriLens.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.
//
// Цель Wave 1 — gate: подтвердить, что эти пакеты собираются под macOS 14+
// как чистый SwiftPM-таргет (без UIKit / iOS-only API).
let package = Package(
    name: "NutriLensEval",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "NutriLensEval", targets: ["NutriLensEval"]),
    ],
    dependencies: [
        // Те же ревизии, что в Package.resolved app'а.
        .package(
            url: "https://github.com/ml-explore/mlx-swift",
            exact: "0.31.3"
        ),
        .package(
            url: "https://github.com/ml-explore/mlx-swift-lm.git",
            revision: "99a2b1c55637a66abfcbe220dd1bf881f805b613"
        ),
        .package(
            url: "https://github.com/huggingface/swift-huggingface.git",
            revision: "b721959445b617d0bf03910b2b4aced345fd93bf"
        ),
        .package(
            url: "https://github.com/huggingface/swift-transformers.git",
            revision: "7f1f9d06c8fc789936a4cca2affe96528e99f47d"
        ),
        .package(
            url: "https://github.com/apple/swift-argument-parser",
            from: "1.5.0"
        ),
    ],
    targets: [
        .executableTarget(
            name: "NutriLensEval",
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
            path: "Sources/NutriLensEval"
        ),
        .testTarget(
            name: "NutriLensEvalTests",
            dependencies: [
                "NutriLensEval",
            ],
            path: "Tests/NutriLensEvalTests"
        ),
    ]
)
