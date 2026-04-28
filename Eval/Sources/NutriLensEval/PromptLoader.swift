import Foundation

// MARK: - PromptTemplate
//
// Раньше Prompts/<v>.txt читался как plain string и подавался в адаптер as-is.
// Это создавало "статический snapshot" (см. v1_baseline.txt) — модель якорилась
// на конкретные числа из примеров. Production же рандомизирует few-shots на
// каждый запрос (FewShotsGenerator). Чтобы harness тестировал production
// поведение честно, prompt-template поддерживает плейсхолдер `{{FEW_SHOTS}}`,
// который при render() подставляется свежими shots с детерминированным seed
// (per-image, см. FewShotsGenerator.seed(forImageId:)).
//
// Backwards-compatible: если шаблон не содержит плейсхолдера (старый
// v1_baseline.txt), render() возвращает raw без изменений.

public struct PromptTemplate {
    /// Сырой текст файла промта.
    public let raw: String
    /// true ⇔ raw содержит `{{FEW_SHOTS}}`.
    public let hasPlaceholder: Bool

    /// Маркер для подстановки. Совпадает с тем, что мы пишем в Prompts/<v>.txt.
    public static let placeholder = "{{FEW_SHOTS}}"

    public init(raw: String) {
        self.raw = raw
        self.hasPlaceholder = raw.contains(PromptTemplate.placeholder)
    }

    /// Возвращает финальную строку system-prompt'а.
    /// - Если плейсхолдера нет — возвращает raw.
    /// - Иначе — подставляет `count` few-shots с заданным seed.
    /// - Параметр `seed: nil` даёт production-поведение (random); EvalRunner
    ///   же передаёт `seed = hash(image_id)` для воспроизводимости.
    public func render(seed: UInt64?, shotCount: Int = 4) -> String {
        guard hasPlaceholder else { return raw }
        let shots = FewShotsGenerator.generate(count: shotCount, seed: seed)
        return raw.replacingOccurrences(
            of: PromptTemplate.placeholder,
            with: shots.joined(separator: "\n")
        )
    }
}

// MARK: - PromptLoader

public enum PromptLoaderError: Error, LocalizedError {
    case notFound(promptVersion: String, triedPaths: [URL])
    case readFailed(URL, underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .notFound(let ver, let tried):
            let names = tried.map { $0.lastPathComponent }.joined(separator: ", ")
            return "prompt \(ver) not found in Prompts/ (tried \(names))"
        case .readFailed(let url, let err):
            return "failed to read prompt at \(url.path): \(err.localizedDescription)"
        }
    }
}

public enum PromptLoader {

    /// Резолвит prompt-файл по версии. Поддерживает несколько имён:
    /// - `<ver>.txt`               (новые промты v1_production / v1_production_retry)
    /// - `<ver>_baseline.txt`      (старый snapshot v1_baseline.txt)
    public static func load(promptVersion: String, fixturesDir: URL) throws -> PromptTemplate {
        let promptsRoot = fixturesDir
        let candidates = [
            promptsRoot.appendingPathComponent("\(promptVersion).txt"),
            promptsRoot.appendingPathComponent("\(promptVersion)_baseline.txt"),
        ]
        guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw PromptLoaderError.notFound(promptVersion: promptVersion, triedPaths: candidates)
        }
        do {
            let raw = try String(contentsOf: url, encoding: .utf8)
            return PromptTemplate(raw: raw)
        } catch {
            throw PromptLoaderError.readFailed(url, underlying: error)
        }
    }
}
