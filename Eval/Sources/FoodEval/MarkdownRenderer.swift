import Foundation

// MARK: - MarkdownRenderer
//
// Рендерит RunSummary → Markdown для Reports/latest.md. Формат описан в
// плане Wave 4 (секция "Reports/latest.md") — секции:
//   - заголовок с runId, prompt, model, count
//   - aggregate stats + дельта к baseline
//   - per-tier breakdown
//   - worst-10
//   - regressions (если есть baseline)
//
// Если baseline = nil — пишем "(first run)" в дельтах.

public enum MarkdownRenderer {

    public static func render(
        summary: RunSummary,
        baseline: RunSummary?
    ) -> String {
        var lines: [String] = []

        // ---- Header ----
        lines.append("# FoodRecognizer VLM Eval — \(summary.runId)")
        lines.append("")
        lines.append("- **Prompt:** \(summary.promptVersion)")
        lines.append("- **Model:** \(summary.modelName)")
        lines.append("- **Images:** \(summary.count)")
        if let baseline {
            lines.append("- **Baseline:** \(baseline.runId) (mean \(fmt(baseline.mean)))")
        } else {
            lines.append("- **Baseline:** (first run)")
        }
        lines.append("")

        // ---- Aggregate ----
        lines.append("## Aggregate")
        lines.append("")
        lines.append("| Metric    | Current | Baseline | Δ |")
        lines.append("| --------- | ------- | -------- | --- |")
        lines.append(metricRow("mean",       current: summary.mean,         baseline: baseline?.mean))
        lines.append(metricRow("p50",        current: summary.p50,          baseline: baseline?.p50))
        lines.append(metricRow("p90",        current: summary.p90,          baseline: baseline?.p90))
        lines.append(metricRow("pass@0.7",   current: summary.passRateAt07, baseline: baseline?.passRateAt07))
        lines.append("")

        // ---- Per-tier ----
        lines.append("## Per-tier")
        lines.append("")
        lines.append("| Tier | Count | Mean | p50 | p90 | pass@0.7 |")
        lines.append("| ---- | ----- | ---- | --- | --- | -------- |")
        for tier in summary.perTier.keys.sorted() {
            guard let stats = summary.perTier[tier] else { continue }
            lines.append(
                "| \(tier) | \(stats.count) | \(fmt(stats.mean)) | \(fmt(stats.p50)) | \(fmt(stats.p90)) | \(fmtPct(stats.passRateAt07)) |"
            )
        }
        lines.append("")

        // ---- Worst 10 ----
        lines.append("## Worst 10")
        lines.append("")
        if summary.worst10.isEmpty {
            lines.append("_no entries_")
        } else {
            lines.append("| ID | Total | Note |")
            lines.append("| -- | ----- | ---- |")
            for w in summary.worst10 {
                let note = (w.firstNote ?? "").replacingOccurrences(of: "|", with: "\\|")
                lines.append("| \(w.id) | \(fmt(w.total)) | \(note) |")
            }
        }
        lines.append("")

        // ---- Regressions ----
        if let regressions = summary.regressions {
            lines.append("## Regressions vs baseline")
            lines.append("")
            if regressions.isEmpty {
                lines.append("_none_")
            } else {
                lines.append("| ID | Baseline | Current | Δ |")
                lines.append("| -- | -------- | ------- | --- |")
                for r in regressions {
                    lines.append(
                        "| \(r.id) | \(fmt(r.baselineTotal)) | \(fmt(r.currentTotal)) | \(fmtDelta(r.delta)) |"
                    )
                }
            }
            lines.append("")
        }

        return lines.joined(separator: "\n") + "\n"
    }

    /// Compare-table для нескольких best-run'ов. Используется `compare` командой.
    /// Берём первую summary как baseline для дельт.
    public static func renderCompare(
        summaries: [(promptVersion: String, summary: RunSummary)]
    ) -> String {
        guard !summaries.isEmpty else { return "_no runs to compare_\n" }
        var lines: [String] = []
        lines.append("| Prompt | Mean | p50 | p90 | pass@0.7 | tier1 | tier2 | tier3 |")
        lines.append("| ------ | ---- | --- | --- | -------- | ----- | ----- | ----- |")

        for entry in summaries {
            let s = entry.summary
            let t1 = s.perTier[1].map { fmt($0.mean) } ?? "-"
            let t2 = s.perTier[2].map { fmt($0.mean) } ?? "-"
            let t3 = s.perTier[3].map { fmt($0.mean) } ?? "-"
            lines.append(
                "| \(entry.promptVersion) | \(fmt(s.mean)) | \(fmt(s.p50)) | \(fmt(s.p90)) | \(passCountString(s)) | \(t1) | \(t2) | \(t3) |"
            )
        }

        // Δ-row: только если ≥ 2 промта.
        if summaries.count >= 2 {
            let base = summaries[0].summary
            let last = summaries[summaries.count - 1].summary
            let label = "Δ \(summaries[summaries.count - 1].promptVersion)/\(summaries[0].promptVersion)"
            let dt1: String = {
                guard let cur = last.perTier[1], let bs = base.perTier[1] else { return "-" }
                return fmtDelta(cur.mean - bs.mean)
            }()
            let dt2: String = {
                guard let cur = last.perTier[2], let bs = base.perTier[2] else { return "-" }
                return fmtDelta(cur.mean - bs.mean)
            }()
            let dt3: String = {
                guard let cur = last.perTier[3], let bs = base.perTier[3] else { return "-" }
                return fmtDelta(cur.mean - bs.mean)
            }()
            let dPass: String = {
                let bsPassed = Int((base.passRateAt07 * Double(base.count)).rounded())
                let curPassed = Int((last.passRateAt07 * Double(last.count)).rounded())
                let diff = curPassed - bsPassed
                return (diff >= 0 ? "+" : "") + String(diff)
            }()
            lines.append(
                "| \(label) | \(fmtDelta(last.mean - base.mean)) | \(fmtDelta(last.p50 - base.p50)) | \(fmtDelta(last.p90 - base.p90)) | \(dPass) | \(dt1) | \(dt2) | \(dt3) |"
            )
        }

        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Helpers

    private static func metricRow(_ label: String, current: Double, baseline: Double?) -> String {
        if let baseline {
            let delta = current - baseline
            return "| \(label) | \(fmt(current)) | \(fmt(baseline)) | \(fmtDelta(delta)) |"
        } else {
            return "| \(label) | \(fmt(current)) | — | (first run) |"
        }
    }

    private static func fmt(_ v: Double) -> String {
        return String(format: "%.3f", v)
    }

    private static func fmtPct(_ v: Double) -> String {
        // pass@0.7 — это [0..1], рендерим в "0.667" формате как доля.
        return String(format: "%.3f", v)
    }

    private static func fmtDelta(_ v: Double) -> String {
        let sign = v >= 0 ? "+" : ""
        return "\(sign)\(String(format: "%.3f", v))"
    }

    private static func passCountString(_ s: RunSummary) -> String {
        let passed = Int((s.passRateAt07 * Double(s.count)).rounded())
        return "\(passed)/\(s.count)"
    }
}
