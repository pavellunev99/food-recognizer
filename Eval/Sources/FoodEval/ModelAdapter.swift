import CoreImage
import Foundation
import MLX
import MLXLMCommon
import MLXVLM
import MLXHuggingFace
import HuggingFace
import Tokenizers

// MARK: - EvalModel

/// Какую VLM-модель загружать для оценочного прогона. Mapping repoId →
/// `VLMRegistry` дублирует production `LocalVLMModel.swift` (намеренно: app-
/// таргет в SwiftPM не подключается, см. план Wave 2). При апдейте production
/// модели — синхронизируй сюда вручную.
enum EvalModel: String {
    case qwen2 = "qwen2"
    case qwen3 = "qwen3"

    var displayName: String {
        switch self {
        case .qwen2: return "Qwen2-VL 2B Instruct (4-bit)"
        case .qwen3: return "Qwen3-VL 4B Instruct (4-bit)"
        }
    }

    /// Совпадает с `LocalVLMModel.repoId` в production.
    var repoId: String {
        switch self {
        case .qwen2: return "mlx-community/Qwen2-VL-2B-Instruct-4bit"
        case .qwen3: return "mlx-community/Qwen3-VL-4B-Instruct-4bit"
        }
    }

    var configuration: ModelConfiguration {
        switch self {
        case .qwen2: return VLMRegistry.qwen2VL2BInstruct4Bit
        case .qwen3: return VLMRegistry.qwen3VL4BInstruct4Bit
        }
    }

    /// Параметры сэмплинга — зеркалят `LocalVLMModel.generationConfig`.
    var generation: (temperature: Float, topP: Float) {
        switch self {
        case .qwen2: return (0.35, 0.9)
        case .qwen3: return (0.35, 0.9)
        }
    }
}

// MARK: - ModelAdapter

/// Тонкий inference-путь для eval-tool. Не подключает production
/// `LocalLLMService.swift` (он завязан на UIKit, AppLog, NotificationCenter,
/// Asset Pack provider — слишком много iOS-only обвязки). Вместо этого
/// повторяет ту же связку MLX API, что использует production
/// (`VLMRegistry` config + `loadModelContainer` + `ChatSession.respond`),
/// без few-shot/retry-логики — это уровень оценки, не runtime app.
///
/// Один контейнер на жизнь процесса. Не thread-safe, но eval-tool
/// последовательный (одна картинка за раз).
final class ModelAdapter {
    private let model: EvalModel
    private var container: ModelContainer?

    init(model: EvalModel) {
        self.model = model
    }

    /// Lazy-load. Первый вызов скачивает веса с HF (~1.2 GB для qwen2, ~2.6 GB
    /// для qwen3) и мапит их в Metal через `loadModelContainer`. На macOS с
    /// готовым metallib bundle (см. scripts/prepare-metallib.sh) — успешен.
    func ensureLoaded() async throws {
        if container != nil { return }
        FileHandle.standardError.write(
            Data("[adapter] loading \(model.displayName) (\(model.repoId))…\n".utf8)
        )
        // MLX cache limit зеркалит production (LocalLLMService.swift:135).
        MLX.Memory.cacheLimit = 20 * 1024 * 1024

        let resolved = try await resolve(
            configuration: model.configuration,
            from: #hubDownloader(),
            useLatest: false,
            progressHandler: { progress in
                let pct = Int(progress.fractionCompleted * 100)
                FileHandle.standardError.write(
                    Data("[adapter] download \(pct)%\r".utf8)
                )
            }
        )
        FileHandle.standardError.write(Data("\n[adapter] loading container…\n".utf8))
        let loaded = try await loadModelContainer(
            from: resolved.modelDirectory,
            using: #huggingFaceTokenizerLoader()
        )
        self.container = loaded
        FileHandle.standardError.write(Data("[adapter] container ready\n".utf8))
    }

    /// Один inference-запрос. Параметры (temperature/topP) — production-defaults.
    /// `systemPrompt` подставляется как есть, `userPrompt` — message от user.
    /// Без few-shot/retry.
    func analyze(
        ciImage: CIImage,
        systemPrompt: String,
        userPrompt: String
    ) async throws -> String {
        try await ensureLoaded()
        guard let container = self.container else {
            throw ModelAdapterError.containerMissing
        }
        let (temperature, topP) = model.generation
        let session = ChatSession(
            container,
            instructions: systemPrompt,
            generateParameters: GenerateParameters(temperature: temperature, topP: topP)
        )
        return try await session.respond(to: userPrompt, image: .ciImage(ciImage))
    }
}

enum ModelAdapterError: LocalizedError {
    case containerMissing
    case imageDecodeFailed(URL)

    var errorDescription: String? {
        switch self {
        case .containerMissing:
            return "Model container not loaded — ensureLoaded() did not complete."
        case .imageDecodeFailed(let url):
            return "Failed to decode image at \(url.path)."
        }
    }
}

// MARK: - Image loading

/// Загружает JPG/PNG с диска в `CIImage`. EXIF-ориентация применяется
/// автоматически (`CIImage(contentsOf:)` уважает orientation tag).
func loadCIImage(at path: String) throws -> CIImage {
    let url = URL(fileURLWithPath: path)
    guard FileManager.default.fileExists(atPath: url.path) else {
        throw ModelAdapterError.imageDecodeFailed(url)
    }
    guard let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
        throw ModelAdapterError.imageDecodeFailed(url)
    }
    return image
}
