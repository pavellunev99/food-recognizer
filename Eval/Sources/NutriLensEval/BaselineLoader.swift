import Foundation

// MARK: - BaselineLoader
//
// Читает best-run JSON из `Reports/best/<promptVer>_<modelName>.json` для
// сравнения нового run'а с baseline. Best хранится в том же формате, что
// и run-files (PerImageRecord[] + RunSummary), потому что Wave 4 копирует
// run целиком при обновлении best (см. ReportWriter.updateBestIfBetter).
//
// Если файл отсутствует — возвращает nil (не ошибка). Caller печатает
// "(first run)" в latest.md.

public struct BestRun: Codable, Sendable {
    public let records: [PerImageRecord]
    public let summary: RunSummary

    public init(records: [PerImageRecord], summary: RunSummary) {
        self.records = records
        self.summary = summary
    }
}

public enum BaselineLoader {

    /// `Reports/best/<promptVer>_<modelName>.json`. Возвращает nil если файла нет.
    /// Бросает ошибку только при corrupt JSON, чтобы caller не молча хрюкнул baseline.
    public static func loadBest(
        reportsDir: URL,
        promptVersion: String,
        modelName: String
    ) throws -> BestRun? {
        let url = bestPath(reportsDir: reportsDir, promptVersion: promptVersion, modelName: modelName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(BestRun.self, from: data)
    }

    /// Путь к best-файлу для конкретной комбинации promptVer × model.
    public static func bestPath(
        reportsDir: URL,
        promptVersion: String,
        modelName: String
    ) -> URL {
        return reportsDir
            .appendingPathComponent("best")
            .appendingPathComponent("\(promptVersion)_\(modelName).json")
    }
}
