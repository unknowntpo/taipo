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

@Test("B9: en lexicon has common words whose SCOWL lines carry spelling-variant info")
func englishVariantWords() throws {
    let lexicon = try sharedLexicon.get()
    // Positive control: a word on a plain SCOWL line, present before and after the fix.
    #expect(lexicon.containsEnglish("travel"))
    let us = ["practice", "practiced", "color", "center", "license", "defense", "program", "organize", "analyze", "gray", "advertise"]
    #expect(us.filter { !lexicon.containsEnglish($0) } == [])
    // British non-variant spellings (D5).
    let gb = ["practise", "colour", "centre", "licence", "defence", "programme", "organise", "analyse", "grey"]
    #expect(gb.filter { !lexicon.containsEnglish($0) } == [])
}

@Test("F9: SCOWL variant levels above 1 stay out of the en lexicon")
func englishVariantLevels() throws {
    let lexicon = try sharedLexicon.get()
    // A-: advertize (uncommon), Bv: connexion (common variant), AV: esthete (acceptable).
    #expect(["advertize", "connexion", "esthete"].filter { lexicon.containsEnglish($0) } == [])
    // Positive control: the preferred forms of the same groups are present.
    #expect(["advertise", "connection", "aesthete"].filter { !lexicon.containsEnglish($0) } == [])
}

/// Log-probability of an English lexicon word; equal values mean equal SCOWL size.
private func englishLogp(_ lexicon: Lexicon, _ word: String) throws -> Float {
    let node = try #require(lexicon.en.node(for: word.utf8))
    return try #require(lexicon.en.entries(at: node).first { $0.text == word }).logp
}

@Test("B9: region-neutral and level-1 SCOWL variants enter the en lexicon at the right size")
func englishVariantAccepted() throws {
    let lexicon = try sharedLexicon.get()
    // `_: adrenaline` (any region), `A. Bv C.: advisor` and `A. Cv: afterward` (US level 1).
    #expect(["adrenaline", "advisor", "afterward"].filter { !lexicon.containsEnglish($0) } == [])
    // Level 1 is the US size (35, the same as `travel`), not the British size + 5.
    let size35 = try englishLogp(lexicon, "travel")
    #expect(try englishLogp(lexicon, "advisor") == size35)
    #expect(try englishLogp(lexicon, "afterward") == size35)
    // `AV Z Cv: tranquillize` (size 35): only the British `Z` accepts it, so 35 + 5 = 40 like adrenaline.
    #expect(try englishLogp(lexicon, "tranquillize") == (try englishLogp(lexicon, "adrenaline")))
    #expect(try englishLogp(lexicon, "tranquilize") == size35)
    // Size limit 60: `A Z: accessorize` at size 60 is in.
    #expect(lexicon.containsEnglish("accessorize"))
    // `A= B: axe` (size 35): US level 2 is ignored, so axe gets the British size 35 + 5 = 40,
    // the same as adrenaline (size 40) and rarer than adviser (size 35).
    let axe = try englishLogp(lexicon, "axe")
    #expect(axe == (try englishLogp(lexicon, "adrenaline")))
    #expect(axe < (try englishLogp(lexicon, "adviser")))
}

@Test("F9: SCOWL level-2 variants and sizes above 60 stay out of the en lexicon")
func englishVariantRejected() throws {
    let lexicon = try sharedLexicon.get()
    // `A= Bv: amuck`: US level 2 and British variant, so it is out.
    #expect(!lexicon.containsEnglish("amuck"))
    // `B: accessorise` at size 60 becomes 60 + 5 = 65 > 60, so it is out.
    #expect(!lexicon.containsEnglish("accessorise"))
    // `_~: cafe <n>: cafes` and `_~: attache <n>: attaches, attache's` (size 35): region-neutral at level `~`,
    // so the head words are out. SCOWL has no `A~` line; `_~` takes the same branch as `A`.
    #expect(["cafe", "attache"].filter { lexicon.containsEnglish($0) } == [])
    // Positive control: the same groups' accepted spellings are present, and `_: so <av> {:1}` (size 35)
    // shows that the `_` branch accepts level 0. (The accepted spellings café and attaché are not ASCII.)
    #expect(["amok", "accessorize", "so"].filter { !lexicon.containsEnglish($0) } == [])
}

@Test("B9: SCOWL lines with a {sense} tag after the part of speech enter the en lexicon")
func englishSenseTaggedWords() throws {
    let lexicon = try sharedLexicon.get()
    let size35 = try englishLogp(lexicon, "travel")
    // `_: so <av> {:1}`, `A B: disk <n> {:1}`, `A B: icon <n> {:1}`, `A C: curb <n> {street edge}: curbs` (size 35).
    // Lines without variant info too: `genius <n> {brilliance}`, `phenomenon <n> {science}`, `die <v> {expire}`.
    let words = ["so", "disk", "icon", "curb", "genius", "phenomenon", "die"]
    #expect(words.filter { !lexicon.containsEnglish($0) } == [])
    for word in words where lexicon.containsEnglish(word) {
        #expect(try englishLogp(lexicon, word) == size35, "\(word)")
    }
    // `B: tyre <n> {wheel}` (size 35): British, so 35 + 5 = 40 like adrenaline.
    #expect(lexicon.containsEnglish("tyre"))
    if lexicon.containsEnglish("tyre") {
        #expect(try englishLogp(lexicon, "tyre") == (try englishLogp(lexicon, "adrenaline")))
    }
}

@Test("B9: Canadian-only and Australian-only SCOWL spellings stay out of the en lexicon")
func englishVariantRegionalOnly() throws {
    let lexicon = try sharedLexicon.get()
    // `C: yogourt` (Canadian only), `Av Bv D: verandah` (Australian only at level 0), both size 35.
    #expect(["yogourt", "verandah"].filter { lexicon.containsEnglish($0) } == [])
    // Positive control: `A B Cv Dv: yogurt` and `A B Dv: veranda` from the same groups are present.
    #expect(["yogurt", "veranda"].filter { !lexicon.containsEnglish($0) } == [])
}

@Test("F9: British level-2 SCOWL spellings stay out of the en lexicon")
func englishVariantBritishLevel2() throws {
    let lexicon = try sharedLexicon.get()
    // `AV B= Cv Dv: encyclopaedia` (size 35): British level 2, US level 6, so it is out.
    #expect(!lexicon.containsEnglish("encyclopaedia"))
    // Positive control: `A B C D: encyclopedia` from the same group is present.
    #expect(lexicon.containsEnglish("encyclopedia"))
    // `BV: burkha` (size 50): British level 6 only, so it is out.
    #expect(!lexicon.containsEnglish("burkha"))
    // Positive control: `A B Dv: burka` from the same group is present.
    #expect(lexicon.containsEnglish("burka"))
    // `AV B-: gage <n>` (size 35) and `B-: gaolbreak <n>` (size 50): British level `-`, so they are out.
    #expect(["gage", "gaolbreak"].filter { lexicon.containsEnglish($0) } == [])
    // Positive control: `A B: gauge <n>` and `A B: jailbreak <n>` from the same groups are present.
    #expect(["gauge", "jailbreak"].filter { !lexicon.containsEnglish($0) } == [])
}

@Test("B9: SCOWL lines with a (vulgar-N) or (offensive-N) usage tag stay out of the en lexicon")
func englishUsageTaggedWordsExcluded() throws {
    let lexicon = try sharedLexicon.get()
    // `A: asshole <n> (vulgar-1)`, `B: arsehole <n> (vulgar-1)`, `_: shit <v> (vulgar-1)` (all size 40).
    #expect(["asshole", "arsehole", "shit"].filter { lexicon.containsEnglish($0) } == [])
    // `kraut <n> (offensive-2): krauts` (size 60): an offensive tag, not only vulgar ones.
    #expect(!lexicon.containsEnglish("kraut"))
    // `crap <n> (vulgar-3)` (size 35): a higher vulgar level, not only level 1.
    #expect(!lexicon.containsEnglish("crap"))
    // `assholes` is listed on the `A: asshole <n> (vulgar-1): assholes, asshole's` line: inline forms are out too.
    #expect(!lexicon.containsEnglish("assholes"))
    // Positive control: the only `(…)` usage tags in SCOWL are vulgar and offensive, so the control is
    // a marked line with a `{sense}` tag in the same slot: `A B: disk <n> {:1}`.
    #expect(lexicon.containsEnglish("disk"))
}
