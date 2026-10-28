import Foundation

public enum Language: String, Codable, Sendable {
    case zh, en
}

public struct Candidate: Sendable, Equatable {
    /// `mixed`: Chinese and English segments (Spec 003); `partial`: ends in an unfinished tail.
    public enum Source: String, Sendable { case lexicon, user, learned, literal, mixed, partial }

    public struct Segment: Sendable, Equatable {
        public let text: String
        public let language: Language
        public let isTail: Bool
        /// Key offset (UTF-8) in the input where this segment ends (Spec 005 auto-commit).
        public let end: Int

        /// Joins segments as displayed: a space wherever an English segment meets another one.
        public static func join(_ segments: some Sequence<Segment>) -> String {
            var text = ""
            var previous: Segment?
            for segment in segments {
                if let previous, !segment.isTail, segment.language == .en || previous.language == .en { text += " " }
                text += segment.text
                previous = segment
            }
            return text
        }
    }

    public let text: String
    public let language: Language
    public let edits: [Edit]
    public let score: Double
    public let source: Source
    /// Segments with their key spans (Chinese sentences, mixed and partial candidates).
    public var segments: [Segment] = []

}

public struct DecodeResult: Sendable {
    public let candidates: [Candidate]
    public let fuzzyEnabled: Bool
    public let maxEdits: Int
}

/// Turns one buffer of typed keys into ranked candidates, reading it both as
/// Dachen Zhuyin and as English, with adjacent-key fuzzy correction.
public final class Decoder {
    static let maxKeys = 32
    public static let editPenalty = 6.0
    static let userWordLogp = Float(log(0.001))
    static let candidateLimit = 20
    /// Spec 006: alternative paths kept per DP cell (position, edits used).
    static let pathsPerCell = 2
    /// Spec 006: the adaptive retry never goes beyond this budget…
    static let maxRetryBudget = 3
    /// …and only runs on inputs of this many keys: short ones (`123`, `JI3`) turn into guesses
    /// when half their keys are edited; long ones auto-commit (Spec 005).
    static let retryMinKeys = 6
    static let retryMaxKeys = 24
    /// Spec 003: switching language costs as much as one edit, so rare short English
    /// words (vi, cu, sue) cannot turn a one-key Zhuyin typo into a mixed sentence.
    static let switchPenalty = editPenalty
    /// Spec 003: an unfinished tail costs less than one edit so fuzzy fixes do not swallow it.
    static func tailPenalty(keys: Int) -> Double { 2.0 + Double(keys) }
    /// Spec 005: smallest input that may fall back to "parsed prefix + remaining keys".
    static let remainderMinKeys = 12

    /// Transposition is the most common fast-typing slip, so it costs a bit less;
    /// this also breaks ties left by SCOWL's coarse frequency tiers (the / ten).
    public static func penalty(_ edits: [Edit]) -> Double {
        edits.reduce(0) { sum, edit in
            if case .transpose = edit { return sum + editPenalty * 0.8 }
            return sum + editPenalty
        }
    }

    private let lexicon: Lexicon
    private var user: UserDictionary
    private var userZh = Trie()
    private var userEn = Trie()

    public var diagnostics: [String] { user.diagnostics }

    public init(lexicon: Lexicon, userDictionaryURL: URL) throws {
        self.lexicon = lexicon
        user = UserDictionary(url: userDictionaryURL)
        rebuildUserTries()
    }

    static func editBudget(keyCount n: Int) -> Int {
        switch n {
        case ...2: 0
        case ...5: 1
        default: 2
        }
    }

    /// Whether a deep pass could change the result for this input (Spec 006).
    public static func canDeepen(_ input: String) -> Bool {
        (retryMinKeys...retryMaxKeys).contains(input.utf8.count)
    }

    public func candidates(for input: String, previousLanguage: Language?) -> [Candidate] {
        decode(input, previousLanguage: previousLanguage).candidates
    }

    /// `deep: true` (Spec 006) may retry with one more edit; it is meant for a pause in typing,
    /// not for every keystroke (a 6–24-key retry costs tens of milliseconds).
    public func decode(_ input: String, previousLanguage: Language?, deep: Bool = false) -> DecodeResult {
        if input.isEmpty { return DecodeResult(candidates: [], fuzzyEnabled: false, maxEdits: 0) }
        let literal = Candidate(text: input, language: .en, edits: [], score: -.infinity, source: .literal)
        guard input.count <= Decoder.maxKeys else {
            return DecodeResult(candidates: [literal], fuzzyEnabled: false, maxEdits: 0)
        }
        // Spec 006: if every real candidate used up the whole budget (or there is none), the typing
        // was messier than the budget allows — a deep pass retries once with one more edit.
        var budget = Decoder.editBudget(keyCount: input.count)
        var ordered = ranked(input, previousLanguage: previousLanguage, budget: budget, maxMissing: budget)
        let real = ordered.filter { $0.source != .literal && $0.source != .partial }
        if deep, Decoder.canDeepen(input), budget < Decoder.maxRetryBudget,
           real.allSatisfy({ $0.edits.count >= budget }) {
            budget += 1
            ordered = ranked(input, previousLanguage: previousLanguage, budget: budget, maxMissing: 1)
        }
        if let chosen = user.choices[input] {
            ordered.removeAll { $0.text == chosen }
            ordered.insert(Candidate(text: chosen, language: Decoder.language(of: chosen), edits: [], score: 0, source: .learned), at: 0)
        }
        var seen = Set<String>()
        ordered = ordered.filter { seen.insert($0.text).inserted }
        if !seen.contains(input) { ordered.append(literal) }
        return DecodeResult(candidates: ordered, fuzzyEnabled: budget > 0, maxEdits: budget)
    }

    /// One decoding pass at a fixed edit budget, ordered per Spec 001 B6 / Spec 003.
    private func ranked(_ input: String, previousLanguage: Language?, budget: Int, maxMissing: Int) -> [Candidate] {
        let zhMatches = ZhMatches(tries: [lexicon.zh, userZh], keys: Array(input.utf8), budget: budget, maxMissing: maxMissing)
        let protected = trailingEnglishWord(input)
        let keepsWord: (Candidate) -> Bool = { c in
            !c.edits.contains { protected.contains($0.position) }
        }
        let zh = zhCandidates(input, budget: budget, matches: zhMatches).filter(keepsWord)
        let en = enCandidates(input, budget: budget, maxMissing: maxMissing)

        let ordered: [Candidate]
        let zhExact = zh.contains { $0.edits.isEmpty }
        let enExact = en.contains { $0.edits.isEmpty }
        if zhExact != enExact {
            ordered = zhExact ? zh + en : en + zh
        } else if zhExact {
            ordered = (previousLanguage ?? .zh) == .zh ? zh + en : en + zh
        } else {
            let mixed = mixedCandidates(input, budget: budget, maxMissing: maxMissing, matches: zhMatches).filter(keepsWord)
            ordered = (zh + en + mixed).sorted { ($0.score, $1.text) > ($1.score, $0.text) }
        }
        return ordered
    }

    /// Spec 017: whether typing `key` after `buffer` still reads as Zhuyin. True when the keys after the
    /// buffer's last tone key, plus `key`, start some Chinese reading (`a` + `8` = ㄇㄚ), or when
    /// `buffer + key` decodes, without edits, to Chinese first (`hellosu` + `3` = hello 你).
    public func continuesChinese(_ buffer: String, with key: Character, previousLanguage: Language? = nil) -> Bool {
        let keys = Array(buffer.utf8)
        let start = keys.lastIndex(where: Decoder.toneKeys.contains).map { $0 + 1 } ?? 0
        let syllable = keys[start...] + Array(String(key).utf8)
        if [lexicon.zh, userZh].contains(where: { $0.node(for: syllable) != nil }) { return true }
        guard let top = decode(buffer + String(key), previousLanguage: previousLanguage).candidates.first else { return false }
        return top.language == .zh && top.edits.isEmpty && top.source != .literal
    }

    public func learn(input: String, chosen: String) throws {
        defer { rebuildUserTries() }
        try user.record(input: input, chosen: chosen, newWord: newUserWord(input: input, chosen: chosen))
    }

    /// Spec 010: forgets every learned choice and word in memory; the file is the caller's job.
    public func clearUserDictionary() {
        user.clear()
        rebuildUserTries()
    }

    public func explain(_ input: String, previousLanguage: Language?) -> String {
        let result = decode(input, previousLanguage: previousLanguage)
        var lines = ["input: \"\(input)\" (\(input.count) keys)",
                     "fuzzy: \(result.fuzzyEnabled ? "on" : "off") (max edits \(result.maxEdits))"]
        for (i, c) in result.candidates.enumerated() {
            let edits = c.edits.isEmpty ? "none" : c.edits.map(\.description).joined(separator: ", ")
            let penalty = Decoder.penalty(c.edits)
            let parts = c.source == .literal || c.source == .learned || !c.segments.isEmpty ? "" :
                String(format: " = logp %.2f − penalty %.2f", c.score + penalty, penalty)
            let segments = c.source != .mixed && c.source != .partial ? "" : " segments: " + c.segments
                .map { "\($0.text)[\($0.isTail ? "tail" : $0.language.rawValue)]" }.joined(separator: " | ")
            lines.append("\(i + 1). \(c.text) [\(c.language.rawValue)] source=\(c.source.rawValue) score=\(String(format: "%.2f", c.score))\(parts) edits: \(edits)\(segments)")
        }
        return lines.joined(separator: "\n")
    }

    /// Per-decode memo of Zhuyin walks, shared by the Chinese and mixed DPs.
    private final class ZhMatches {
        private var memo: [Int: [(trie: Int, match: Match)]] = [:]
        private let tries: [Trie]
        private let keys: [UInt8]
        private let budget: Int
        private let maxMissing: Int

        init(tries: [Trie], keys: [UInt8], budget: Int, maxMissing: Int) {
            self.tries = tries
            self.keys = keys
            self.budget = budget
            self.maxMissing = maxMissing
        }

        func from(_ start: Int) -> [(trie: Int, match: Match)] {
            if let hit = memo[start] { return hit }
            let found = tries.indices.flatMap { t in
                fuzzyMatches(in: tries[t], input: keys, start: start, maxEdits: budget, requireEnd: false,
                             maxMissing: maxMissing).map { (t, $0) }
            }
            memo[start] = found
            return found
        }

        func trie(_ t: Int) -> Trie { tries[t] }
    }

    // MARK: - Zhuyin

    private struct Path {
        var score: Double
        var texts: [String]
        var ends: [Int] = []
        var edits: [Edit]
    }

    private func zhCandidates(_ input: String, budget: Int, matches: ZhMatches) -> [Candidate] {
        let keys = Array(input.utf8)
        guard keys.allSatisfy(Layout.zhuyinKeys.contains) else { return [] }
        let n = keys.count
        // Spec 006: keep the best `pathsPerCell` paths per (position, edits), not just one, so a
        // multi-phrase input still offers the runner-up segmentations.
        var best = [[[Path]]](repeating: [[Path]](repeating: [], count: budget + 1), count: n + 1)
        best[0][0] = [Path(score: 0, texts: [], edits: [])]
        var singles: [Candidate] = []

        func keep(_ path: Path, at end: Int, edits e: Int) {
            var cell = best[end][e]
            if let same = cell.firstIndex(where: { $0.texts == path.texts }) {
                guard cell[same].score < path.score else { return }
                cell.remove(at: same)
            }
            let slot = cell.firstIndex { $0.score < path.score } ?? cell.endIndex
            guard slot < Decoder.pathsPerCell else { return }
            cell.insert(path, at: slot)
            if cell.count > Decoder.pathsPerCell { cell.removeLast() }
            best[end][e] = cell
        }

        for i in 0..<n where best[i].contains(where: { !$0.isEmpty }) {
            for (t, m) in matches.from(i) {
                let trie = matches.trie(t)
                let source: Candidate.Source = t == 0 ? .lexicon : .user
                do {
                    let entries = trie.entries(at: m.node)
                    let cost = Decoder.penalty(m.edits)
                    if i == 0, m.end == n {
                        for entry in entries.prefix(10) {
                            singles.append(Candidate(text: entry.text, language: .zh, edits: m.edits,
                                                     score: Double(entry.logp) - cost, source: source,
                                                     segments: [.init(text: entry.text, language: .zh, isTail: false, end: n)]))
                        }
                    }
                    guard let top = entries.first else { continue }
                    for e in 0...budget - m.edits.count {
                        for path in best[i][e] {
                            keep(Path(score: path.score + Double(top.logp) - cost,
                                      texts: path.texts + [top.text], ends: path.ends + [m.end], edits: path.edits + m.edits),
                                 at: m.end, edits: e + m.edits.count)
                        }
                    }
                }
            }
        }
        let sentences = best[n].flatMap { $0 }.filter { $0.texts.count > 1 }.map {
            Candidate(text: $0.texts.joined(), language: .zh, edits: $0.edits, score: $0.score, source: .lexicon,
                      segments: zip($0.texts, $0.ends).map { .init(text: $0, language: .zh, isTail: false, end: $1) })
        }
        return Decoder.rank(singles + sentences)
    }

    // MARK: - Mixed (Spec 003)

    /// Key range of an English word typed right after a completed syllable at the
    /// end of the input. No edit may touch those keys (Spec 003 Behavior 7): otherwise `這個`
    /// (two deletions) or `這個於` (y→6) beat `這個 is` / `這個 my`, since SCOWL scores short words low.
    private func trailingEnglishWord(_ input: String) -> Range<Int> {
        let keys = Array(input.utf8)
        var start = keys.count
        while start > 0, Decoder.isLetter(keys[start - 1]) { start -= 1 }
        guard start > 0, start < keys.count, Decoder.toneKeys.contains(keys[start - 1]),
              lexicon.containsEnglish(String(decoding: keys[start...], as: UTF8.self).lowercased())
        else { return 0..<0 }
        return start..<keys.count
    }

    private struct MixedPath {
        var score: Double
        var segments: [Candidate.Segment]
        var edits: [Edit]
    }

    private static func isLetter(_ b: UInt8) -> Bool { (65...90).contains(b) || (97...122).contains(b) }
    private static let toneKeys = Set(" 6347".utf8)

    /// Splits the keys into Chinese phrases and English words (≥ 2 letters: every single
    /// letter is a lexicon word and would turn Zhuyin typos into "r 惡"), with an
    /// optional unfinished tail after a Chinese segment.
    private func mixedCandidates(_ input: String, budget: Int, maxMissing: Int, matches: ZhMatches) -> [Candidate] {
        let keys = Array(input.utf8)
        // Every mixed candidate has a Chinese segment, which ends in a typed tone key.
        guard keys.contains(where: Decoder.toneKeys.contains),
              keys.allSatisfy({ Layout.zhuyinKeys.contains($0) || Decoder.isLetter($0) }) else { return [] }
        let lower = Array(input.lowercased().utf8)
        let n = keys.count
        var best = [[MixedPath?]](repeating: [MixedPath?](repeating: nil, count: budget + 1), count: n + 1)
        best[0][0] = MixedPath(score: 0, segments: [], edits: [])
        var bestTail: MixedPath?

        func extend(_ i: Int, to end: Int, _ segment: Candidate.Segment, logp: Double, edits: [Edit]) {
            for e in 0...(budget - edits.count) {
                guard let path = best[i][e] else { continue }
                let switching = path.segments.last.map { $0.language != segment.language } ?? false
                let next = MixedPath(score: path.score + logp - Decoder.penalty(edits) - (switching ? Decoder.switchPenalty : 0),
                                     segments: path.segments + [segment], edits: path.edits + edits)
                let ne = e + edits.count
                if best[end][ne].map({ $0.score < next.score }) ?? true { best[end][ne] = next }
            }
        }

        for i in 0..<n where best[i].contains(where: { $0 != nil }) {
            for (t, m) in matches.from(i) {
                guard let top = matches.trie(t).entries(at: m.node).first else { continue }
                extend(i, to: m.end, .init(text: top.text, language: .zh, isTail: false, end: m.end), logp: Double(top.logp), edits: m.edits)
            }
            // English words start the input or follow a completed syllable (a tone key).
            if Decoder.isLetter(keys[i]), i == 0 || Decoder.toneKeys.contains(keys[i - 1]) {
                for trie in [lexicon.en, userEn] {
                    for m in fuzzyMatches(in: trie, input: lower, start: i, maxEdits: budget, requireEnd: false, maxMissing: maxMissing)
                    where (i..<m.end).allSatisfy({ Decoder.isLetter(keys[$0]) }) {
                        guard let top = trie.entries(at: m.node).first, top.text.count >= 2 else { continue }
                        let segment = Candidate.Segment(text: top.text, language: .en, isTail: false, end: m.end)
                        extend(i, to: m.end, segment, logp: Double(top.logp), edits: m.edits)
                        if m.end < n, keys[m.end] == 32 {
                            let spaced = Candidate.Segment(text: top.text, language: .en, isTail: false, end: m.end + 1)
                            extend(i, to: m.end + 1, spaced, logp: Double(top.logp), edits: m.edits)
                        }
                    }
                }
            }
            let tail = n - i
            // A tail must be how some syllable starts (ㄨ yes, ㄜㄧ no); otherwise it is a typo for fuzzy fixing.
            // Toneless syllable starts are at most 3 keys (ㄒㄧㄤ), so no explicit length cap is needed.
            if tail > 0, !keys[i...].contains(where: Decoder.toneKeys.contains),
               lexicon.zh.node(for: keys[i...]) != nil {
                let text = String(decoding: keys[i...], as: UTF8.self)
                // Any prefix may carry edits: garbage tails (zxv) are already excluded by the
                // syllable-start rule above (Spec 005 relaxed Spec 003 X7).
                for case let path? in best[i] where path.segments.last?.language == .zh {
                    // After an edited prefix the tail costs one more edit, so dropping a real key to
                    // leave a tail (理e, −g) never beats a one-key fix of a full parse (理事).
                    let extra = path.edits.isEmpty ? 0 : Decoder.editPenalty
                    let next = MixedPath(score: path.score - Decoder.tailPenalty(keys: tail) - extra,
                                         segments: path.segments + [.init(text: text, language: .zh, isTail: true, end: n)], edits: path.edits)
                    if bestTail.map({ $0.score < next.score }) ?? true { bestTail = next }
                }
            }
        }

        // Spec 005: nothing parses the whole input → longest parsed prefix + the remaining keys
        // as typed, ranked below every real parse (but above the bare literal).
        var remainder: MixedPath?
        // Only for long inputs where most keys parsed; short garbage (`123`, `JI3`) stays literal.
        if n >= Decoder.remainderMinKeys, best[n].allSatisfy({ $0 == nil }), bestTail == nil,
           let i = (1..<n).last(where: { i in best[i].contains { $0?.segments.isEmpty == false } }), i * 2 >= n,
           let path = best[i].compactMap({ $0 }).max(by: { $0.score < $1.score }) {
            let rest = String(decoding: keys[i...], as: UTF8.self)
            remainder = MixedPath(score: path.score - Decoder.editPenalty * Double(n - i),
                                  segments: path.segments + [.init(text: rest, language: .zh, isTail: true, end: n)],
                                  edits: path.edits)
        }

        // Tails live apart from full parses so a 0-edit parse is never displaced by one.
        return (best[n].compactMap { $0 } + [bestTail, remainder].compactMap { $0 }).filter { path in
            path.segments.contains(where: \.isTail) || Set(path.segments.map(\.language)).count > 1
        }.map { path in
            let text = Candidate.Segment.join(path.segments)
            let hasTail = path.segments.contains(where: \.isTail)
            let language = path.segments.last(where: { !$0.isTail })?.language ?? .zh
            return Candidate(text: text, language: language, edits: path.edits, score: path.score,
                             source: hasTail ? .partial : .mixed, segments: path.segments)
        }
    }

    // MARK: - English

    private func enCandidates(_ input: String, budget: Int, maxMissing: Int) -> [Candidate] {
        var word = input.lowercased()
        while word.hasSuffix(" ") { word.removeLast() }
        let keys = Array(word.utf8)
        guard !keys.isEmpty, keys.allSatisfy({ (97...122).contains($0) || $0 == 39 }) else { return [] }
        var out: [Candidate] = []
        for (trie, source) in [(lexicon.en, Candidate.Source.lexicon), (userEn, .user)] {
            for m in fuzzyMatches(in: trie, input: keys, start: 0, maxEdits: budget, requireEnd: true, maxMissing: maxMissing) {
                for entry in trie.entries(at: m.node) {
                    out.append(Candidate(text: entry.text, language: .en, edits: m.edits,
                                         score: Double(entry.logp) - Decoder.penalty(m.edits), source: source))
                }
            }
        }
        return Decoder.rank(out)
    }

    /// Exact (0-edit) candidates first, then by score; one row per text.
    private static func rank(_ candidates: [Candidate]) -> [Candidate] {
        var seen = Set<String>()
        return candidates
            .sorted { ($0.edits.isEmpty ? 0 : 1, -$0.score, $0.text) < ($1.edits.isEmpty ? 0 : 1, -$1.score, $1.text) }
            .filter { seen.insert($0.text).inserted }
            .prefix(candidateLimit)
            .map { $0 }
    }

    // MARK: - User dictionary

    private static func language(of text: String) -> Language {
        text.unicodeScalars.allSatisfy(\.isASCII) ? .en : .zh
    }

    private func newUserWord(input: String, chosen: String) -> UserDictionary.Word? {
        if Decoder.language(of: chosen) == .en {
            let keys = chosen.lowercased()
            guard !lexicon.containsEnglish(keys), keys.utf8.allSatisfy({ (97...122).contains($0) || $0 == 39 }) else { return nil }
            return .init(text: chosen, language: .en, keys: keys)
        }
        guard !lexicon.containsChinese(chosen, keys: input), input.utf8.allSatisfy(Layout.zhuyinKeys.contains) else { return nil }
        return .init(text: chosen, language: .zh, keys: input)
    }

    private func rebuildUserTries() {
        func trie(_ language: Language) -> Trie {
            Trie(rows: user.words.filter { $0.language == language }
                .map { (Array($0.keys.utf8), Entry(text: $0.text, logp: Decoder.userWordLogp)) })
        }
        userZh = trie(.zh)
        userEn = trie(.en)
    }
}
