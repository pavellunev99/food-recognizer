import Foundation

// MARK: - ReportWriter
//
// Пишет run-артефакты:
//   - Reports/runs/<runId>_<promptVer>_<modelName>.json — full (records + summary)
//   - Reports/runs/<runId>_<promptVer>_<modelName>_summary.json — summary only
//   - Reports/best/<promptVer>_<modelName>.json — копия лучшего run по mean
//   - Reports/latest.md — human-readable c дельтой к best (которая была ДО)
//
// runId — ISO timestamp без двоеточий: "2026-04-28T01-30-15Z".

public struct RunArtifact: Codable, Sendable {
    public let records: [PerImageRecord]
    public let summary: RunSummary

    public init(records: [PerImageRecord], summary: RunSummary) {
        self.records = records
        self.summary = summary
    }
}

public struct ReportPaths {
    public let fullRunJSON: URL
    public let summaryJSON: URL
    public let latestMarkdown: URL
    public let bestJSON: URL
}

public enum ReportWriter {

    /// ISO timestamp с дефисами вместо `:` — пригоден для имени файла на macOS.
    /// Формат: `2026-04-28T01-30-15Z`.
    public static func makeRunId(date: Date = Date()) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        // Подменяем `:` на `-`, чтобы имя файла было FS-безопасным.
        let raw = f.string(from: date)
        return raw.replacingOccurrences(of: ":", with: "-")
    }

    /// Пишет все артефакты после успешного run. baseline — best, который был
    /// загружен ДО прогона (для дельты в latest.md). После записи best может
    /// быть обновлён (см. updateBestIfBetter).
    @discardableResult
    public static func write(
        artifact: RunArtifact,
        baseline: RunSummary?,
        reportsDir: URL
    ) throws -> ReportPaths {
        let runsDir = reportsDir.appendingPathComponent("runs")
        let bestDir = reportsDir.appendingPathComponent("best")
        try FileManager.default.createDirectory(at: runsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bestDir, withIntermediateDirectories: true)

        let baseName = "\(artifact.summary.runId)_\(artifact.summary.promptVersion)_\(artifact.summary.modelName)"
        let fullURL = runsDir.appendingPathComponent("\(baseName).json")
        let summaryURL = runsDir.appendingPathComponent("\(baseName)_summary.json")
        let latestURL = reportsDir.appendingPathComponent("latest.md")
        let bestURL = BaselineLoader.bestPath(
            reportsDir: reportsDir,
            promptVersion: artifact.summary.promptVersion,
            modelName: artifact.summary.modelName
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        // 1) Full run
        let fullData = try encoder.encode(artifact)
        try fullData.write(to: fullURL)

        // 2) Summary only
        let summaryData = try encoder.encode(artifact.summary)
        try summaryData.write(to: summaryURL)

        // 3) latest.md (с дельтой к baseline, который был ДО этого run)
        let md = MarkdownRenderer.render(summary: artifact.summary, baseline: baseline)
        try md.data(using: .utf8)?.write(to: latestURL)

        return ReportPaths(
            fullRunJSON: fullURL,
            summaryJSON: summaryURL,
            latestMarkdown: latestURL,
            bestJSON: bestURL
        )
    }

    /// Если новый run.summary.mean > baseline.summary.mean (или baseline нет) —
    /// перезаписывает Reports/best/<promptVer>_<model>.json. Возвращает true,
    /// если best был обновлён.
    @discardableResult
    public static func updateBestIfBetter(
        artifact: RunArtifact,
        existingBest: BestRun?,
        reportsDir: URL
    ) throws -> Bool {
        let bestURL = BaselineLoader.bestPath(
            reportsDir: reportsDir,
            promptVersion: artifact.summary.promptVersion,
            modelName: artifact.summary.modelName
        )

        let shouldReplace: Bool
        if let existingBest {
            shouldReplace = artifact.summary.mean > existingBest.summary.mean
        } else {
            shouldReplace = true
        }

        guard shouldReplace else { return false }

        try FileManager.default.createDirectory(
            at: bestURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let bestPayload = BestRun(records: artifact.records, summary: artifact.summary)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(bestPayload)
        try data.write(to: bestURL)
        return true
    }
}
