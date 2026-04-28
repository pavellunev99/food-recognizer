#if os(iOS)

import Foundation
#if canImport(BackgroundAssets)
import BackgroundAssets
import System
#endif

/// Локальный источник файлов VLM через Asset Packs (App Store Connect hosting).
/// Доступен только на iOS 26+. На более старых версиях возвращает nil —
/// вызывающий должен использовать HuggingFace-фоллбек.
///
/// Модель разбита на несколько asset packs (шарды ≤400 MB из-за 512 MB лимита
/// Apple) + meta pack с конфигами и `asset_pack_manifest.json`. Провайдер:
/// 1) Качает meta pack, читает manifest.
/// 2) Параллельно качает все data packs, перечисленные в manifest.
/// 3) В `caches/` собирает staging dir: симлинки на все файлы + reassembly
///    побайтно-разрезанных шардов (ручная склейка .partNN → исходный файл).
///    Reassembly пишет во временный файл и атомарно переименовывает;
///    маркер `.complete` в staging dir означает что сборка завершена.
/// 4) Возвращает URL staging dir. MLX-loader читает sharded safetensors через
///    `model.safetensors.index.json`.
enum ModelAssetProvider {

    /// Корневой идентификатор модели (имя папки). Meta pack = "\(root)-meta".
    /// Data-паки перечислены в manifest и докачиваются динамически.
    static func ensureAvailable(
        modelRoot: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async -> URL? {
        #if canImport(BackgroundAssets)
        if #available(iOS 26, *) {
            return await resolve(modelRoot: modelRoot, progress: progress)
        }
        #endif
        return nil
    }

    #if canImport(BackgroundAssets)
    @available(iOS 26, *)
    private static func resolve(
        modelRoot: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async -> URL? {
        let manager = AssetPackManager.shared
        let metaPackID = "\(modelRoot)-meta"

        do {
            // 1) Meta pack — читаем manifest.
            let metaPack = try await manager.assetPack(withID: metaPackID)
            try await manager.ensureLocalAvailability(of: metaPack)

            let manifestPath = FilePath("\(modelRoot)/asset_pack_manifest.json")
            let manifestURL = try manager.url(for: manifestPath)
            let manifest = try parseManifest(at: manifestURL)
            try validateManifest(manifest)

            // 2) Все остальные паки параллельно с агрегированным прогрессом.
            let dataPackIDs = manifest.packs.keys.filter { $0 != metaPackID }
            try await downloadPacksInParallel(
                ids: dataPackIDs,
                manager: manager,
                progress: progress
            )

            // 3) Staging dir (idempotent — при наличии маркера переиспользуем).
            let stagingURL = try stagingDirectory(for: modelRoot)
            try buildStagingDir(
                stagingURL: stagingURL,
                manifest: manifest,
                modelRoot: modelRoot,
                manager: manager
            )

            progress(1.0)
            return stagingURL
        } catch {
            AppLog.error(
                "Asset packs для \(modelRoot) недоступны: \(error.localizedDescription)",
                category: .llm
            )
            return nil
        }
    }

    // MARK: - Manifest

    private struct Manifest: Decodable {
        let packs: [String: [String]]
        let reassemble: [String: [String]]
    }

    private enum ProviderError: Error, LocalizedError {
        case unsafeManifestPath(String)

        var errorDescription: String? {
            switch self {
            case .unsafeManifestPath(let p):
                return String(localized: "error_unsafe_manifest_path \(p)")
            }
        }
    }

    private static func parseManifest(at url: URL) throws -> Manifest {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Manifest.self, from: data)
    }

    /// Валидация путей из manifest: никаких `..`, абсолютных путей или NUL-байтов.
    /// Manifest пишется доверенным оффлайн-скриптом, но staging dir находится в
    /// файловой системе приложения — защищаемся от эскейпа на уровне провайдера.
    private static func validateManifest(_ manifest: Manifest) throws {
        for files in manifest.packs.values {
            for file in files { try validateRelativePath(file) }
        }
        for (target, parts) in manifest.reassemble {
            try validateRelativePath(target)
            for part in parts { try validateRelativePath(part) }
        }
    }

    private static func validateRelativePath(_ path: String) throws {
        if path.isEmpty || path.hasPrefix("/") || path.contains("\0") {
            throw ProviderError.unsafeManifestPath(path)
        }
        for component in path.split(separator: "/") {
            if component == ".." || component == "." {
                throw ProviderError.unsafeManifestPath(path)
            }
        }
    }

    // MARK: - Parallel download

    @available(iOS 26, *)
    private static func downloadPacksInParallel(
        ids: [String],
        manager: AssetPackManager,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws {
        // Трекаем прогресс по каждому паку, агрегируем в среднее значение.
        let fractions = FractionMap(capacity: ids.count, onUpdate: progress)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask {
                    try Task.checkCancellation()
                    let pack = try await manager.assetPack(withID: id)

                    // Структурированная конкурентность: status-loop живёт во
                    // внутренней группе, отменяется сразу после завершения
                    // ensureLocalAvailability. Так оба async-контекста не
                    // пересекаются неструктурированно.
                    try await withThrowingTaskGroup(of: Void.self) { inner in
                        inner.addTask {
                            for await update in manager.statusUpdates(forAssetPackWithID: id) {
                                if case .downloading(_, let p) = update {
                                    await fractions.set(id: id, value: p.fractionCompleted)
                                }
                            }
                        }

                        try Task.checkCancellation()
                        try await manager.ensureLocalAvailability(of: pack)
                        await fractions.set(id: id, value: 1.0)
                        inner.cancelAll()
                    }
                }
            }

            // Первая ошибка → отменяем остальные дочерние задачи, чтобы
            // не качать ненужное в фоне.
            do {
                try await group.waitForAll()
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    /// Актор для агрегации прогресса по нескольким параллельным загрузкам.
    private actor FractionMap {
        private var values: [String: Double] = [:]
        private let capacity: Int
        private let onUpdate: @Sendable (Double) -> Void

        init(capacity: Int, onUpdate: @escaping @Sendable (Double) -> Void) {
            self.capacity = capacity
            self.onUpdate = onUpdate
        }

        func set(id: String, value: Double) {
            values[id] = value
            let total = values.values.reduce(0, +)
            let denom = Double(max(capacity, 1))
            onUpdate(total / denom)
        }
    }

    // MARK: - Staging dir

    private static let completionMarker = ".complete"

    private static func stagingDirectory(for modelRoot: String) throws -> URL {
        let caches = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return caches.appendingPathComponent("vlm-staging", isDirectory: true)
            .appendingPathComponent(modelRoot, isDirectory: true)
    }

    @available(iOS 26, *)
    private static func buildStagingDir(
        stagingURL: URL,
        manifest: Manifest,
        modelRoot: String,
        manager: AssetPackManager
    ) throws {
        let fm = FileManager.default
        let markerURL = stagingURL.appendingPathComponent(completionMarker)

        // Идемпотентность: если маркер уже на месте — staging готов с прошлого
        // запуска, ничего не пересобираем.
        if fm.fileExists(atPath: markerURL.path) {
            return
        }

        // Неполная или отсутствующая staging — сносим и собираем с нуля.
        if fm.fileExists(atPath: stagingURL.path) {
            try fm.removeItem(at: stagingURL)
        }
        try fm.createDirectory(at: stagingURL, withIntermediateDirectories: true)

        // Собираем множество файлов, которые нужно reassemble (они не
        // симлинкаются — вместо них в staging лежит склеенный файл).
        let reassembleTargets = Set(manifest.reassemble.keys)
        let reassembleParts = Set(manifest.reassemble.values.flatMap { $0 })

        // Симлинки: все файлы из всех паков, кроме частей reassemble.
        for (_, files) in manifest.packs {
            for file in files {
                if reassembleParts.contains(file) { continue }
                let src = try manager.url(for: FilePath("\(modelRoot)/\(file)"))
                let dst = stagingURL.appendingPathComponent(file)
                try? fm.removeItem(at: dst)
                try fm.createSymbolicLink(at: dst, withDestinationURL: src)
            }
        }

        // Reassemble: склеиваем части во временный файл, затем атомарно
        // переименовываем. Если процесс упадёт в середине — останется только
        // .tmp, который будет удалён вместе со staging при следующей сборке.
        for target in reassembleTargets {
            guard let parts = manifest.reassemble[target] else { continue }
            let dst = stagingURL.appendingPathComponent(target)
            let tmp = stagingURL.appendingPathComponent(target + ".tmp")
            try? fm.removeItem(at: dst)
            try? fm.removeItem(at: tmp)

            guard fm.createFile(atPath: tmp.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let handle = try FileHandle(forWritingTo: tmp)
            do {
                for part in parts {
                    let src = try manager.url(for: FilePath("\(modelRoot)/\(part)"))
                    let inHandle = try FileHandle(forReadingFrom: src)
                    defer { try? inHandle.close() }
                    var eof = false
                    while !eof {
                        try autoreleasepool {
                            let chunk = try inHandle.read(upToCount: 8 * 1024 * 1024) ?? Data()
                            if chunk.isEmpty {
                                eof = true
                                return
                            }
                            try handle.write(contentsOf: chunk)
                        }
                    }
                }
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                try? fm.removeItem(at: tmp)
                throw error
            }

            try fm.moveItem(at: tmp, to: dst)
        }

        // Маркер завершения — пишем последним. Его наличие означает что весь
        // staging dir собран полностью и консистентен.
        try Data().write(to: markerURL, options: .atomic)
    }
    #endif

    // MARK: - Purge

    /// Удаляет staging dir конкретной модели. Безопасно вызывать когда модель
    /// больше не активна (после апгрейда heavy → bootstrap не нужен).
    /// Возвращает `true` если staging либо отсутствовал, либо удалён без
    /// ошибок. На случай частичного удаления — `false` означает «остались
    /// файлы», caller сможет повторить попытку позже.
    static func purgeStagingDir(for modelRoot: String) -> Bool {
        guard let caches = try? FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ) else { return false }

        let stagingURL = caches.appendingPathComponent("vlm-staging", isDirectory: true)
            .appendingPathComponent(modelRoot, isDirectory: true)

        guard FileManager.default.fileExists(atPath: stagingURL.path) else {
            return true
        }

        do {
            let size = directorySize(at: stagingURL)
            try FileManager.default.removeItem(at: stagingURL)
            AppLog.info(
                "Purged staging dir \(modelRoot) (\(size / 1_048_576) MB)",
                category: .llm
            )
            return true
        } catch {
            AppLog.error(
                "Failed to purge staging dir \(modelRoot): \(error.localizedDescription)",
                category: .llm
            )
            return false
        }
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

    /// Удаляет все Asset Packs модели — meta-pack плюс все data-шарды,
    /// перечисленные в manifest. Manifest читаем ДО удаления meta-pack
    /// (после `remove(meta)` доступ к файлу пропадёт).
    /// На iOS < 26 / в debug-сборке без Asset Packs — no-op (manifest
    /// просто не найдётся, list packIDs останется пустым).
    static func purgeAssetPacks(for modelRoot: String) async {
        #if canImport(BackgroundAssets)
        if #available(iOS 26, *) {
            await purgeAssetPacksImpl(for: modelRoot)
        }
        #endif
    }

    #if canImport(BackgroundAssets)
    @available(iOS 26, *)
    private static func purgeAssetPacksImpl(for modelRoot: String) async {
        let manager = AssetPackManager.shared
        let metaPackID = "\(modelRoot)-meta"

        // 1) Читаем manifest (ещё пока meta-pack доступен) для списка
        //    всех data-шардов. Если не получилось — удаляем хотя бы meta.
        var packIDs: Set<String> = [metaPackID]
        if let manifestURL = try? manager.url(for: FilePath("\(modelRoot)/asset_pack_manifest.json")),
           let manifest = try? parseManifest(at: manifestURL) {
            packIDs.formUnion(manifest.packs.keys)
        } else {
            AppLog.info(
                "Asset pack manifest для \(modelRoot) недоступен — удаляем только meta-pack",
                category: .llm
            )
        }

        // 2) Удаляем параллельно. Ошибки не критичны (pack могло уже не
        //    быть, или это debug-сборка без Asset Packs) — логируем и идём
        //    дальше; HF-кеш и staging dir всё равно почистятся.
        await withTaskGroup(of: Void.self) { group in
            for id in packIDs {
                group.addTask {
                    do {
                        try await manager.remove(assetPackWithID: id)
                        AppLog.info("Asset pack удалён: \(id)", category: .llm)
                    } catch {
                        AppLog.info(
                            "Asset pack \(id) не удалось удалить: \(error.localizedDescription)",
                            category: .llm
                        )
                    }
                }
            }
        }
    }
    #endif
}

#endif
