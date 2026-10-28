import Foundation
import Testing
import TaipoCore
@testable import TaipoIME

private func typed(_ keys: String, learnAt url: URL? = nil) throws -> CompositionSession {
    let session = try makeSession(userDictionaryAt: url)
    for key in parseKeys(keys) { _ = session.handle(key) }
    return session
}

/// Types `keys` one by one and returns true when every key was added to the buffer (nothing selected).
private func composesEveryKey(_ keys: String) throws -> (CompositionSession, Bool) {
    let session = try makeSession()
    var buffer = ""
    for key in parseKeys(keys) {
        let response = session.handle(key)
        if case let .char(c) = key { buffer.append(c) } else if key == .space { buffer.append(" ") }
        if response.commit != nil || session.buffer != buffer { return (session, false) }
    }
    return (session, true)
}

@Test("A1: lexus then 3 commits the candidate shown on row 3 and learns like Enter")
@MainActor func lexusDigitSelects() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("taipo-a1-\(UUID().uuidString)/user.json")
    let session = try typed("lexus", learnAt: url)
    #expect(session.candidates.first?.language == .en)
    #expect(!session.isSelecting)
    let third = try #require(session.visibleCandidates.dropFirst(2).first)
    #expect(third == "lexus", "today row 3 is the typed letters")
    #expect(session.handle(.char("3")) == Response(consumed: true, commit: third))
    #expect(session.buffer.isEmpty)
    #expect(FileManager.default.fileExists(atPath: url.path), "learned like Enter")
}

@Test("A2: Zhuyin typing is unchanged: tone digits compose (positive control for A1)",
      arguments: [("ji3", "我"), ("su3", "你"), ("5j/{Space}cl3", "中好")])
@MainActor func zhuyinDigitsCompose(_ keys: String, _ marked: String) throws {
    let (session, composed) = try composesEveryKey(keys)
    #expect(composed)
    #expect(session.markedText == marked)
}

@Test("A3: an English word first, then a tone digit that makes a Chinese reading, composes",
      arguments: [("up", "4", "印"), ("hellosu", "3", "hello 你")])
@MainActor func englishPrefixThenTone(_ prefix: String, _ digit: String, _ marked: String) throws {
    let session = try typed(prefix)
    #expect(session.candidates.first?.language == .en, "the shown first candidate is English")
    #expect(session.handle(.char(Character(digit))) == Response(consumed: true, commit: nil))
    #expect(session.buffer == prefix + digit)
    #expect(session.markedText == marked)
}

@Test("A6: a digit past the last row is swallowed")
@MainActor func pastLastRowSwallowed() throws {
    let session = try typed("lexus")
    let count = session.visibleCandidates.count
    try #require(count < 9)
    let digit = Character(String(count + 1))
    #expect(session.handle(.char(digit)) == Response(consumed: true, commit: nil))
    #expect(session.buffer == "lexus")
    #expect(session.candidates.count == count)
}

@Test("A7: typed letters shown first (no dictionary word) → the digit composes")
@MainActor func literalFirstComposes() throws {
    let session = try typed("ok")
    #expect(session.candidates.first?.source == .literal)
    #expect(session.handle(.char("8")) == Response(consumed: true, commit: nil))
    #expect(session.buffer == "ok8")
}

@Test("A8: a mixed sentence shown first → the digit composes")
@MainActor func mixedFirstComposes() throws {
    let session = try typed("su3hello")
    #expect(session.candidates.first?.source == .mixed)
    #expect(session.handle(.char("3")) == Response(consumed: true, commit: nil))
    #expect(session.buffer == "su3hello3")
}

@Test("A9: an English word first, then a digit that starts a syllable, composes (a + 8 = ㄇㄚ)")
@MainActor func syllableDigitComposes() throws {
    let session = try typed("a")
    #expect(session.candidates.first.map { $0.language == .en && $0.source == .lexicon } == true)
    #expect(session.handle(.char("8")) == Response(consumed: true, commit: nil))
    #expect(session.buffer == "a8")
    #expect(session.handle(.space) == Response(consumed: true, commit: nil))
    #expect(session.markedText == "嗎", "ㄇㄚ + space decodes as before Spec 017")
}

@Test("A10: 0 is ㄢ and never selects, even after an English word")
@MainActor func zeroComposes() throws {
    let session = try typed("lexus")
    #expect(session.handle(.char("0")) == Response(consumed: true, commit: nil))
    #expect(session.buffer == "lexus0")
}

/// A11 [measure]: types every Nth Chinese reading of the bundled lexicon key by key and counts readings where
/// a digit was taken as a selection. Slow (≈0.1 s per reading in debug): run with TAIPO_SWEEP_STRIDE=N.
@Test("A11: lexicon sweep of digit false positives", .enabled(if: ProcessInfo.processInfo.environment["TAIPO_SWEEP_STRIDE"] != nil))
@MainActor func lexiconSweep() throws {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../Sources/TaipoCore/Resources/zh.tsv")
    let readings = Set(try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        .compactMap { $0.split(separator: "\t", omittingEmptySubsequences: false).first.map(String.init) }).sorted()
    let stride = Int(ProcessInfo.processInfo.environment["TAIPO_SWEEP_STRIDE"] ?? "") ?? 50
    var checked = 0, exposed = 0
    var hits: [String] = []
    for (i, keys) in readings.enumerated() where i % stride == 0 && keys.contains(where: { ("1"..."9").contains($0) }) {
        checked += 1
        let session = try makeSession()
        for c in keys {
            let before = session.buffer
            if c.isNumber, c != "0", let first = session.candidates.first, first.language == .en,
               [.lexicon, .user, .learned].contains(first.source) { exposed += 1 }
            let response = session.handle(c == " " ? .space : .char(c))
            if c.isNumber, c != "0", session.buffer != before + String(c) {
                hits.append("\(keys): \(before)+\(c) → \(response.commit ?? "swallowed")")
                break
            }
        }
    }
    print("A11 sweep: readings=\(checked) englishFirstDigits=\(exposed) falsePositives=\(hits.count)")
    for hit in hits.prefix(50) { print("A11 hit:", hit) }
    #expect(hits.isEmpty)
}
