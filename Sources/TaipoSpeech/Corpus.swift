import Foundation

public struct Sentence: Equatable, Sendable {
    public let id: String
    public let text: String

    public init(id: String, text: String) {
        self.id = id
        self.text = text
    }
}

/// One line of `results/<engine>.jsonl`.
public struct ResultRecord: Codable, Equatable, Sendable {
    public let id: String
    public let engine: String
    public let text: String
    public let seconds: Double
    public let audioSeconds: Double?

    enum CodingKeys: String, CodingKey {
        case id, engine, text, seconds
        case audioSeconds = "audio_seconds"
    }

    public init(id: String, engine: String, text: String, seconds: Double, audioSeconds: Double?) {
        self.id = id
        self.engine = engine
        self.text = text
        self.seconds = seconds
        self.audioSeconds = audioSeconds
    }
}

public struct ResultFile: Equatable, Sendable {
    /// Last record per id.
    public let records: [String: ResultRecord]
    public let malformed: Int
}

public enum Corpus {
    /// `id<TAB>text` per line; blank lines skipped.
    public static func sentences(tsv: String) -> [Sentence] {
        tsv.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 1)
            guard fields.count == 2 else { return nil }
            return Sentence(id: String(fields[0]), text: String(fields[1]))
        }
    }

    /// Malformed lines are counted and skipped; blank lines are ignored.
    public static func results(jsonl: String) -> ResultFile {
        var records: [String: ResultRecord] = [:]
        var malformed = 0
        for line in jsonl.split(whereSeparator: \.isNewline) where !line.allSatisfy(\.isWhitespace) {
            if let record = try? JSONDecoder().decode(ResultRecord.self, from: Data(line.utf8)) {
                records[record.id] = record
            } else {
                malformed += 1
            }
        }
        return ResultFile(records: records, malformed: malformed)
    }
}
