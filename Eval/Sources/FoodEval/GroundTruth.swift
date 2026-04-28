import Foundation

// MARK: - Ground Truth Schema
//
// Соответствует схеме из .claude/plans/vlm-eval-harness.md "ground_truth.json schema".
// Sendable + Codable, чтобы пайпить через JSON-runs и работать в строгой Swift 6 concurrency.

public struct GroundTruthItem: Codable, Sendable, Equatable {
    public let id: String
    public let image: String              // путь относительно Fixtures/images/
    public let tier: Int                  // 1, 2, 3
    public let category: String           // "fruit", "packaged", "dish" и т.п.
    public let nameAliases: [String]      // ["apple", "яблоко", "red apple"]
    public let calories: Double
    public let protein: Double
    public let carbs: Double
    public let fats: Double
    public let portionGrams: Double
    public let tolerancePercent: Double   // 10 для tier-1/2, 25 для tier-3
    public let source: String
    public let license: String
    public let imageUrl: String?

    public init(
        id: String,
        image: String,
        tier: Int,
        category: String,
        nameAliases: [String],
        calories: Double,
        protein: Double,
        carbs: Double,
        fats: Double,
        portionGrams: Double,
        tolerancePercent: Double,
        source: String,
        license: String,
        imageUrl: String? = nil
    ) {
        self.id = id
        self.image = image
        self.tier = tier
        self.category = category
        self.nameAliases = nameAliases
        self.calories = calories
        self.protein = protein
        self.carbs = carbs
        self.fats = fats
        self.portionGrams = portionGrams
        self.tolerancePercent = tolerancePercent
        self.source = source
        self.license = license
        self.imageUrl = imageUrl
    }
}

public struct GroundTruthDocument: Codable, Sendable {
    public let version: Int
    public let items: [GroundTruthItem]

    public init(version: Int, items: [GroundTruthItem]) {
        self.version = version
        self.items = items
    }
}

public enum GroundTruthError: Error, CustomStringConvertible, Sendable {
    case fileNotFound(URL)
    case parseFailed(String)
    case validationFailed(String)

    public var description: String {
        switch self {
        case .fileNotFound(let url):
            return "Ground truth file not found at \(url.path)"
        case .parseFailed(let reason):
            return "Failed to parse ground_truth.json: \(reason)"
        case .validationFailed(let reason):
            return "Ground truth validation failed: \(reason)"
        }
    }
}

extension GroundTruthDocument {
    /// Загружает и парсит ground_truth.json. Не валидирует — вызови `validate()` отдельно.
    public static func load(from url: URL) throws -> GroundTruthDocument {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw GroundTruthError.fileNotFound(url)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw GroundTruthError.parseFailed("read error: \(error.localizedDescription)")
        }
        do {
            return try JSONDecoder().decode(GroundTruthDocument.self, from: data)
        } catch {
            throw GroundTruthError.parseFailed("decode error: \(error)")
        }
    }

    /// Проверяет: уникальные id, относительные image-пути, tier ∈ 1..3,
    /// tolerancePercent > 0, числовые поля ≥ 0, nameAliases непустой.
    public func validate() throws {
        guard version >= 1 else {
            throw GroundTruthError.validationFailed("version must be >= 1, got \(version)")
        }
        guard !items.isEmpty else {
            throw GroundTruthError.validationFailed("items array is empty")
        }

        var seenIds = Set<String>()
        for item in items {
            // unique id
            guard !item.id.isEmpty else {
                throw GroundTruthError.validationFailed("empty id encountered")
            }
            if seenIds.contains(item.id) {
                throw GroundTruthError.validationFailed("duplicate id: \(item.id)")
            }
            seenIds.insert(item.id)

            // tier
            guard (1...3).contains(item.tier) else {
                throw GroundTruthError.validationFailed(
                    "id=\(item.id) tier=\(item.tier) out of range 1...3"
                )
            }

            // image path: relative (no leading "/")
            guard !item.image.isEmpty else {
                throw GroundTruthError.validationFailed("id=\(item.id) image path empty")
            }
            if item.image.hasPrefix("/") {
                throw GroundTruthError.validationFailed(
                    "id=\(item.id) image path must be relative, got \(item.image)"
                )
            }

            // tolerance > 0
            guard item.tolerancePercent > 0 else {
                throw GroundTruthError.validationFailed(
                    "id=\(item.id) tolerancePercent must be > 0"
                )
            }

            // numeric ≥ 0
            for (label, value) in [
                ("calories", item.calories),
                ("protein", item.protein),
                ("carbs", item.carbs),
                ("fats", item.fats),
                ("portionGrams", item.portionGrams),
            ] {
                guard value >= 0 else {
                    throw GroundTruthError.validationFailed(
                        "id=\(item.id) \(label)=\(value) must be >= 0"
                    )
                }
            }

            // nameAliases
            guard !item.nameAliases.isEmpty else {
                throw GroundTruthError.validationFailed(
                    "id=\(item.id) nameAliases is empty"
                )
            }
            for alias in item.nameAliases where alias.isEmpty {
                throw GroundTruthError.validationFailed(
                    "id=\(item.id) has empty alias"
                )
            }
        }
    }
}
