import CoreImage
import Foundation

// MARK: - EvalRunner
//
// Основной orchestrator: ground_truth → for each (image × prompt × model) →
// ModelAdapter.analyze → ModelOutput.parse → Scorer.score → [PerImageRecord].
// Прогресс лог в stderr; финальная агрегация — отдельный шаг через
// Aggregator.summarize (вызывает caller, см. RunCommand).
//
// Всё последовательно, без параллелизма: MLX session не thread-safe,
// и параллельные inference исчерпают GPU память.

enum EvalRunnerError: Error, LocalizedError {
    case groundTruthMissing(URL)
    case noMatchingItems(filter: String)
    case imageMissing(String)
    case promptMissing(URL)

    var errorDescription: String? {
        switch self {
        case .groundTruthMissing(let url):
            return "ground_truth file not found at \(url.path). Create it (см. SPECS/) или передай --ground-truth <path>."
        case .noMatchingItems(let filter):
            return "no items in ground_truth matched filter \(filter)"
        case .imageMissing(let path):
            return "image file not found at \(path)"
        case .promptMissing(let url):
            return "prompt file not found at \(url.path)"
        }
    }
}

/// Фильтр выбора items из ground_truth для прогона.
enum ImageFilter {
    case all
    case tier(Int)
    case ids([String])
    case folder(String)  // например "_smoke/apple" — matches image starts with prefix
}

extension ImageFilter {
    /// Парсит CLI-флаг `--images <value>`:
    ///   - "all" → .all
    ///   - "tier1" / "tier2" / "tier3" → .tier(N)
    ///   - "id1,id2,id3" → .ids(...)
    ///   - prefix (e.g. "_smoke/apple") → .folder(prefix)
    static func parse(_ raw: String) -> ImageFilter {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch s {
        case "all", "": return .all
        case "tier1": return .tier(1)
        case "tier2": return .tier(2)
        case "tier3": return .tier(3)
        default:
            if s.contains(",") {
                let ids = s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                return .ids(ids)
            }
            // одиночный id или префикс пути
            return .ids([s])
        }
    }

    func apply(to items: [GroundTruthItem]) -> [GroundTruthItem] {
        switch self {
        case .all:
            return items
        case .tier(let t):
            return items.filter { $0.tier == t }
        case .ids(let ids):
            let set = Set(ids)
            return items.filter { item in
                set.contains(item.id) || set.contains(where: { item.image.hasPrefix($0) })
            }
        case .folder(let prefix):
            return items.filter { $0.image.hasPrefix(prefix) }
        }
    }
}

struct EvalRunnerConfig {
    let groundTruthURL: URL
    let imagesRoot: URL              // Fixtures/images/
    let promptURL: URL
    let promptVersion: String        // "v1"
    let modelName: String            // enum.rawValue ("qwen2VL_2B")
    let model: EvalModel
    let userPrompt: String
    let filter: ImageFilter
    let limit: Int?

    init(
        groundTruthURL: URL,
        imagesRoot: URL,
        promptURL: URL,
        promptVersion: String,
        modelName: String,
        model: EvalModel,
        userPrompt: String,
        filter: ImageFilter,
        limit: Int?
    ) {
        self.groundTruthURL = groundTruthURL
        self.imagesRoot = imagesRoot
        self.promptURL = promptURL
        self.promptVersion = promptVersion
        self.modelName = modelName
        self.model = model
        self.userPrompt = userPrompt
        self.filter = filter
        self.limit = limit
    }
}



final class EvalRunner {
    private let config: EvalRunnerConfig
    private let adapter: ModelAdapter

    init(config: EvalRunnerConfig, adapter: ModelAdapter) {
        self.config = config
        self.adapter = adapter
    }

    /// Прогоняет всё что выбрано фильтром. Возвращает список записей в том же
    /// порядке, в каком items идут в ground_truth (после фильтра/limit).
    func run() async throws -> [PerImageRecord] {
        // 1) ground_truth
        guard FileManager.default.fileExists(atPath: config.groundTruthURL.path) else {
            throw EvalRunnerError.groundTruthMissing(config.groundTruthURL)
        }
        let doc = try GroundTruthDocument.load(from: config.groundTruthURL)
        try doc.validate()

        // 2) prompt — читаем как PromptTemplate, чтобы поддержать {{FEW_SHOTS}}.
        // Если плейсхолдера нет, render() вернёт raw — backwards-compatible
        // для старого v1_baseline.txt.
        guard FileManager.default.fileExists(atPath: config.promptURL.path) else {
            throw EvalRunnerError.promptMissing(config.promptURL)
        }
        let promptTemplate: PromptTemplate
        do {
            let raw = try String(contentsOf: config.promptURL, encoding: .utf8)
            promptTemplate = PromptTemplate(raw: raw)
        } catch {
            throw EvalRunnerError.promptMissing(config.promptURL)
        }
        if promptTemplate.hasPlaceholder {
            FileHandle.standardError.write(
                Data("[runner] prompt has {{FEW_SHOTS}} — rendering per-image with seed=hash(image_id)\n".utf8)
            )
        }

        // 3) фильтр + limit
        var selected = config.filter.apply(to: doc.items)
        if let limit = config.limit, limit > 0, selected.count > limit {
            selected = Array(selected.prefix(limit))
        }
        if selected.isEmpty {
            throw EvalRunnerError.noMatchingItems(filter: filterDescription(config.filter))
        }

        FileHandle.standardError.write(
            Data("[runner] selected \(selected.count) items for run\n".utf8)
        )

        // 4) последовательный inference
        var records: [PerImageRecord] = []
        records.reserveCapacity(selected.count)
        let total = selected.count

        for (idx, truth) in selected.enumerated() {
            let imageURL = config.imagesRoot.appendingPathComponent(truth.image)
            guard FileManager.default.fileExists(atPath: imageURL.path) else {
                FileHandle.standardError.write(
                    Data("[runner] [\(idx + 1)/\(total)] SKIP \(truth.id) — image missing at \(imageURL.path)\n".utf8)
                )
                continue
            }

            let ciImage: CIImage
            do {
                ciImage = try loadCIImage(at: imageURL.path)
            } catch {
                FileHandle.standardError.write(
                    Data("[runner] [\(idx + 1)/\(total)] SKIP \(truth.id) — image decode failed: \(error.localizedDescription)\n".utf8)
                )
                continue
            }

            // Per-image system prompt: render шаблон с детерминированным seed
            // от image_id. Для шаблонов БЕЗ плейсхолдера render() вернёт raw,
            // т.е. поведение прежнее — обратная совместимость.
            let perImageSeed = FewShotsGenerator.seed(forImageId: truth.id)
            let renderedSystemPrompt = promptTemplate.render(seed: perImageSeed)

            let started = Date()
            let raw: String
            do {
                raw = try await adapter.analyze(
                    ciImage: ciImage,
                    systemPrompt: renderedSystemPrompt,
                    userPrompt: config.userPrompt
                )
            } catch {
                FileHandle.standardError.write(
                    Data("[runner] [\(idx + 1)/\(total)] FAIL \(truth.id) — inference error: \(error.localizedDescription)\n".utf8)
                )
                // Пишем запись с пустым raw, structural=0, total≈0 — caller увидит провал.
                let durationMs = Date().timeIntervalSince(started) * 1000.0
                let score = Scorer.score(output: nil, truth: truth)
                let record = PerImageRecord(
                    id: truth.id,
                    image: truth.image,
                    tier: truth.tier,
                    category: truth.category,
                    rawOutput: "",
                    parsed: nil,
                    score: score,
                    durationMs: durationMs
                )
                records.append(record)
                continue
            }
            let durationMs = Date().timeIntervalSince(started) * 1000.0

            let parsed = ModelOutput.parse(rawJSON: raw)
            let score = Scorer.score(output: parsed, truth: truth)

            let progressLine = formatProgress(
                idx: idx + 1,
                total: total,
                truth: truth,
                score: score
            )
            FileHandle.standardError.write(Data((progressLine + "\n").utf8))

            records.append(PerImageRecord(
                id: truth.id,
                image: truth.image,
                tier: truth.tier,
                category: truth.category,
                rawOutput: raw,
                parsed: parsed,
                score: score,
                durationMs: durationMs
            ))
        }

        // 5) финальный mean в stderr
        if !records.isEmpty {
            let mean = records.map { $0.score.total }.reduce(0, +) / Double(records.count)
            FileHandle.standardError.write(
                Data("[runner] done: \(records.count) records, mean=\(String(format: "%.3f", mean))\n".utf8)
            )
        }

        return records
    }

    // MARK: - Private

    private func filterDescription(_ f: ImageFilter) -> String {
        switch f {
        case .all: return "all"
        case .tier(let t): return "tier\(t)"
        case .ids(let ids): return "ids(\(ids.joined(separator: ",")))"
        case .folder(let p): return "folder(\(p))"
        }
    }

    private func formatProgress(
        idx: Int,
        total: Int,
        truth: GroundTruthItem,
        score: ScoreBreakdown
    ) -> String {
        let totalStr = String(format: "%.2f", score.total)
        var label = "[\(idx)/\(total)] tier\(truth.tier)/\(truth.id) — total=\(totalStr)"
        if let firstNote = score.notes.first {
            label += " (\(firstNote))"
        }
        return label
    }
}
