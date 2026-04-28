import Testing
import Foundation
@testable import FoodEval

private func mkRecord(
    id: String,
    tier: Int = 1,
    total: Double,
    notes: [String] = []
) -> PerImageRecord {
    let breakdown = ScoreBreakdown(
        structural: 1,
        name: 1,
        calories: total,
        protein: total,
        carbs: total,
        fats: total,
        macros: total,
        total: total,
        notes: notes
    )
    return PerImageRecord(
        id: id,
        image: "tier\(tier)/\(id).jpg",
        tier: tier,
        category: "test",
        rawOutput: "{}",
        parsed: nil,
        score: breakdown,
        durationMs: 100
    )
}

@Suite("Aggregator")
struct AggregatorTests {

    @Test("summary statistics: mean / p50 / p90 / passRate")
    func summaryStatistics() {
        // 10 точек: 0.1, 0.2, 0.3, ..., 1.0
        // mean = 0.55, p50 ≈ 0.55, p90 ≈ 0.91, passRate@0.7 = 4/10 = 0.4 (0.7,0.8,0.9,1.0)
        let totals: [Double] = [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0]
        let records = totals.enumerated().map { (i, t) in
            mkRecord(id: "img\(i)", tier: (i % 3) + 1, total: t)
        }

        let summary = Aggregator.summarize(
            records: records,
            baseline: nil,
            promptVersion: "v1",
            modelName: "qwen2"
        )

        #expect(summary.count == 10)
        #expect(abs(summary.mean - 0.55) < 1e-9)
        // p50 by linear interp at idx=4.5 → (0.5+0.6)/2 = 0.55
        #expect(abs(summary.p50 - 0.55) < 1e-9)
        // p90 at idx=8.1 → 0.9 + 0.1*(1.0-0.9) = 0.91
        #expect(abs(summary.p90 - 0.91) < 1e-9)
        #expect(abs(summary.passRateAt07 - 0.4) < 1e-9)
        #expect(summary.regressions == nil)

        // Worst-10 — все 10, отсортированы по возрастанию total.
        #expect(summary.worst10.count == 10)
        #expect(summary.worst10.first?.id == "img0")
        #expect(summary.worst10.first?.total == 0.1)

        // Per-tier
        // tier=1: img0(0.1), img3(0.4), img6(0.7), img9(1.0) → mean=0.55
        // tier=2: img1(0.2), img4(0.5), img7(0.8) → mean=0.5
        // tier=3: img2(0.3), img5(0.6), img8(0.9) → mean=0.6
        #expect(summary.perTier[1]?.count == 4)
        #expect(summary.perTier[2]?.count == 3)
        #expect(summary.perTier[3]?.count == 3)
    }

    @Test("passRate edge: all above threshold = 1.0")
    func allPassRate() {
        let records = [
            mkRecord(id: "a", total: 0.7),
            mkRecord(id: "b", total: 0.8),
            mkRecord(id: "c", total: 0.95),
        ]
        let summary = Aggregator.summarize(records: records, baseline: nil)
        #expect(summary.passRateAt07 == 1.0)
    }

    @Test("regression detection finds correct ids")
    func regressionDetection() {
        // Baseline records: a=0.9, b=0.8, c=0.5
        let baselineRecords = [
            mkRecord(id: "a", total: 0.9),
            mkRecord(id: "b", total: 0.8),
            mkRecord(id: "c", total: 0.5),
        ]
        // Current records: a=0.95 (better), b=0.65 (regression: -0.15), c=0.35 (regression: -0.15)
        // Используем -0.15, а не -0.10, чтобы избежать double-arithmetic edge case
        // (0.40 - 0.5 = -0.0999...8, что чуть > -0.10).
        let currentRecords = [
            mkRecord(id: "a", total: 0.95),
            mkRecord(id: "b", total: 0.65),
            mkRecord(id: "c", total: 0.35),
        ]

        let regs = Aggregator.detectRegressions(
            current: currentRecords,
            baseline: baselineRecords
        )

        let ids = Set(regs.map { $0.id })
        #expect(ids.contains("b"))
        #expect(ids.contains("c"))
        #expect(!ids.contains("a"))

        // Проверим точные дельты
        if let bReg = regs.first(where: { $0.id == "b" }) {
            #expect(abs(bReg.delta - (-0.15)) < 1e-9)
            #expect(bReg.baselineTotal == 0.8)
            #expect(bReg.currentTotal == 0.65)
        } else {
            Issue.record("expected regression for id=b")
        }
    }

    @Test("regression: drop below threshold not flagged")
    func smallDropNotFlagged() {
        // delta = -0.05 — ниже threshold 0.10 → не регрессия
        let baseline = [mkRecord(id: "a", total: 0.9)]
        let current = [mkRecord(id: "a", total: 0.85)]
        let regs = Aggregator.detectRegressions(current: current, baseline: baseline)
        #expect(regs.isEmpty)
    }

    @Test("regression: no baseline → regressions == nil")
    func noBaselineNoRegressions() {
        let records = [mkRecord(id: "a", total: 0.5)]
        let summary = Aggregator.summarize(records: records, baseline: nil)
        #expect(summary.regressions == nil)
    }

    @Test("RunSummary roundtrips through JSON")
    func runSummaryJSONRoundtrip() throws {
        let records = [
            mkRecord(id: "a", tier: 1, total: 0.9),
            mkRecord(id: "b", tier: 2, total: 0.6),
        ]
        let summary = Aggregator.summarize(
            records: records,
            baseline: nil,
            runId: "2026-04-28T10:00:00Z",
            promptVersion: "v1",
            modelName: "qwen2"
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(summary)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(RunSummary.self, from: data)

        #expect(decoded.runId == summary.runId)
        #expect(decoded.count == summary.count)
        #expect(decoded.perTier.keys.sorted() == [1, 2])
        #expect(decoded.perTier[1]?.mean == 0.9)
        #expect(decoded.perTier[2]?.mean == 0.6)
    }
}
