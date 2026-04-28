import ArgumentParser
import CoreImage
import Foundation
import MLX
import MLXLMCommon
import MLXVLM
import HuggingFace
import Tokenizers

// MARK: - Root command

// `@main` обязателен. Если оставить top-level `await NutriLensEval.main()` в
// main.swift — компилятор резолвит синхронный `ParsableCommand.main()`
// (override для AsyncParsableCommand сидит на async-перегрузке), и в DEBUG
// ArgumentParser ловит «Asynchronous root command needs availability
// annotation». `@main` форсит выбор async-варианта `AsyncParsableCommand.main`.
// `@available(macOS 10.15, *)` — формальное требование того же DEBUG-чека.
@available(macOS 10.15, *)
@main
struct NutriLensEval: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "NutriLensEval",
        abstract: "Offline VLM accuracy harness for NutriLens (Wave 1 skeleton).",
        subcommands: [GateCheck.self, SmokeInfer.self, RunCommand.self, CompareCommand.self, ScoreOnlyCommand.self],
        defaultSubcommand: GateCheck.self
    )
}

// Eval-tool корень — `tools/eval` (cwd при `swift run`). Используется чтобы
// строить дефолтные пути к Fixtures/ Prompts/ Reports/.
private func defaultEvalRoot() -> URL {
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
}

private func mapModelName(_ raw: String) -> (EvalModel, String)? {
    // Маппинг CLI-флага --model qwen2|qwen3 на (EvalModel, fileSafeName).
    // FileSafeName совпадает с production `LocalVLMModel` rawValue, чтобы
    // best-файлы и compare-таблицы согласовывались между tool и app.
    switch raw {
    case "qwen2": return (.qwen2, "qwen2VL_2B")
    case "qwen3": return (.qwen3, "qwen3VL_4B")
    default: return nil
    }
}

// MARK: - gate-check

/// Минимальная проверка зависимостей перед остальной волной:
/// - SwiftPM-таргет компилируется и линкуется под macOS;
/// - MLX отдаёт device info (Metal-enabled GPU доступен на Apple Silicon);
/// - swift-huggingface отдаёт реальный путь HF-кеша;
/// - swift-transformers умеет подтянуть конфиг + tokenizer для prod-модели.
///
/// Inference сюда сознательно не попал — это Wave 2.
struct GateCheck: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "gate-check",
        abstract: "Verify MLX + Hub + Tokenizers resolve and load on this host."
    )

    @Option(name: .long, help: "HF repo id to probe tokenizer for (Wave 1: prod bootstrap model).")
    var model: String = "mlx-community/Qwen2-VL-2B-Instruct-4bit"

    @Flag(name: .long, help: "Skip the network probe (don't download tokenizer); useful in offline CI.")
    var offline: Bool = false

    func run() async throws {
        var report = GateReport()
        report.swift = swiftRuntimeVersion()

        // 1) MLX device info. Чисто read-only вызовы, без allocate.
        report.mlx = collectMLXInfo()

        // 2) Hub cache directory из swift-huggingface.
        report.hub.cacheDir = HubCache.default.cacheDirectory.path

        // 3) Tokenizer probe — единственный сетевой шаг. Контролируется флагом.
        if offline {
            report.hub.tokenizerOk = false
            report.hub.tokenizerNote = "skipped: --offline"
            report.ok = true // offline-режим всё ещё считается зелёным gate'ом
        } else {
            do {
                _ = try await AutoTokenizer.from(pretrained: model)
                report.hub.tokenizerOk = true
                report.hub.tokenizerNote = "loaded \(model)"
                report.ok = true
            } catch {
                report.hub.tokenizerOk = false
                report.hub.tokenizerNote = "error: \(error.localizedDescription)"
                report.ok = false
                FileHandle.standardError.write(
                    Data("gate-check: tokenizer load failed for \(model): \(error)\n".utf8)
                )
            }
        }

        // JSON в stdout (machine-readable). pretty-printed для человеческого чтения.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))

        if !report.ok {
            // ArgumentParser сам конвертит ExitCode в exit код.
            throw ExitCode.failure
        }
    }
}

// MARK: - smoke-infer

/// Однократный inference: одна картинка + один промт-файл → JSON в stdout.
/// Используется чтобы быстро проверить, что весь стек (metallib bundle, HF
/// download, ChatSession.respond) работает на macOS host'е, ДО того как
/// строить полный harness с per-image scoring.
///
/// Лог стадий идёт в stderr, raw model output — в stdout. Это позволяет
/// `swift run NutriLensEval smoke-infer ... > out.json` отработать чисто
/// для машинной обработки.
struct SmokeInfer: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "smoke-infer",
        abstract: "Run a single VLM inference on one image with an override system prompt."
    )

    @Option(name: .long, help: "Path to a JPG/PNG image file.")
    var image: String

    @Option(name: .long, help: "Path to a UTF-8 text file with the system prompt.")
    var prompt: String

    @Option(name: .long, help: "Model id: qwen2 or qwen3.")
    var model: String = "qwen2"

    @Option(name: .long, help: "User message (defaults to a generic nutrition probe).")
    var userPrompt: String = "Analyze the meal in this photo and estimate nutrition facts."

    func run() async throws {
        guard let evalModel = EvalModel(rawValue: model) else {
            FileHandle.standardError.write(Data("smoke-infer: unknown --model \(model). Use qwen2 or qwen3.\n".utf8))
            throw ExitCode.failure
        }
        // Резолвим относительные пути от cwd, как ожидает обычный CLI-юзер.
        let promptText: String
        do {
            promptText = try String(contentsOfFile: prompt, encoding: .utf8)
        } catch {
            FileHandle.standardError.write(Data("smoke-infer: cannot read prompt at \(prompt): \(error.localizedDescription)\n".utf8))
            throw ExitCode.failure
        }
        guard !promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            FileHandle.standardError.write(Data("smoke-infer: prompt file is empty\n".utf8))
            throw ExitCode.failure
        }

        let ciImage: CIImage
        do {
            ciImage = try loadCIImage(at: image)
        } catch {
            FileHandle.standardError.write(Data("smoke-infer: cannot load image at \(image): \(error.localizedDescription)\n".utf8))
            throw ExitCode.failure
        }

        let adapter = ModelAdapter(model: evalModel)
        let started = Date()
        let result: String
        do {
            result = try await adapter.analyze(
                ciImage: ciImage,
                systemPrompt: promptText,
                userPrompt: userPrompt
            )
        } catch {
            // Сетевые ошибки HF + Metal ошибки оба идут сюда; различать ошибки
            // по типу нет смысла для smoke — caller увидит описание в stderr.
            FileHandle.standardError.write(Data("smoke-infer: inference failed: \(error.localizedDescription)\n".utf8))
            throw ExitCode.failure
        }
        let elapsed = Date().timeIntervalSince(started)
        FileHandle.standardError.write(Data("[smoke-infer] done in \(String(format: "%.1f", elapsed))s\n".utf8))

        // Raw output в stdout. Не парсим JSON — это smoke, valid формат
        // проверяется на следующем уровне (Wave 3 Scorer).
        FileHandle.standardOutput.write(Data(result.utf8))
        if !result.hasSuffix("\n") {
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
    }
}

// MARK: - Report payload

struct GateReport: Codable {
    struct MLXSection: Codable {
        var gpuAvailable: Bool = false
        var deviceInfo: String = ""
        var defaultDevice: String = ""
    }

    struct HubSection: Codable {
        var cacheDir: String = ""
        var tokenizerOk: Bool = false
        var tokenizerNote: String = ""
    }

    var swift: String = ""
    var mlx: MLXSection = .init()
    var hub: HubSection = .init()
    var ok: Bool = false
}

// MARK: - Helpers

private func swiftRuntimeVersion() -> String {
    // #if-блоки для версии Swift полезны только при cross-build; для рантайма
    // компилятор-версии достаточно.
    #if swift(>=6.2)
    return "6.2+"
    #elseif swift(>=6.1)
    return "6.1"
    #elseif swift(>=6.0)
    return "6.0"
    #else
    return "<6.0"
    #endif
}

private func collectMLXInfo() -> GateReport.MLXSection {
    var section = GateReport.MLXSection()
    // Любой вызов Device API через mlx-c (`mlx_device_get_type`, описание устройств,
    // `defaultDevice()`) триггерит lazy-load Metal-библиотеки `default.metallib`.
    // SwiftPM не копирует metallib в `.build/debug/<bin>` — отсюда "Failed to
    // load the default metallib" и SIGABRT через C++. Wave 1 не запускает
    // inference, поэтому обходимся статической интроспекцией:
    //  - сам факт того, что `import MLX` слинковался и static `Device.gpu`
    //    инициализировался без exception'а в startup'е, — достаточно.
    //  - если позже Wave 2 пойдёт через ChatSession, она грузит metallib через
    //    bundle resource path внутри `loadModelContainer`, либо нам нужно
    //    положить metallib в Sources/NutriLensEval/Resources/.
    //
    // В отчёте честно фиксируем "metallibLoaded=false (deferred to Wave 2)".
    section.deviceInfo = "MLX module linked; default.metallib lookup deferred to inference path"
    section.defaultDevice = "deferred"
    // На Apple Silicon (Mac arm64) Metal GPU физически есть. Это машинная
    // характеристика, не runtime — берём её из uname.
    var sysinfo = utsname()
    uname(&sysinfo)
    let arch = withUnsafePointer(to: &sysinfo.machine) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) {
            String(cString: $0)
        }
    }
    section.gpuAvailable = arch.hasPrefix("arm64")
    return section
}

// Entry point: `@main` на `NutriLensEval` сам поднимает `static main() async`
// из `AsyncParsableCommand`. Никакого top-level кода тут не нужно.

// MARK: - run

/// Полный прогон harness'а: ground_truth → inference → score → артефакты в Reports/.
struct RunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run the full eval harness over a set of images (writes Reports/runs/, best/, latest.md)."
    )

    @Option(name: .long, help: "Prompt version (e.g. v1). Resolves to Prompts/<ver>_baseline.txt or Prompts/<ver>.txt.")
    var prompt: String

    @Option(name: .long, help: "Model id: qwen2 or qwen3.")
    var model: String

    @Option(name: .long, help: "Image filter: all | tier1 | tier2 | tier3 | <id1,id2,...> | <prefix like _smoke/apple>.")
    var images: String = "all"

    @Option(name: .long, help: "Path to ground_truth.json (default: Fixtures/ground_truth.json).")
    var groundTruth: String?

    @Option(name: .long, help: "Limit number of items to process (after filter).")
    var limit: Int?

    @Option(name: .long, help: "User prompt (default: generic JSON-only probe).")
    var userPrompt: String = "Analyze this food image and respond ONLY with JSON."

    func run() async throws {
        guard let (evalModel, modelFileName) = mapModelName(model) else {
            FileHandle.standardError.write(Data("run: unknown --model \(model). Use qwen2 or qwen3.\n".utf8))
            throw ExitCode.failure
        }

        let evalRoot = defaultEvalRoot()
        let fixturesRoot = evalRoot.appendingPathComponent("Fixtures")
        let imagesRoot = fixturesRoot.appendingPathComponent("images")
        let promptsRoot = evalRoot.appendingPathComponent("Prompts")
        let reportsDir = evalRoot.appendingPathComponent("Reports")

        let gtURL: URL
        if let gtPath = groundTruth {
            gtURL = URL(fileURLWithPath: gtPath, isDirectory: false, relativeTo: evalRoot)
        } else {
            gtURL = fixturesRoot.appendingPathComponent("ground_truth.json")
        }

        // Resolve prompt file. Поддерживаем Prompts/<ver>.txt и Prompts/<ver>_baseline.txt.
        let promptCandidates = [
            promptsRoot.appendingPathComponent("\(prompt).txt"),
            promptsRoot.appendingPathComponent("\(prompt)_baseline.txt"),
        ]
        guard let promptURL = promptCandidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            FileHandle.standardError.write(Data("run: prompt \(prompt) not found in Prompts/ (tried \(promptCandidates.map { $0.lastPathComponent }.joined(separator: ", ")))\n".utf8))
            throw ExitCode.failure
        }

        let config = EvalRunnerConfig(
            groundTruthURL: gtURL,
            imagesRoot: imagesRoot,
            promptURL: promptURL,
            promptVersion: prompt,
            modelName: modelFileName,
            model: evalModel,
            userPrompt: userPrompt,
            filter: ImageFilter.parse(images),
            limit: limit
        )

        let adapter = ModelAdapter(model: evalModel)
        let runner = EvalRunner(config: config, adapter: adapter)

        // Загружаем существующий best ДО прогона — для дельты в latest.md и
        // для решения, перезаписывать ли best после прогона.
        let existingBest: BestRun?
        do {
            existingBest = try BaselineLoader.loadBest(
                reportsDir: reportsDir,
                promptVersion: prompt,
                modelName: modelFileName
            )
        } catch {
            FileHandle.standardError.write(Data("run: warning — failed to load baseline: \(error.localizedDescription)\n".utf8))
            existingBest = nil
        }

        let records: [PerImageRecord]
        do {
            records = try await runner.run()
        } catch {
            FileHandle.standardError.write(Data("run: failed: \(error.localizedDescription)\n".utf8))
            throw ExitCode.failure
        }
        guard !records.isEmpty else {
            FileHandle.standardError.write(Data("run: no records produced (all skipped/failed)\n".utf8))
            throw ExitCode.failure
        }

        let runId = ReportWriter.makeRunId()
        let summary = Aggregator.summarize(
            records: records,
            baseline: existingBest?.summary,
            runId: runId,
            promptVersion: prompt,
            modelName: modelFileName
        )
        let artifact = RunArtifact(records: records, summary: summary)

        let paths = try ReportWriter.write(
            artifact: artifact,
            baseline: existingBest?.summary,
            reportsDir: reportsDir
        )
        let updated = try ReportWriter.updateBestIfBetter(
            artifact: artifact,
            existingBest: existingBest,
            reportsDir: reportsDir
        )

        FileHandle.standardError.write(Data("[run] full:    \(paths.fullRunJSON.path)\n".utf8))
        FileHandle.standardError.write(Data("[run] summary: \(paths.summaryJSON.path)\n".utf8))
        FileHandle.standardError.write(Data("[run] latest:  \(paths.latestMarkdown.path)\n".utf8))
        if updated {
            FileHandle.standardError.write(Data("[run] best updated: \(paths.bestJSON.path)\n".utf8))
        } else {
            FileHandle.standardError.write(Data("[run] best unchanged (mean \(String(format: "%.3f", summary.mean)) ≤ existing)\n".utf8))
        }
    }
}

// MARK: - compare

/// Печатает Markdown-таблицу, сравнивающую несколько best-run по комбинации
/// (model, prompt). Не падает если только один промт.
struct CompareCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "compare",
        abstract: "Compare best-runs across multiple prompt versions for a single model."
    )

    @Option(name: .long, help: "Model id: qwen2 or qwen3.")
    var model: String

    @Option(name: .long, help: "Comma-separated prompt versions (e.g. v1,v2,v3).")
    var prompts: String

    func run() async throws {
        guard let (_, modelFileName) = mapModelName(model) else {
            FileHandle.standardError.write(Data("compare: unknown --model \(model). Use qwen2 or qwen3.\n".utf8))
            throw ExitCode.failure
        }
        let promptList = prompts.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !promptList.isEmpty else {
            FileHandle.standardError.write(Data("compare: --prompts must list at least one version\n".utf8))
            throw ExitCode.failure
        }

        let evalRoot = defaultEvalRoot()
        let reportsDir = evalRoot.appendingPathComponent("Reports")

        var collected: [(promptVersion: String, summary: RunSummary)] = []
        for ver in promptList {
            do {
                if let best = try BaselineLoader.loadBest(
                    reportsDir: reportsDir,
                    promptVersion: ver,
                    modelName: modelFileName
                ) {
                    collected.append((promptVersion: ver, summary: best.summary))
                } else {
                    FileHandle.standardError.write(Data("compare: no best for \(ver)_\(modelFileName) — skipped\n".utf8))
                }
            } catch {
                FileHandle.standardError.write(Data("compare: failed to load best for \(ver): \(error.localizedDescription)\n".utf8))
            }
        }

        if collected.isEmpty {
            FileHandle.standardError.write(Data("compare: no best-runs found, nothing to print\n".utf8))
            throw ExitCode.failure
        }

        let md = MarkdownRenderer.renderCompare(summaries: collected)
        FileHandle.standardOutput.write(Data(md.utf8))
    }
}

// MARK: - score-only

/// Отладочная команда: парсит raw JSON c диска + ищет ground_truth item по id,
/// печатает ScoreBreakdown. Inference не запускает.
struct ScoreOnlyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "score-only",
        abstract: "Score a raw model JSON against a single ground_truth item (no inference)."
    )

    @Option(name: .long, help: "Path to a file with raw model output (JSON or JSON-with-prose).")
    var rawJson: String

    @Option(name: .long, help: "Ground truth id to score against.")
    var truthId: String

    @Option(name: .long, help: "Path to ground_truth.json (default: Fixtures/ground_truth.json).")
    var groundTruth: String?

    func run() async throws {
        let evalRoot = defaultEvalRoot()
        let fixturesRoot = evalRoot.appendingPathComponent("Fixtures")
        let gtURL: URL
        if let gtPath = groundTruth {
            gtURL = URL(fileURLWithPath: gtPath, isDirectory: false, relativeTo: evalRoot)
        } else {
            gtURL = fixturesRoot.appendingPathComponent("ground_truth.json")
        }

        guard FileManager.default.fileExists(atPath: gtURL.path) else {
            FileHandle.standardError.write(Data("score-only: ground_truth not found at \(gtURL.path)\n".utf8))
            throw ExitCode.failure
        }
        let doc = try GroundTruthDocument.load(from: gtURL)
        guard let truth = doc.items.first(where: { $0.id == truthId }) else {
            FileHandle.standardError.write(Data("score-only: id \(truthId) not found in ground_truth\n".utf8))
            throw ExitCode.failure
        }

        let raw: String
        do {
            raw = try String(contentsOfFile: rawJson, encoding: .utf8)
        } catch {
            FileHandle.standardError.write(Data("score-only: cannot read \(rawJson): \(error.localizedDescription)\n".utf8))
            throw ExitCode.failure
        }
        let parsed = ModelOutput.parse(rawJSON: raw)
        let score = Scorer.score(output: parsed, truth: truth)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(score)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
