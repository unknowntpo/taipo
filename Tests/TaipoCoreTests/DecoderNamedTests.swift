import Foundation
import Testing
@testable import TaipoCore

private func tempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("taipo-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Test("B1: every candidate carries text, language, edits and score")
func candidateShape() throws {
    let decoder = try makeDecoder()
    let candidates = decoder.decode("hrllo", previousLanguage: nil).candidates
    let hello = try #require(candidates.first { $0.text == "hello" })
    #expect(hello.language == .en)
    #expect(hello.edits.count == 1)
    #expect(hello.score.isFinite)
    let zh = try #require(decoder.decode("ji3", previousLanguage: nil).candidates.first)
    #expect(zh.language == .zh)
    #expect(zh.edits.isEmpty)
}

@Test("B7: learned choice persists across restart")
func learnPersists() throws {
    let url = try tempDir().appendingPathComponent("user.json")
    let first = try makeDecoder(userDictionaryAt: url)
    #expect(first.decode("teh", previousLanguage: nil).candidates.first?.text == "the")
    try first.learn(input: "teh", chosen: "teh")
    let second = try makeDecoder(userDictionaryAt: url)
    #expect(second.decode("teh", previousLanguage: nil).candidates.first?.text == "teh")
}

@Test("F4: corrupt user dictionary is quarantined and decoder starts empty")
func corruptUserDictionary() throws {
    let dir = try tempDir()
    let url = dir.appendingPathComponent("user.json")
    try Data("{not json".utf8).write(to: url)
    let decoder = try makeDecoder(userDictionaryAt: url)
    #expect(decoder.decode("teh", previousLanguage: nil).candidates.first?.text == "the")
    #expect(decoder.diagnostics.contains { $0.contains("corrupt") })
    let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
    #expect(files.contains { $0.hasPrefix("user.json.corrupt-") })
    #expect(!files.contains("user.json"))
}

@Test("F5: missing user dictionary starts empty and is created on first learn")
func missingUserDictionary() throws {
    let url = try tempDir().appendingPathComponent("nested/user.json")
    let decoder = try makeDecoder(userDictionaryAt: url)
    #expect(decoder.diagnostics.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: url.path))
    try decoder.learn(input: "teh", chosen: "teh")
    #expect(FileManager.default.fileExists(atPath: url.path))
}

@Test("F6: write failure throws but the in-memory choice still applies")
func writeFailure() throws {
    let dir = try tempDir()
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }
    let decoder = try makeDecoder(userDictionaryAt: dir.appendingPathComponent("user.json"))
    #expect(throws: UserDictionaryError.self) { try decoder.learn(input: "ji3", chosen: "婐") }
    #expect(decoder.decode("ji3", previousLanguage: nil).candidates.first?.text == "婐")
}

@Test("F8: missing or malformed lexicon throws LexiconError")
func badLexicon() throws {
    let dir = try tempDir()
    let missing = dir.appendingPathComponent("missing.tsv")
    #expect(throws: LexiconError.self) { try Lexicon(zhURL: missing, enURL: missing) }
    let bad = dir.appendingPathComponent("bad.tsv")
    try Data("no tabs here\n".utf8).write(to: bad)
    #expect(throws: LexiconError.self) { try Lexicon(zhURL: bad, enURL: bad) }
    let good = dir.appendingPathComponent("good-zh.tsv")
    try Data("ji3\t我\t10\n".utf8).write(to: good)
    let goodEn = dir.appendingPathComponent("good-en.tsv")
    try Data("the\t35\n".utf8).write(to: goodEn)
    #expect(throws: Never.self) { try Lexicon(zhURL: good, enURL: goodEn) }
}

@Test("O1: explain lists language, edits, score and fuzzy state")
func explainOutput() throws {
    let decoder = try makeDecoder()
    let text = decoder.explain("hrllo", previousLanguage: nil)
    #expect(text.contains("fuzzy: on"))
    #expect(text.contains("hello"))
    #expect(text.contains("[en]"))
    #expect(text.contains("substitute r→e"))
    #expect(text.contains("logp"), "score components")
    #expect(text.contains("penalty 6.00"))
    #expect(decoder.explain(String(repeating: "a", count: 33), previousLanguage: nil).contains("fuzzy: off"))
}

@Test("X12: explain lists the segments of a mixed candidate")
func explainMixed() throws {
    let decoder = try makeDecoder()
    let text = decoder.explain("5k4ek7tricky", previousLanguage: nil)
    #expect(text.contains("segments: 這個[zh] | tricky[en]"), "\(text)")
    #expect(!decoder.explain("su3cl3", previousLanguage: nil).contains("segments:"), "single-language candidates list no segments")
}


@Test("L6: short unparseable input stays literal (no parsed-prefix fallback below 12 keys)")
func shortGarbageStaysLiteral() throws {
    let decoder = try makeDecoder()
    for input in ["123", "JI3", "3333"] {
        let candidates = decoder.decode(input, previousLanguage: nil).candidates
        #expect(candidates.first?.text == input, "\(input): \(candidates.prefix(3).map(\.text))")
        #expect(!candidates.contains { $0.source == .partial }, "\(input)")
    }
}

@Test("L5: a syllable-start tail may follow an edited prefix, but costs more than a one-key fix")
func tailAfterEditedPrefix() throws {
    let decoder = try makeDecoder()
    #expect(decoder.decode("5k4rk7j", previousLanguage: nil).candidates.first?.text == "這個j", "r→e fixed, then tail j")
    #expect(decoder.decode("xu3ge", previousLanguage: nil).candidates.first?.text == "理事", "not 理e: dropping g to keep a tail must lose")
}

@Test("A4: typed letters that are a dictionary word rank above fuzzy-corrected words",
      // baht, froward: rare words (SCOWL 60) one transposition from common ones (bath, forward), which would outscore them.
      arguments: ["lexis", "plexus", "hello", "baht", "froward", "teh"])
func exactEnglishFirst(_ word: String) throws {
    let candidates = try makeDecoder().decode(word, previousLanguage: nil).candidates
    let exact = candidates.firstIndex { $0.language == .en && $0.text == word && $0.source == .lexicon && $0.edits.isEmpty }
    if word == "teh" {
        // Other side of the boundary: not a dictionary word, so the typed letters stay the last row.
        #expect(exact == nil)
        #expect(candidates.last?.text == "teh")
        #expect(candidates.last?.source == .literal)
    } else {
        #expect(exact == 0)
        #expect(candidates.dropFirst().filter { $0.language == .en && $0.source != .literal }.allSatisfy { !$0.edits.isEmpty })
    }
}
