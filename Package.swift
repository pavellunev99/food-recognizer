// swift-tools-version: 6.1
import PackageDescription

// MARK: - FoodRecognizer
//
// Standalone SPM модуль для распознавания еды по фото через локальную VLM
// (Qwen2-VL-2B / Qwen3-VL-4B через MLX). Используется как dependency в Nutrilens
// iOS-приложении, а также как self-contained библиотека для evaluation
// инструмента (см. ./Eval/).
//
// Модуль НЕ зависит от UIKit на macOS-таргете: вход — CIImage. На iOS — есть
// удобный UIImage entry-point под `#if canImport(UIKit)`.
//
// Ревизии MLX / mlx-swift-lm / swift-huggingface / swift-transformers зеркалят
// те, что зафиксированы в Nutrilens.xcodeproj/.../Package.resolved.

let package = Package(
    name: "FoodRecognizer",
    platforms: [
        // Главная цель — iOS 17+ (для mobile app). macOS 14+ заявлен только
        // ради SPM dep-resolve (MLX/Transformers требуют macOS 14+). На macOS
        // public surface FoodRecognizer пуст — UIKit-зависимые типы обёрнуты
        // `#if canImport(UIKit)`. Eval-инструмент (./Eval/) — отдельный SwiftPM
        // package под macOS, работает с MLX напрямую через CIImage.
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "FoodRecognizer", targets: ["FoodRecognizer"]),
    ],
    dependencies: [
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
    ],
    targets: [
        .target(
            name: "FoodRecognizer",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Transformers", package: "swift-transformers"),
            ],
            path: "Sources/FoodRecognizer",
            swiftSettings: [
                // Swift 5 mode для совместимости с существующим iOS-кодом, который
                // использует NSObjectProtocol в `withLock` (на macOS Swift 6
                // strict concurrency это требует @unchecked Sendable). Этап B —
                // ужесточить до Swift 6 после рефакторинга lock-обёрток.
                .swiftLanguageMode(.v5),
            ]
        ),
        .testTarget(
            name: "FoodRecognizerTests",
            dependencies: ["FoodRecognizer"],
            path: "Tests/FoodRecognizerTests"
        ),
    ]
)
