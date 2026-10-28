import Foundation

public enum LexiconError: Error, Equatable {
    case unreadable(URL)
    case malformed(URL, line: Int)
}

/// Immutable bundled dictionaries: Zhuyin key strings → phrases, and English words.
public final class Lexicon: Sendable {
    let zh: Trie
    let en: Trie

    /// zh rows: `keys<TAB>phrase<TAB>count`, grouped by keys; en rows: `word<TAB>scowlSize`.
    public init(zhURL: URL, enURL: URL) throws {
        zh = try Lexicon.load(zhURL, columns: 3) { cols in
            (cols[0], cols[1], Lexicon.integer(cols[2]).map { Double($0) + 1 })
        }
        en = try Lexicon.load(enURL, columns: 2) { cols in
            (cols[0], cols[0], Lexicon.integer(cols[1]).map { Lexicon.weight(scowlSize: Double($0)) })
        }
    }

    /// SCOWL size 35 is the most common tier; each +10 is ~10x rarer.
    static func weight(scowlSize: Double) -> Double { pow(10, (70 - scowlSize) / 10) }

    public static func bundled() throws -> Lexicon {
        guard let zh = Bundle.module.url(forResource: "zh", withExtension: "tsv"),
              let en = Bundle.module.url(forResource: "en", withExtension: "tsv")
        else { throw LexiconError.unreadable(Bundle.module.bundleURL) }
        return try Lexicon(zhURL: zh, enURL: en)
    }

    func containsEnglish(_ word: String) -> Bool {
        en.node(for: word.utf8).map(en.hasEntries) ?? false
    }

    func containsChinese(_ phrase: String, keys: String) -> Bool {
        guard let node = zh.node(for: keys.utf8) else { return false }
        return zh.entries(at: node).contains { $0.text == phrase }
    }

    typealias Field = UnsafeBufferPointer<UInt8>

    /// Single pass: each row yields (key, text, weight); log-probabilities are
    /// normalised by the total weight once all rows are read.
    private static func load(_ url: URL, columns: Int,
                             _ row: ([Field]) -> (key: Field, text: Field, weight: Double?)) throws -> Trie {
        guard let data = try? Data(contentsOf: url) else { throw LexiconError.unreadable(url) }
        var trie = Trie()
        var total = 0.0
        var lines = 0
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            var start = 0
            var fields: [Field] = []
            fields.reserveCapacity(columns)
            while start < bytes.count {
                var end = start
                while end < bytes.count, bytes[end] != 10 { end += 1 }
                if end > start {
                    lines += 1
                    fields.removeAll(keepingCapacity: true)
                    var fieldStart = start
                    for i in start...end where i == end || bytes[i] == 9 {
                        fields.append(Field(rebasing: bytes[fieldStart..<i]))
                        fieldStart = i + 1
                    }
                    guard fields.count == columns, !fields[0].isEmpty else { throw LexiconError.malformed(url, line: lines) }
                    let (key, text, weight) = row(fields)
                    guard let weight, weight > 0 else { throw LexiconError.malformed(url, line: lines) }
                    total += weight
                    let entry = Entry(text: String(decoding: text, as: UTF8.self), logp: Float(log(weight)))
                    guard trie.append(key: key, entry: entry) else { throw LexiconError.malformed(url, line: lines) }
                }
                start = end + 1
            }
        }
        if lines == 0 { throw LexiconError.malformed(url, line: 0) }
        trie.finish(logpOffset: -Float(log(total)))
        return trie
    }

    private static func integer(_ field: Field) -> Int? {
        guard !field.isEmpty else { return nil }
        var value = 0
        for byte in field {
            guard (48...57).contains(byte) else { return nil }
            value = value * 10 + Int(byte - 48)
        }
        return value
    }
}
