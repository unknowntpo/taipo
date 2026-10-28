import Foundation

public struct SentenceScore: Equatable, Sendable {
    public let id: String
    public let reference: String
    public let hypothesis: String
    public let errors: Int
    public let tokens: Int
    public var mer: Double { tokens == 0 ? 0 : Double(errors) / Double(tokens) }
}

public struct EngineReport: Equatable, Sendable {
    public let engine: String
    public let scored: [SentenceScore]
    /// Sentences lacking a recording or a result; excluded from every metric.
    public let missing: [String]
    public let malformed: Int
    /// Corpus MER: total errors ÷ total reference tokens.
    public let mer: Double?
    public let merS2twp: Double?
    public let meanSeconds: Double?
    /// Total processing seconds ÷ total audio seconds, over sentences with a known duration.
    public let rtf: Double?
    public let worst: [SentenceScore]
}

public enum Report {
    /// `audioSeconds` fills in durations the engine did not record; `converted` is s2twp output by id.
    public static func engine(
        _ name: String,
        sentences: [Sentence],
        recorded: Set<String>,
        results: ResultFile,
        audioSeconds: [String: Double] = [:],
        converted: [String: String]? = nil
    ) -> EngineReport {
        var scored: [SentenceScore] = []
        var missing: [String] = []
        var convertedErrors = 0
        var seconds = 0.0
        var timedSeconds = 0.0
        var audio = 0.0
        for sentence in sentences {
            guard recorded.contains(sentence.id), let record = results.records[sentence.id] else {
                missing.append(sentence.id)
                continue
            }
            let (errors, tokens) = MER.errors(reference: sentence.text, hypothesis: record.text)
            scored.append(SentenceScore(id: sentence.id, reference: sentence.text, hypothesis: record.text,
                                        errors: errors, tokens: tokens))
            if let text = converted?[sentence.id] {
                convertedErrors += MER.errors(reference: sentence.text, hypothesis: text).errors
            }
            seconds += record.seconds
            if let duration = record.audioSeconds ?? audioSeconds[sentence.id], duration > 0 {
                timedSeconds += record.seconds
                audio += duration
            }
        }
        let tokens = scored.reduce(0) { $0 + $1.tokens }
        let errors = scored.reduce(0) { $0 + $1.errors }
        func ratio(_ n: Int) -> Double? { tokens == 0 ? nil : Double(n) / Double(tokens) }
        let worst = scored.enumerated()
            .sorted { $0.element.mer != $1.element.mer ? $0.element.mer > $1.element.mer : $0.offset < $1.offset }
            .prefix(5).map(\.element)
        return EngineReport(
            engine: name,
            scored: scored,
            missing: missing,
            malformed: results.malformed,
            mer: ratio(errors),
            merS2twp: converted == nil ? nil : ratio(convertedErrors),
            meanSeconds: scored.isEmpty ? nil : seconds / Double(scored.count),
            rtf: audio > 0 ? timedSeconds / audio : nil,
            worst: worst
        )
    }

    public static func render(_ reports: [EngineReport]) -> String {
        func cell(_ value: Double?, percent: Bool = false) -> String {
            guard let value else { return "-" }
            return percent ? String(format: "%.1f%%", value * 100) : String(format: "%.2f", value)
        }
        func pad(_ text: String, _ width: Int) -> String {
            text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
        }
        let header = ["engine", "scored", "missing", "malformed", "MER", "MER s2twp", "mean s", "RTF"]
        let rows = reports.map { r in
            [r.engine, "\(r.scored.count)", "\(r.missing.count)", "\(r.malformed)", cell(r.mer, percent: true),
             cell(r.merS2twp, percent: true), cell(r.meanSeconds), cell(r.rtf)]
        }
        let widths = header.indices.map { i in ([header] + rows).map { $0[i].count }.max()! }
        var lines = ([header] + rows).map { row in
            row.indices.map { pad(row[$0], widths[$0]) }.joined(separator: "  ")
        }
        for r in reports where !r.worst.isEmpty {
            lines.append("")
            lines.append("worst \(r.engine):")
            for s in r.worst {
                lines.append("  \(s.id) \(cell(s.mer, percent: true))  ref: \(s.reference)  hyp: \(s.hypothesis)")
            }
        }
        for r in reports where !r.missing.isEmpty {
            lines.append("")
            lines.append("missing \(r.engine): \(r.missing.joined(separator: " "))")
        }
        return lines.joined(separator: "\n")
    }
}
