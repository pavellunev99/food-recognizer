import Foundation

// MARK: - Per-image record (input для агрегатора)

public struct PerImageRecord: Codable, Sendable, Equatable {
    public let id: String
    public let image: String
    public let tier: Int
    public let category: String
    public let rawOutput: String   // raw model JSON
    public let parsed: ModelOutput?
    public let score: ScoreBreakdown
    public let durationMs: Double

    public init(
        id: String,
        image: String,
        tier: Int,
        category: String,
        rawOutput: String,
        parsed: ModelOutput?,
        score: ScoreBreakdown,
        durationMs: Double
    ) {
        self.id = id
        self.image = image
        self.tier = tier
        self.category = category
        self.rawOutput = rawOutput
        self.parsed = parsed
        self.score = score
        self.durationMs = durationMs
    }
}

// MARK: - Per-tier stats

public struct TierStats: Codable, Sendable, Equatable {
    public let count: Int
    public let mean: Double
    public let p50: Double
    public let p90: Double
    public let passRateAt07: Double

    public init(count: Int, mean: Double, p50: Double, p90: Double, passRateAt07: Double) {
        self.count = count
        self.mean = mean
        self.p50 = p50
        self.p90 = p90
        self.passRateAt07 = passRateAt07
    }
}

// MARK: - Worst entry / Regression

public struct WorstEntry: Codable, Sendable, Equatable {
    public let id: String
    public let total: Double
    public let firstNote: String?

    public init(id: String, total: Double, firstNote: String?) {
        self.id = id
        self.total = total
        self.firstNote = firstNote
    }
}

public struct RegressionEntry: Codable, Sendable, Equatable {
    public let id: String
    public let baselineTotal: Double
    public let currentTotal: Double
    public let delta: Double  // currentTotal - baselineTotal (negative — регрессия)

    public init(id: String, baselineTotal: Double, currentTotal: Double, delta: Double) {
        self.id = id
        self.baselineTotal = baselineTotal
        self.currentTotal = currentTotal
        self.delta = delta
    }
}

// MARK: - Run summary

public struct RunSummary: Codable, Sendable, Equatable {
    public let runId: String              // ISO timestamp
    public let promptVersion: String
    public let modelName: String
    public let count: Int
    public let mean: Double
    public let p50: Double
    public let p90: Double
    public let passRateAt07: Double
    public let perTier: [Int: TierStats]
    public let worst10: [WorstEntry]
    public let regressions: [RegressionEntry]?  // nil если нет baseline

    public init(
        runId: String,
        promptVersion: String,
        modelName: String,
        count: Int,
        mean: Double,
        p50: Double,
        p90: Double,
        passRateAt07: Double,
        perTier: [Int: TierStats],
        worst10: [WorstEntry],
        regressions: [RegressionEntry]?
    ) {
        self.runId = runId
        self.promptVersion = promptVersion
        self.modelName = modelName
        self.count = count
        self.mean = mean
        self.p50 = p50
        self.p90 = p90
        self.passRateAt07 = passRateAt07
        self.perTier = perTier
        self.worst10 = worst10
        self.regressions = regressions
    }

    // [Int: TierStats] — JSON dictionary keys должны быть строками, делаем кастом.
    private enum CodingKeys: String, CodingKey {
        case runId, promptVersion, modelName, count, mean, p50, p90, passRateAt07
        case perTier, worst10, regressions
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.runId = try c.decode(String.self, forKey: .runId)
        self.promptVersion = try c.decode(String.self, forKey: .promptVersion)
        self.modelName = try c.decode(String.self, forKey: .modelName)
        self.count = try c.decode(Int.self, forKey: .count)
        self.mean = try c.decode(Double.self, forKey: .mean)
        self.p50 = try c.decode(Double.self, forKey: .p50)
        self.p90 = try c.decode(Double.self, forKey: .p90)
        self.passRateAt07 = try c.decode(Double.self, forKey: .passRateAt07)
        let raw = try c.decode([String: TierStats].self, forKey: .perTier)
        var dict = [Int: TierStats]()
        for (k, v) in raw {
            if let i = Int(k) { dict[i] = v }
        }
        self.perTier = dict
        self.worst10 = try c.decode([WorstEntry].self, forKey: .worst10)
        self.regressions = try c.decodeIfPresent([RegressionEntry].self, forKey: .regressions)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(runId, forKey: .runId)
        try c.encode(promptVersion, forKey: .promptVersion)
        try c.encode(modelName, forKey: .modelName)
        try c.encode(count, forKey: .count)
        try c.encode(mean, forKey: .mean)
        try c.encode(p50, forKey: .p50)
        try c.encode(p90, forKey: .p90)
        try c.encode(passRateAt07, forKey: .passRateAt07)
        var raw = [String: TierStats]()
        for (k, v) in perTier { raw[String(k)] = v }
        try c.encode(raw, forKey: .perTier)
        try c.encode(worst10, forKey: .worst10)
        try c.encodeIfPresent(regressions, forKey: .regressions)
    }
}

// MARK: - Aggregator

public enum Aggregator {

    /// Регрессией считается падение total на ≥ regressionThreshold от baseline.
    public static let regressionThreshold: Double = 0.10

    public static func summarize(
        records: [PerImageRecord],
        baseline: RunSummary?,
        runId: String = ISO8601DateFormatter().string(from: Date()),
        promptVersion: String = "unknown",
        modelName: String = "unknown"
    ) -> RunSummary {
        let totals = records.map { $0.score.total }
        let mean = average(totals)
        let p50 = percentile(totals, p: 0.50)
        let p90 = percentile(totals, p: 0.90)
        let pass = passRate(totals, threshold: 0.7)

        // per-tier
        var perTier = [Int: TierStats]()
        let byTier = Dictionary(grouping: records, by: { $0.tier })
        for (tier, recs) in byTier {
            let t = recs.map { $0.score.total }
            perTier[tier] = TierStats(
                count: t.count,
                mean: average(t),
                p50: percentile(t, p: 0.50),
                p90: percentile(t, p: 0.90),
                passRateAt07: passRate(t, threshold: 0.7)
            )
        }

        // worst-10 by total ascending
        let worst10: [WorstEntry] = records
            .sorted { $0.score.total < $1.score.total }
            .prefix(10)
            .map {
                WorstEntry(
                    id: $0.id,
                    total: $0.score.total,
                    firstNote: $0.score.notes.first
                )
            }

        // regressions vs baseline
        let regressions: [RegressionEntry]?
        if let baseline {
            // Baseline хранит aggregate, а не per-image. Чтобы детектить per-id регрессии,
            // нужен per-image baseline. Здесь принимаем, что caller уже передал baseline
            // с тем же набором id через worst10 + ... — но worst10 неполный.
            // Поэтому используем прокси: если у baseline есть worst10 с тем же id и наша
            // total упала на ≥ threshold — считаем регрессией. Для полной картины caller
            // должен передавать per-image baseline отдельно (см. compareAgainst).
            var out: [RegressionEntry] = []
            let baselineMap = Dictionary(uniqueKeysWithValues:
                baseline.worst10.map { ($0.id, $0.total) }
            )
            for r in records {
                if let bt = baselineMap[r.id] {
                    let delta = r.score.total - bt
                    if delta <= -regressionThreshold {
                        out.append(RegressionEntry(
                            id: r.id,
                            baselineTotal: bt,
                            currentTotal: r.score.total,
                            delta: delta
                        ))
                    }
                }
            }
            regressions = out
        } else {
            regressions = nil
        }

        return RunSummary(
            runId: runId,
            promptVersion: promptVersion,
            modelName: modelName,
            count: records.count,
            mean: mean,
            p50: p50,
            p90: p90,
            passRateAt07: pass,
            perTier: perTier,
            worst10: worst10,
            regressions: regressions
        )
    }

    /// Полная per-id регрессия: сравнивает текущие records с baseline records
    /// (а не с агрегированным RunSummary).
    public static func detectRegressions(
        current: [PerImageRecord],
        baseline: [PerImageRecord],
        threshold: Double = regressionThreshold
    ) -> [RegressionEntry] {
        let baselineMap = Dictionary(
            uniqueKeysWithValues: baseline.map { ($0.id, $0.score.total) }
        )
        var out: [RegressionEntry] = []
        for r in current {
            if let bt = baselineMap[r.id] {
                let delta = r.score.total - bt
                if delta <= -threshold {
                    out.append(RegressionEntry(
                        id: r.id,
                        baselineTotal: bt,
                        currentTotal: r.score.total,
                        delta: delta
                    ))
                }
            }
        }
        return out
    }

    // MARK: - Stats helpers

    private static func average(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        return xs.reduce(0, +) / Double(xs.count)
    }

    private static func percentile(_ xs: [Double], p: Double) -> Double {
        guard !xs.isEmpty else { return 0 }
        if xs.count == 1 { return xs[0] }
        let sorted = xs.sorted()
        // Linear interpolation. p ∈ [0..1].
        let pp = max(0, min(1, p))
        let idx = pp * Double(sorted.count - 1)
        let lo = Int(floor(idx))
        let hi = Int(ceil(idx))
        if lo == hi { return sorted[lo] }
        let frac = idx - Double(lo)
        return sorted[lo] + (sorted[hi] - sorted[lo]) * frac
    }

    private static func passRate(_ xs: [Double], threshold: Double) -> Double {
        guard !xs.isEmpty else { return 0 }
        let passed = xs.filter { $0 >= threshold }.count
        return Double(passed) / Double(xs.count)
    }
}
