import Foundation

// MARK: - Score Breakdown
//
// Per-image метрики. Все поля в [0..1] кроме total — он тоже [0..1] по построению.
// Sendable + Codable, чтобы пайпить в RunSummary и через JSON-runs.

public struct ScoreBreakdown: Codable, Sendable, Equatable {
    public let structural: Double   // 0 or 1
    public let name: Double         // [0..1]
    public let calories: Double     // [0..1]
    public let protein: Double      // [0..1]
    public let carbs: Double        // [0..1]
    public let fats: Double         // [0..1]
    public let macros: Double       // avg of protein/carbs/fats
    public let total: Double        // 0.10*str + 0.30*name + 0.30*cal + 0.30*macros
    public let notes: [String]      // диагностика — что отвалилось

    public init(
        structural: Double,
        name: Double,
        calories: Double,
        protein: Double,
        carbs: Double,
        fats: Double,
        macros: Double,
        total: Double,
        notes: [String]
    ) {
        self.structural = structural
        self.name = name
        self.calories = calories
        self.protein = protein
        self.carbs = carbs
        self.fats = fats
        self.macros = macros
        self.total = total
        self.notes = notes
    }
}

public enum Scorer {

    // Веса формулы total. Сумма == 1.0:
    //   structural 0.10, name 0.30, calories 0.30, macros 0.30
    private static let wStructural: Double = 0.10
    private static let wName: Double = 0.30
    private static let wCalories: Double = 0.30
    private static let wMacros: Double = 0.30

    public static func score(output: ModelOutput?, truth: GroundTruthItem) -> ScoreBreakdown {
        var notes: [String] = []

        // ---- Structural ----
        let structural: Double = {
            guard let o = output else {
                notes.append("structural: output is nil (no JSON parsed)")
                return 0.0
            }
            var missing: [String] = []
            if o.calories == nil { missing.append("calories") }
            if o.protein == nil { missing.append("protein") }
            if o.carbs == nil { missing.append("carbs") }
            if o.fats == nil { missing.append("fats") }
            if o.portionGrams == nil { missing.append("portionGrams") }
            if !missing.isEmpty {
                notes.append("structural: missing fields \(missing.joined(separator: ","))")
                return 0.0
            }
            // Все есть — проверим неотрицательность
            let nums: [(String, Double)] = [
                ("calories", o.calories ?? 0),
                ("protein", o.protein ?? 0),
                ("carbs", o.carbs ?? 0),
                ("fats", o.fats ?? 0),
                ("portionGrams", o.portionGrams ?? 0),
            ]
            for (label, v) in nums where v < 0 {
                notes.append("structural: \(label)=\(v) is negative")
                return 0.0
            }
            return 1.0
        }()

        // ---- Name similarity ----
        let nameScore: Double = {
            guard let raw = output?.foodName, !raw.isEmpty else {
                notes.append("name: foodName missing")
                return 0.0
            }
            let foodNameLower = raw.lowercased()
            var best: Double = 0.0
            for alias in truth.nameAliases {
                let aliasLower = alias.lowercased()
                let sub = substringMatch(foodNameLower, aliasLower)
                let lev = levenshteinSimilarity(foodNameLower, aliasLower)
                let s = max(sub, lev)
                if s > best { best = s }
            }
            if best < 0.7 {
                notes.append(
                    "name mismatch: expected one of [\(truth.nameAliases.joined(separator: ","))], got \(raw)"
                )
            }
            return best
        }()

        // ---- Numeric per-field ----
        let tolerance = truth.tolerancePercent / 100.0  // e.g. 10 → 0.10

        let caloriesScore = numericScore(
            actual: output?.calories,
            truth: truth.calories,
            tolerance: tolerance,
            label: "calories",
            notes: &notes
        )
        let proteinScore = numericScore(
            actual: output?.protein,
            truth: truth.protein,
            tolerance: tolerance,
            label: "protein",
            notes: &notes
        )
        let carbsScore = numericScore(
            actual: output?.carbs,
            truth: truth.carbs,
            tolerance: tolerance,
            label: "carbs",
            notes: &notes
        )
        let fatsScore = numericScore(
            actual: output?.fats,
            truth: truth.fats,
            tolerance: tolerance,
            label: "fats",
            notes: &notes
        )

        let macros = (proteinScore + carbsScore + fatsScore) / 3.0

        let total =
            wStructural * structural
            + wName * nameScore
            + wCalories * caloriesScore
            + wMacros * macros

        return ScoreBreakdown(
            structural: structural,
            name: nameScore,
            calories: caloriesScore,
            protein: proteinScore,
            carbs: carbsScore,
            fats: fatsScore,
            macros: macros,
            total: clamp01(total),
            notes: notes
        )
    }

    // MARK: - Numeric scoring

    private static func numericScore(
        actual: Double?,
        truth: Double,
        tolerance: Double,
        label: String,
        notes: inout [String]
    ) -> Double {
        guard let actual else {
            notes.append("\(label): missing in output")
            return 0.0
        }
        // Спец. случай truth = 0: допуск ±0.5 абсолютно.
        if truth == 0 {
            if abs(actual) <= 0.5 {
                return 1.0
            } else {
                notes.append("\(label) expected 0, got \(actual) (>0.5 abs)")
                return 0.0
            }
        }

        let diff = abs(actual - truth)
        let band = truth * tolerance
        guard band > 0 else { return actual == truth ? 1.0 : 0.0 }

        let raw = 1.0 - diff / band
        let s = clamp01(raw)
        if s < 1.0 {
            let pct = Int(((actual - truth) / truth * 100).rounded())
            notes.append("\(label) off by \(pct)%: expected \(formatNum(truth)), got \(formatNum(actual))")
        }
        return s
    }

    // MARK: - Name similarity helpers

    /// 1.0 если одна строка целиком содержится в другой, иначе 0.0.
    private static func substringMatch(_ a: String, _ b: String) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0.0 }
        if a.contains(b) || b.contains(a) {
            return 1.0
        }
        return 0.0
    }

    /// `1 - distance / max(a.count, b.count)`, clamped [0..1].
    /// Работает по Character-уровню, поэтому unicode (русский) корректен.
    static func levenshteinSimilarity(_ a: String, _ b: String) -> Double {
        let aChars = Array(a)
        let bChars = Array(b)
        if aChars.isEmpty && bChars.isEmpty { return 1.0 }
        let maxLen = max(aChars.count, bChars.count)
        if maxLen == 0 { return 1.0 }
        let dist = levenshteinDistance(aChars, bChars)
        let sim = 1.0 - Double(dist) / Double(maxLen)
        return clamp01(sim)
    }

    /// Классический DP, O(n*m) time, O(min(n,m)) space.
    static func levenshteinDistance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }

        // Меньшую — в внутренний цикл, чтобы массив prev был меньше.
        let (s1, s2) = a.count <= b.count ? (a, b) : (b, a)
        var prev = Array(0...s1.count)
        var curr = Array(repeating: 0, count: s1.count + 1)

        for i in 1...s2.count {
            curr[0] = i
            let s2c = s2[i - 1]
            for j in 1...s1.count {
                let cost = (s1[j - 1] == s2c) ? 0 : 1
                curr[j] = min(
                    prev[j] + 1,        // delete
                    curr[j - 1] + 1,    // insert
                    prev[j - 1] + cost  // replace
                )
            }
            swap(&prev, &curr)
        }
        return prev[s1.count]
    }

    // MARK: - Utils

    private static func clamp01(_ x: Double) -> Double {
        if x.isNaN { return 0 }
        if x < 0 { return 0 }
        if x > 1 { return 1 }
        return x
    }

    private static func formatNum(_ x: Double) -> String {
        if x.rounded() == x { return String(Int(x)) }
        return String(format: "%.1f", x)
    }
}
