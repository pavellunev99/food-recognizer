#if canImport(UIKit)

import Foundation
#if canImport(UIKit)
import UIKit
#endif
import CoreImage
import os
#if !targetEnvironment(simulator)
import MLX
import MLXLMCommon
import MLXVLM
import MLXHuggingFace
import HuggingFace
import Tokenizers
#endif

/// Сервис локальной VLM для анализа еды на базе MLX Swift (Qwen2-VL-2B-Instruct-4bit).
///
/// В iOS Simulator Metal-совместимый GPU недоступен — используем стабильный мок.
///
/// `@unchecked Sendable`: `container` мутируется только внутри `initialize()` /
/// `cleanup()`, которые вызываются строго последовательно из главного актора
/// (`AppController.initializeServices`). После `initialize()` контейнер readonly.
public nonisolated final class LocalLLMService: LLMServiceProtocol, @unchecked Sendable {

    // MARK: - Notifications

    /// Прогресс скачивания модели (0.0 … 1.0). Передаётся через NotificationCenter.
    public static let progressNotification = Notification.Name("LocalLLMService.loadingProgress")

    // MARK: - State

    /// Кэш in-flight задачи `initialize()`. Если пользователь нажал Test Connection
    /// во время первичной загрузки модели, второй вызов не стартует параллельный
    /// download, а ждёт завершения первого. Доступ к полю — из @MainActor контекста
    /// (AppController.initializeServices + SettingsViewModel.testLLMConnection).
    private var initializationTask: Task<Void, Error>?

    /// Holder для critical-state (`container`, `selectedModel`, `initialized`).
    /// Actor-изоляция гарантирует:
    ///  - swap и inference не пересекаются (inflight-counter с draining перед swap);
    ///  - `MLX.Memory.clearCache()` зовётся ТОЛЬКО когда нет активной inference,
    ///    т.е. не сносит KV/буферы у параллельной генерации;
    ///  - доступ к `container` без race — старый контейнер deinit-ится после swap,
    ///    но только когда все inference, державшие на него ссылку, отпустили.
    private let holder: ModelHolder

    /// Снимок состояния для нон-async доступа (`isInitialized`, `modelName` в
    /// `LLMServiceProtocol` — не async). Holder обновляет этот снимок атомарно
    /// под unfair-lock'ом в каждой mutator-операции.
    fileprivate struct Snapshot: Sendable {
        var initialized: Bool
        var selectedModel: LocalVLMModel
    }
    fileprivate let snapshot: OSAllocatedUnfairLock<Snapshot>

    /// UserDefaults-флаг: была ли хотя бы одна успешная inference на heavy
    /// после переключения. Используется координатором, чтобы решить — можно
    /// ли удалить bootstrap-веса с диска.
    private static let firstHeavyInferenceKey = "LocalLLMService.firstHeavyInferenceCompleted"
    /// Отдельный флаг: HF-кеш bootstrap'а уже почищен. Вынесен из
    /// `firstHeavyInferenceKey`, чтобы при ошибке cleanup'а на первом heavy
    /// мы могли повторить попытку при следующей успешной prod-inference.
    private static let bootstrapHFPurgedKey = "LocalLLMService.bootstrapHFPurged"

    public init(model: LocalVLMModel) {
        let initial = Snapshot(initialized: false, selectedModel: model)
        let lock = OSAllocatedUnfairLock(initialState: initial)
        self.snapshot = lock
        self.holder = ModelHolder(snapshot: lock)
    }

    /// Текущая активная модель — читается координатором.
    public var currentModel: LocalVLMModel {
        snapshot.withLock { $0.selectedModel }
    }

    public var isInitialized: Bool { snapshot.withLock { $0.initialized } }

    public var modelName: String {
        #if targetEnvironment(simulator)
        return "Simulator Mock VLM"
        #else
        return "\(snapshot.withLock { $0.selectedModel }.displayName) (MLX)"
        #endif
    }

    // MARK: - Initialization

    public func initialize() async throws {
        if isInitialized { return }
        if let existing = initializationTask {
            try await existing.value
            return
        }
        let task = Task { try await self.performInitialize() }
        initializationTask = task
        do {
            try await task.value
            initializationTask = nil
        } catch {
            initializationTask = nil
            throw error
        }
    }

    private func performInitialize() async throws {
        #if !targetEnvironment(simulator)
        // Ставим 0% сразу, чтобы UI-индикатор (ModelDownloadState) появился
        // ещё до того как Asset Pack / HF начнут слать реальный прогресс —
        // иначе юзер видит чёрный экран 10-30 сек, пока HF резолвит metadata.
        //
        // НО: если модель уже в HF-кеше, resolve() отрабатывает мгновенно, а
        // loadModelContainer (mmap весов в Metal) занимает 5-30 сек. Всё это
        // время банер висит на 0% — отправлять 0% нет смысла. Сразу шлём 1.0,
        // чтобы любой уже подписанный observer не залип на 0%.
        if Self.isModelLikelyCached() {
            NotificationCenter.default.post(
                name: Self.progressNotification,
                object: nil,
                userInfo: ["fraction": 1.0]
            )
        } else {
            NotificationCenter.default.post(
                name: Self.progressNotification,
                object: nil,
                userInfo: ["fraction": 0.0]
            )
        }
        #endif

        #if targetEnvironment(simulator)
        AppLog.info("[Simulator] LocalLLMService использует мок-инференс", category: .llm)
        await holder.setLoaded(model: currentModel)
        #else
        let model = currentModel
        AppLog.info("Загрузка MLX VLM (\(model.displayName))", category: .llm)
        MLX.Memory.cacheLimit = 20 * 1024 * 1024

        // 1) Пробуем локальный Asset Pack (iOS 26+, App Store hosting).
        if let localURL = await ModelAssetProvider.ensureAvailable(
            modelRoot: model.assetPackModelRoot,
            progress: { fraction in
                NotificationCenter.default.post(
                    name: Self.progressNotification,
                    object: nil,
                    userInfo: ["fraction": fraction]
                )
            }
        ) {
            do {
                // loadModelContainer мапит веса в GPU через Metal — в background
                // это кидает std::runtime_error, который Swift не ловит. Ждём
                // возврата в foreground.
                await Self.waitUntilActive()
                let loaded = try await loadModelContainer(
                    from: localURL,
                    using: #huggingFaceTokenizerLoader()
                )
                await holder.setLoaded(container: loaded, model: model)
                NotificationCenter.default.post(
                    name: Self.progressNotification,
                    object: nil,
                    userInfo: ["fraction": 1.0]
                )
                AppLog.info("MLX VLM загружена из Asset Pack", category: .llm)
                return
            } catch {
                AppLog.error(
                    "Asset Pack загружен, но ModelContainer не собрался — fallback на HF: \(error.localizedDescription)",
                    category: .llm
                )
            }
        }

        // 2) Fallback: скачивание с HuggingFace.
        // swift-huggingface глючит с parent.fractionCompleted: DownloadProgressDelegate
        // перезаписывает child.totalUnitCount после создания, что ломает
        // parent↔child aggregation в NSProgress. В результате handler сообщает
        // только "% завершённых файлов" — стоит на ~1% всё время пока
        // model.safetensors (3.5 ГБ) не докачается целиком.
        // Обход: сами опрашиваем размер HF-кеша на диске раз в секунду.
        let totalBox = TotalBox()
        let samplingTask = Task.detached {
            let baseline = Self.hfCacheSize()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let total = totalBox.value, total > 0 else { continue }
                let downloaded = max(0, Self.hfCacheSize() - baseline)
                // Когда модель уже в кеше, resolve() ничего не качает, но
                // progressHandler всё равно может выставить totalBox. Без этой
                // отсечки каждую секунду летит fraction=0 и банер застревает
                // на 0% всё время пока loadModelContainer мапит веса.
                guard downloaded > 0 else { continue }
                let fraction = min(1.0, Double(downloaded) / Double(total))
                NotificationCenter.default.post(
                    name: Self.progressNotification,
                    object: nil,
                    userInfo: ["fraction": fraction]
                )
            }
        }
        defer { samplingTask.cancel() }

        // Разделяем скачивание и загрузку в GPU:
        // 1) resolve — только скачивание файлов через URLSession (background-safe)
        // 2) ждём foreground
        // 3) loadModelContainer(from:) — mmap весов через Metal (требует foreground)
        // Иначе #huggingFaceLoadModelContainer делает оба шага атомарно и крашит
        // если юзер свернул app пока шла загрузка.
        do {
            let resolved = try await resolve(
                configuration: Self.registryConfiguration(for: model),
                from: #hubDownloader(),
                useLatest: false,
                progressHandler: { progress in
                    if progress.totalUnitCount > 1, totalBox.value == nil {
                        totalBox.value = progress.totalUnitCount
                    }
                }
            )
            await Self.waitUntilActive()
            let loaded = try await loadModelContainer(
                from: resolved.modelDirectory,
                using: #huggingFaceTokenizerLoader()
            )
            await holder.setLoaded(container: loaded, model: model)
            NotificationCenter.default.post(
                name: Self.progressNotification,
                object: nil,
                userInfo: ["fraction": 1.0]
            )
            AppLog.info("MLX VLM загружена с HuggingFace", category: .llm)
        } catch {
            throw LLMServiceError.processingFailed(String(localized: "error_failed_load_model \(error.localizedDescription)"))
        }
        #endif
    }

    // MARK: - Request Handling

    public func sendRequest(_ request: LLMRequest) async throws -> LLMResponse {
        guard isInitialized else {
            throw LLMServiceError.modelNotLoaded
        }

        let content: String

        switch request.type {
        case .textAnalysis(let text):
            content = try await processTextAnalysis(text)

        case .imageAnalysis(let image, let prompt):
            content = try await processImageAnalysis(
                image,
                prompt: prompt,
                isRetry: request.isRetry,
                systemPromptOverride: request.systemPromptOverride
            )

        case .nutritionExtraction(let text):
            content = try await processTextAnalysis(text)
        }

        return LLMResponse(
            content: content,
            finishReason: "stop",
            model: modelName,
            tokensUsed: nil
        )
    }

    // MARK: - Private Processing

    private func processTextAnalysis(_ text: String) async throws -> String {
        mockNutritionJSON(name: text.isEmpty ? String(localized: "nutrition_meal") : text)
    }

    #if canImport(UIKit)
    private func processImageAnalysis(
        _ image: UIImage,
        prompt: String?,
        isRetry: Bool,
        systemPromptOverride: String? = nil
    ) async throws -> String {
        #if targetEnvironment(simulator)
        try await Task.sleep(nanoseconds: 800_000_000)
        return mockNutritionJSON(name: String(localized: "nutrition_chicken_salad_demo"))
        #else
        // EXIF-нормализация и downscale до 1024px по длинной стороне делаются
        // через UIKit-renderer (быстрее чем CoreImage для типичных JPEG с
        // камеры). На macOS-таргете (eval-tool) эту ветку не вызываем —
        // там input уже CIImage, идём напрямую в `analyzeFood(ciImage:)`.
        guard let normalized = Self.preparedImage(from: image),
              let cgImage = normalized.cgImage else {
            throw LLMServiceError.invalidInput
        }
        let ciImage = CIImage(cgImage: cgImage)
        return try await analyzeFood(
            ciImage: ciImage,
            userPrompt: prompt,
            systemPromptOverride: systemPromptOverride,
            isRetry: isRetry
        )
        #endif
    }
    #endif

    /// Платформо-нейтральный inference-путь. UIKit-зависимый
    /// `processImageAnalysis(_ image: UIImage, ...)` делегирует сюда после
    /// EXIF-нормализации и downscale. Eval-tool (macOS, без UIKit) вызывает
    /// этот метод напрямую с уже подготовленным `CIImage`.
    ///
    /// Семантика промтов:
    ///   - `systemPromptOverride != nil` — системный промт берётся as-is из
    ///     override, логика few-shot/retry-варианта в `LocalVLMModel` не
    ///     запускается. Используется eval-tool'ом для итерации над промтом
    ///     без пересборки app.
    ///   - иначе если `userPrompt != nil` — caller (foodNameOnly-запрос)
    ///     передал всю инструкцию через user-message, системный контекст не
    ///     навязываем.
    ///   - иначе (default app path) — берём `model.nutritionSystemPrompt(retry:)`.
    ///
    /// App никогда не выставляет `systemPromptOverride` — поведение app не меняется.
    public func analyzeFood(
        ciImage: CIImage,
        userPrompt: String?,
        systemPromptOverride: String?,
        isRetry: Bool
    ) async throws -> String {
        #if targetEnvironment(simulator)
        try await Task.sleep(nanoseconds: 800_000_000)
        return mockNutritionJSON(name: String(localized: "nutrition_chicken_salad_demo"))
        #else
        // Acquire bumps holder.inflight — пока ссылка взята, swap/clear ждут
        // дренаж и не дёрнут MLX.Memory.clearCache() из-под идущей inference.
        guard let container = await holder.acquire() else {
            throw LLMServiceError.modelNotLoaded
        }

        let model = currentModel
        let resolvedUserPrompt: String
        let resolvedSystemPrompt: String
        if let systemPromptOverride {
            // Eval-режим: системный промт зафиксирован caller'ом, user-message
            // оставляем дефолтным либо берём caller-значение.
            resolvedUserPrompt = userPrompt ?? "Analyze the meal in this photo and estimate nutrition facts."
            resolvedSystemPrompt = systemPromptOverride
        } else if let userPrompt {
            // foodNameOnly-путь: caller сам передал всю инструкцию.
            resolvedUserPrompt = userPrompt
            resolvedSystemPrompt = ""
        } else {
            resolvedUserPrompt = "Analyze the meal in this photo and estimate nutrition facts."
            resolvedSystemPrompt = model.nutritionSystemPrompt(retry: isRetry)
        }

        // iOS блокирует Metal/GPU в background — MLX при попытке сабмитить
        // commands кидает std::runtime_error из C++, который Swift не поймает,
        // и app крашится. Ждём возврата приложения в foreground перед стартом
        // inference. На macOS waitUntilActive — no-op (см. реализацию).
        await Self.waitUntilActive()

        let config = model.generationConfig
        let temperature: Float = isRetry ? config.retryTemperature : config.temperature
        AppLog.info(
            "VLM inference: model=\(model.displayName) retry=\(isRetry) temp=\(temperature) topP=\(config.topP)",
            category: .llm
        )
        let session = ChatSession(
            container,
            instructions: resolvedSystemPrompt,
            generateParameters: GenerateParameters(temperature: temperature, topP: config.topP)
        )

        do {
            let result = try await session.respond(to: resolvedUserPrompt, image: .ciImage(ciImage))
            await holder.release()
            return result
        } catch {
            await holder.release()
            // MLX иногда кидает SIGABRT во вложенном стеке при невалидном
            // изображении — перехватить это в Swift нельзя, но обычные
            // ошибки токенизатора/декодера ловим сюда.
            throw LLMServiceError.processingFailed(String(localized: "error_failed_analyze_photo \(error.localizedDescription)"))
        }
        #endif
    }

    #if canImport(UIKit)
    /// Нормализует ориентацию (EXIF → .up) и даунскейлит до 1024px по длинной
    /// стороне. Без этого VLM видит портретные фото повёрнутыми, а крупные
    /// изображения увеличивают разброс декодирования у 2B-модели.
    private static func preparedImage(from image: UIImage) -> UIImage? {
        let maxSide: CGFloat = 1024
        let size = image.size
        let longest = max(size.width, size.height)
        let scale = longest > maxSide ? maxSide / longest : 1.0
        let targetSize = CGSize(width: size.width * scale, height: size.height * scale)

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }
    #endif

    // MARK: - Model Registry

    #if !targetEnvironment(simulator)
    private static func registryConfiguration(for model: LocalVLMModel) -> ModelConfiguration {
        switch model {
        case .qwen2VL_2B:
            return VLMRegistry.qwen2VL2BInstruct4Bit
        case .qwen3VL_4B:
            // mlx-swift-lm с версии, где появился `Qwen3VL.swift`, регистрирует
            // нативную конфигурацию в `VLMRegistry`. Используем её — иначе
            // loader пытается читать веса Qwen3-VL по схеме Qwen2-VL и
            // получаем shape mismatch на первом же inference.
            return VLMRegistry.qwen3VL4BInstruct4Bit
        }
    }

    /// Загружает `ModelContainer` для указанной модели. Используется и при
    /// первичной инициализации, и при горячей замене (`switchActiveModel`).
    /// Возвращает контейнер; кто его сохранит в `self.container` — решает caller.
    private func loadContainer(for model: LocalVLMModel) async throws -> ModelContainer {
        // 1) Asset Pack путь (iOS 26+).
        if let localURL = await ModelAssetProvider.ensureAvailable(
            modelRoot: model.assetPackModelRoot,
            progress: { fraction in
                NotificationCenter.default.post(
                    name: Self.progressNotification,
                    object: nil,
                    userInfo: ["fraction": fraction]
                )
            }
        ) {
            await Self.waitUntilActive()
            return try await loadModelContainer(
                from: localURL,
                using: #huggingFaceTokenizerLoader()
            )
        }

        // 2) HuggingFace fallback.
        let totalBox = TotalBox()
        let samplingTask = Task.detached {
            let baseline = Self.hfCacheSize()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let total = totalBox.value, total > 0 else { continue }
                let downloaded = max(0, Self.hfCacheSize() - baseline)
                guard downloaded > 0 else { continue }
                let fraction = min(1.0, Double(downloaded) / Double(total))
                NotificationCenter.default.post(
                    name: Self.progressNotification,
                    object: nil,
                    userInfo: ["fraction": fraction]
                )
            }
        }
        defer { samplingTask.cancel() }

        let resolved = try await resolve(
            configuration: Self.registryConfiguration(for: model),
            from: #hubDownloader(),
            useLatest: false,
            progressHandler: { progress in
                if progress.totalUnitCount > 1, totalBox.value == nil {
                    totalBox.value = progress.totalUnitCount
                }
            }
        )
        await Self.waitUntilActive()
        return try await loadModelContainer(
            from: resolved.modelDirectory,
            using: #huggingFaceTokenizerLoader()
        )
    }
    #endif

    // MARK: - Hot swap

    /// Замена активной модели. Если новая не инициализируется — throws и
    /// сервис остаётся в "no model" состоянии (caller должен решить fallback,
    /// напр. coordinator делает rollback к bootstrap).
    ///
    /// **Cold swap, а не hot swap:** старый контейнер выгружается ДО загрузки
    /// нового. Раньше делали наоборот (load new → swap → release old) ради
    /// нулевого downtime, но peak memory достигал old+new (~4-5 GB для
    /// qwen2+qwen3) и iOS jetsam убивал процесс на iPhone 17 Pro Max.
    /// Сейчас peak = max(old, new), downtime ~5-30 сек на mmap+GPU-загрузке.
    /// UX: ModelDownloadBanner показывается через `ModelDownloadState.phase`,
    /// инференс возвращает `modelNotLoaded` пока новая модель не готова.
    public func switchActiveModel(_ model: LocalVLMModel) async throws {
        #if targetEnvironment(simulator)
        // На симуляторе MLX не работает — фиксируем выбор и считаем готовым.
        await holder.setLoaded(model: model)
        #else
        // 1) Drain in-flight inference + container = nil. Старый
        //    ModelContainer становится ARC-orphan (но его MTLBuffer'ы
        //    могут остаться в MLX.Memory cache до явной эвакуации).
        await holder.clear()

        // 2) Sync GPU — ждём submitted command buffers. После respond
        //    Swift получает результат, GPU может ещё доезжать до конца.
        Stream.gpu.synchronize()

        // 3) Загружаем новый контейнер. Peak memory здесь:
        //    cache (старые буферы ~ qwen2 1.3 GB) + new (qwen3 ~ 2.6 GB)
        //    ≈ 3.9–4.5 GB — терпимо для devices, проходящих
        //    `recommendedHeavyModel()` гейт (минимум 6 GB physicalMemory).
        //
        //    Если loadContainer бросит (OOM, повреждённые шарды, отсутствие
        //    весов), холдер уже пуст после шага 1 — все тапы «Распознать»,
        //    приехавшие в окно загрузки, паркуются в `loadWaiters` через
        //    `acquire()` и без отмены висят навечно (новый `setLoaded` уже
        //    не наступит). Резюмим их nil → caller получает modelNotLoaded
        //    и видит ошибку, а не вечный спиннер.
        let new: ModelContainer
        do {
            new = try await loadContainer(for: model)
        } catch {
            await holder.cancelLoadWaiters()
            throw error
        }

        // 4) Дожидаемся, пока загрузка (mmap, квантизация) осела на GPU.
        Stream.gpu.synchronize()

        // 5) Атомарно делаем новый активным. Между шагами 1 и 5
        //    isInitialized=false, `processImageAnalysis` отдаёт
        //    `modelNotLoaded` — UI показывает upgrade-banner.
        await holder.setLoaded(container: new, model: model)

        // 6) Эвакуируем кешированные MTLBuffer'ы старой модели — ТОЛЬКО
        //    сейчас, после того как новая модель уже активна и
        //    зарегистрировала свои references на shared Metal objects
        //    (MTLLibrary, MTLPipelineState через MLX.Memory).
        //
        //    Раньше (до этой правки) clearCache стоял МЕЖДУ holder.clear()
        //    и loadContainer. Это уничтожало shared Metal objects ДО
        //    того, как loadContainer мог их перезахватить → при первом
        //    же коммите inference на новой модели Metal Debug Layer
        //    ловил `MTLDebugCommandBuffer preCommit:1167 — command buffer
        //    references deallocated object` и app падал на устройстве
        //    через SIGABRT (см. crash 2026-04-27, stack: asyncEval →
        //    commit_command_buffer → preCommit assert). Sync не помогал:
        //    он ждёт GPU completion, но не отпускает internal refs Debug
        //    Layer'а на завершённые command buffers.
        //
        //    Теперь к моменту clearCache:
        //    - старый container уже ARC-released (был nil в holder + не в
        //      snapshot все шаги 1–5) — его буферы orphan'ы в MLX cache;
        //    - новая модель уже activated и держит refs на свои объекты;
        //    - clearCache выкидывает только orphan'ы — refs у Debug Layer
        //      на новые command buffers (которых ещё нет) не пострадают.
        Stream.gpu.synchronize()
        MLX.Memory.clearCache()

        AppLog.info("MLX VLM swapped → \(model.displayName)", category: .llm)
        #endif
    }

    /// Идемпотентная отметка: на heavy уже была хотя бы одна успешная inference.
    /// Координатор по этому флагу решает — можно ли удалять bootstrap.
    /// Дополнительно триггерит `purgeBootstrap()` как safety-net на случай,
    /// если purge после успешного апгрейда не отработал (краш приложения,
    /// kill-by-jetsam в момент удаления). Сам `purgeBootstrap()` идемпотентный
    /// через `bootstrapHFPurgedKey` — повторный вызов = no-op.
    public func markFirstSuccessfulHeavyInference() {
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: Self.firstHeavyInferenceKey) {
            defaults.set(true, forKey: Self.firstHeavyInferenceKey)
        }
        Task.detached(priority: .background) {
            await Self.purgeBootstrap()
        }
    }

    /// Полностью освобождает место от bootstrap-модели (qwen2-VL-2B):
    ///   - HF-кеш (`models--mlx-community--Qwen2-VL-2B-Instruct-4bit`) ~1.2 GB
    ///     на dev/HF-fallback сценариях.
    ///   - Staging dir (`Caches/vlm-staging/qwen2-vl-2b-instruct-4bit/`) ~1.2 GB
    ///     reassembled .safetensors из Asset Pack шардов.
    ///   - Asset Packs (BackgroundAssets remove) на iOS 26+ — освобождает
    ///     системные ~1.2 GB; на App Store сборке это основная экономия.
    /// Идемпотентный: при повторном вызове проверяет `bootstrapHFPurgedKey`
    /// и сразу возвращает. Безопасен в режиме `Task.detached(priority: .background)`.
    public static func purgeBootstrap() async {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: bootstrapHFPurgedKey) else { return }

        let modelRoot = LocalVLMModel.qwen2VL_2B.assetPackModelRoot

        // 1) Asset Packs ПЕРВЫМИ — пока meta-pack доступен, manifest
        //    читабелен и мы знаем все ID шардов. После remove(meta) — нет.
        await ModelAssetProvider.purgeAssetPacks(for: modelRoot)

        // 2) Staging dir — наша копия reassembled-весов.
        _ = ModelAssetProvider.purgeStagingDir(for: modelRoot)

        // 3) HF cache (legacy / debug fallback path).
        let hfOK = purgeBootstrapHFCache()

        // Флаг ставим только если HF-cleanup прошёл без ошибок IO.
        // Asset Pack remove failures не блокируют — там «удалить нельзя»
        // часто означает «уже удалено» или «нет на этой сборке».
        if hfOK {
            defaults.set(true, forKey: bootstrapHFPurgedKey)
            AppLog.info("Bootstrap purge complete (qwen2-vl-2b)", category: .llm)
        }
    }

    /// Был ли первый успешный heavy-inference. Координатор использует это,
    /// чтобы решить — безопасно ли удалить bootstrap-веса.
    public static var hasPerformedSuccessfulInferenceOnHeavy: Bool {
        UserDefaults.standard.bool(forKey: firstHeavyInferenceKey)
    }

    /// Удаляет HF-кеш bootstrap'а (qwen2-vl-2b). Возвращает `true`, если
    /// либо кеша не было (нечего удалять), либо удаление прошло без ошибок.
    /// `false` возвращается только при реальной ошибке IO — caller должен
    /// не выставлять `bootstrapHFPurgedKey`, чтобы попробовать ещё раз
    /// при следующей heavy-inference.
    private static func purgeBootstrapHFCache() -> Bool {
        guard let cachesURL = try? FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ) else { return false }

        let hfRoot = cachesURL.appendingPathComponent("huggingface")
        guard FileManager.default.fileExists(atPath: hfRoot.path) else {
            // Кеша нет — вероятно, bootstrap пришёл через Asset Pack.
            // Считаем cleanup завершённым, чтобы не пытаться снова.
            return true
        }

        // HF cache layout варьируется (top-level или под `hub/`); ищем по имени
        // папки — `models--mlx-community--Qwen2-VL-2B-Instruct-4bit` или похожее.
        let needle = "Qwen2-VL-2B-Instruct-4bit"
        var anyError = false
        var totalRemoved: Int64 = 0

        let candidates = [hfRoot, hfRoot.appendingPathComponent("hub")]
        for root in candidates {
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            guard let children = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey]
            ) else { continue }
            for url in children where url.lastPathComponent.contains(needle) {
                let size = directorySize(at: url)
                do {
                    try FileManager.default.removeItem(at: url)
                    totalRemoved += size
                    AppLog.info(
                        "Purged bootstrap HF cache: \(url.lastPathComponent) (\(size / 1_048_576) MB)",
                        category: .llm
                    )
                } catch {
                    AppLog.error(
                        "Failed to purge \(url.lastPathComponent): \(error.localizedDescription)",
                        category: .llm
                    )
                    anyError = true
                }
            }
        }

        AppLog.info("Bootstrap HF cache cleanup: освобождено \(totalRemoved / 1_048_576) MB", category: .llm)
        return !anyError
    }

    // MARK: - Cleanup

    /// Сбрасывает контейнер и state. Async, чтобы caller мог дождаться
    /// дренажа in-flight inference и `MLX.Memory.clearCache()` ПЕРЕД
    /// созданием нового сервиса. Иначе clearCache при rebuild стрельнул бы
    /// по только что загруженному в новый сервис контейнеру.
    public func cleanup() async {
        await holder.clear()
        #if !targetEnvironment(simulator)
        // Любые pending тапы «Распознать», которые ждали setLoaded на этом
        // (умирающем) сервисе, получают nil → caller бросает modelNotLoaded.
        // Без этого waiters висели бы навсегда — fresh-сервис свой setLoaded
        // дёргает в собственном holder'е, не в нашем.
        await holder.cancelLoadWaiters()
        // Sync GPU — ждём завершения submitted command buffers перед
        // тем как ARC отпустит старый container.
        Stream.gpu.synchronize()
        // clearCache здесь безопасен: после rebuildLLMService этот сервис
        // больше не используется (caller свапнул AppController.llmService
        // на fresh-инстанс перед `cleanup` через rebuildLLMService:91), и
        // никаких новых command buffers через этот контейнер не пойдёт.
        // У rebuildLLMService нет race вида switch (как в `switchActiveModel`),
        // потому что fresh-сервис создаёт собственные shared Metal objects
        // через свой первый loadContainer, а не разделяет state со старым.
        MLX.Memory.clearCache()
        #endif
    }

    // MARK: - Constants

    /// Ждёт, пока приложение не окажется в `.active`. Возвращается мгновенно,
    /// если оно уже активно. Используется перед MLX/Metal вызовами — чтобы
    /// не крашить app, если inference стартует в фоне.
    /// На macOS-target (eval-tool) — no-op: процесс CLI всегда foreground.
    #if canImport(UIKit)
    @MainActor
    private static func waitUntilActive() async {
        if UIApplication.shared.applicationState == .active { return }
        // Swift 6: `var observer` мутируется после захвата в @Sendable closure +
        // `NSObjectProtocol` — non-Sendable. Заворачиваем в Sendable-box и
        // мутируем через withLock, чтобы compiler был доволен и не было
        // гонки на removeObserver.
        let box = ObserverBox()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let observer = NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { _ in
                guard let observer = box.takeObserver() else { return }
                NotificationCenter.default.removeObserver(observer)
                continuation.resume()
            }
            box.setObserver(observer)
        }
    }
    #else
    private static func waitUntilActive() async { /* macOS CLI: no app lifecycle */ }
    #endif

    /// Box для one-shot NSObjectProtocol observer. `@unchecked Sendable`,
    /// потому что доступ только через unfair-lock; NSObjectProtocol сам
    /// non-Sendable, но instance валиден между потоками — observer ссылка
    /// от NotificationCenter живёт пока мы её не удалим.
    nonisolated private final class ObserverBox: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock()
        private var observer: NSObjectProtocol?
        private var finished = false

        func setObserver(_ value: NSObjectProtocol) {
            lock.withLock { observer = value }
        }

        /// Атомарно: возвращает observer и помечает completed. Вторая
        /// нотификация (на тот же observer) вернёт nil и ничего не сделает.
        func takeObserver() -> NSObjectProtocol? {
            lock.withLock {
                guard !finished else { return nil }
                finished = true
                let value = observer
                observer = nil
                return value
            }
        }
    }

    /// Хранит ожидаемый total, установленный из HF progressHandler.
    /// Читается из detached-Task — нужен thread-safe reference тип.
    nonisolated private final class TotalBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: Int64?
        var value: Int64? {
            get { lock.lock(); defer { lock.unlock() }; return _value }
            set { lock.lock(); defer { lock.unlock() }; _value = newValue }
        }
    }

    /// Эвристика «модель уже лежит на диске». Используется чтобы не
    /// показывать 0%-банер при старте, если HF-кеш уже содержит веса и
    /// `resolve()` отработает мгновенно. Порог 500 МБ — гарантированно
    /// больше любого набора мета/конфигов без самих весов (Qwen2-VL 2B
    /// 4bit ≈ 1.2 ГБ, heavy 4bit ≈ 2.6–3 ГБ).
    private static func isModelLikelyCached() -> Bool {
        return hfCacheSize() > 500_000_000
    }

    /// Суммарный размер скачанных/скачиваемых файлов. Считает:
    /// 1) `Library/Caches/huggingface/` — куда HubClient переносит завершённые файлы
    /// 2) `NSTemporaryDirectory()/CFNetworkDownload_*.tmp` — где URLSession буферизует
    ///    in-progress скачивание большого файла (model.safetensors).
    /// Без второго источника пока скачивается 3.5 ГБ файл, прогресс-бар стоит на 1%.
    private static func hfCacheSize() -> Int64 {
        var total: Int64 = 0

        if let cachesURL = try? FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ) {
            total += directorySize(at: cachesURL.appendingPathComponent("huggingface"))
        }

        // tmp может содержать и другие файлы — считаем только CFNetworkDownload_*
        let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        if let children = try? FileManager.default.contentsOfDirectory(
            at: tmpURL, includingPropertiesForKeys: [.fileSizeKey, .totalFileAllocatedSizeKey]
        ) {
            for url in children where url.lastPathComponent.hasPrefix("CFNetworkDownload") {
                let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
                total += Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
            }
        }

        return total
    }

    private static func directorySize(at url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
        }
        return total
    }

    private func mockNutritionJSON(name: String) -> String {
        let portion = String(localized: "nutrition_serving_250g")
        return """
        {"foodName":"\(name)","portionSize":"\(portion)","portionGrams":250,"calories":420,"protein":28,"carbs":35,"fats":18}
        """
    }
}

// MARK: - ModelHolder

/// Actor-обёртка для critical-state `LocalLLMService`: container, флаг
/// initialized и selectedModel. Зачем актор, а не просто unfair-lock:
///  - drain-before-swap: `swap()` и `clear()` ждут, пока завершатся все
///    in-flight inference, прежде чем сменить контейнер и дёрнуть
///    `MLX.Memory.clearCache()`. Без drain'а MLX мог бы снять Metal-кеш
///    под идущей генерацией → SIGABRT в C++ стеке.
///  - acquire/release протокол: caller-inference берёт ссылку через
///    `acquire()`, потом обязательно вызывает `release()` (даже на error).
///  - Snapshot обновляется ТОЛЬКО в actor-методах под unfair-lock'ом —
///    `isInitialized`/`modelName` остаются дешёвыми non-async читателями.
fileprivate actor ModelHolder {
    private let snapshot: OSAllocatedUnfairLock<LocalLLMService.Snapshot>

    #if !targetEnvironment(simulator)
    private var container: ModelContainer?
    private var inflight: Int = 0
    /// Несколько drain-ожидающих сразу могут не появиться, но если когда-нибудь
    /// `swap` и `clear` запустятся параллельно, единственный slot continuations
    /// потерял бы один из них. Массив дёшев и убирает класс багов.
    private var drainContinuations: [CheckedContinuation<Void, Never>] = []
    /// Тапы «Распознать» во время первичной загрузки модели или фонового
    /// апгрейда: контейнера ещё нет, но мы не хотим бросать `modelNotLoaded`
    /// и показывать «Не удалось распознать» пока модель доезжает. Вместо
    /// этого паркуем continuation тут — он резюмится в `setLoaded(...)` или
    /// в `cancelLoadWaiters()` (cleanup перед удалением сервиса).
    private var loadWaiters: [CheckedContinuation<ModelContainer?, Never>] = []
    #endif

    init(snapshot: OSAllocatedUnfairLock<LocalLLMService.Snapshot>) {
        self.snapshot = snapshot
    }

    #if !targetEnvironment(simulator)
    /// Атомарно фиксирует загруженный контейнер и обновляет snapshot.
    /// Резюмирует все `loadWaiters` — каждый park'нутый caller (тап
    /// «Распознать», отправленный пока шла загрузка) получает контейнер
    /// и сразу переходит в in-flight (inflight++).
    func setLoaded(container: ModelContainer, model: LocalVLMModel) {
        self.container = container
        snapshot.withLock {
            $0.initialized = true
            $0.selectedModel = model
        }
        let waiters = loadWaiters
        loadWaiters.removeAll()
        for cont in waiters {
            inflight += 1
            cont.resume(returning: container)
        }
    }

    /// Возвращает контейнер для inference, инкрементируя счётчик активных
    /// генераций. Если контейнера ещё нет (первая загрузка / cold-swap
    /// в процессе), парковка через `loadWaiters` — caller дождётся
    /// `setLoaded(...)` или получит nil из `cancelLoadWaiters()`
    /// (cleanup перед уничтожением сервиса).
    /// Caller ОБЯЗАН вызвать `release()` ровно один раз при не-nil.
    func acquire() async -> ModelContainer? {
        if let c = container {
            inflight += 1
            return c
        }
        return await withCheckedContinuation { (cont: CheckedContinuation<ModelContainer?, Never>) in
            loadWaiters.append(cont)
        }
    }

    /// Декрементирует счётчик и пробуждает дренирующих, если активных не осталось.
    func release() {
        inflight -= 1
        if inflight == 0 { resumeDrains() }
    }

    /// Резюмит все `loadWaiters` с nil — caller получит `modelNotLoaded`.
    /// Используется только в `cleanup()`: после rebuildLLMService этот
    /// сервис уже мёртв, ждать у него `setLoaded` бессмысленно.
    /// `clear()` НЕ дёргает этот метод — там после nil-ения контейнера
    /// планируется новый `setLoaded` (cold-swap), waiters должны его
    /// дождаться, а не получить ошибку.
    func cancelLoadWaiters() {
        let waiters = loadWaiters
        loadWaiters.removeAll()
        for cont in waiters { cont.resume(returning: nil) }
    }

    /// Дренирует in-flight inference, потом сбрасывает контейнер.
    func clear() async {
        await drainInflight()
        container = nil
        snapshot.withLock { $0.initialized = false }
    }

    private func drainInflight() async {
        guard inflight > 0 else { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            drainContinuations.append(cont)
        }
    }

    private func resumeDrains() {
        guard !drainContinuations.isEmpty else { return }
        let pending = drainContinuations
        drainContinuations.removeAll()
        for cont in pending { cont.resume() }
    }
    #else
    /// На симуляторе контейнера нет — обновляем только snapshot.
    func setLoaded(model: LocalVLMModel) {
        snapshot.withLock {
            $0.initialized = true
            $0.selectedModel = model
        }
    }

    func clear() {
        snapshot.withLock { $0.initialized = false }
    }
    #endif
}

#endif
