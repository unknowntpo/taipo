import Foundation
import Testing
@testable import TaipoCore

struct DecoderCase: Decodable, CustomTestStringConvertible, Sendable {
    let id: String
    let name: String
    let input: String
    var previousLanguage: Language?
    var learn: [[String]]?
    var expectTop1: String?
    var expectTop1Language: Language?
    var expectInTop3: [String]?
    var expectAbsent: [String]?
    var expectInCandidates: [String]?
    var expectCount: Int?
    var expectFuzzy: Bool?
    var expectNoLanguage: Language?
    var note: String?

    var testDescription: String { "\(id): \(name)" }

    static func load(_ name: String = "decoder-cases") throws -> [DecoderCase] {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Cases"))
        return try JSONDecoder().decode([DecoderCase].self, from: Data(contentsOf: url))
    }
}

let sharedLexicon = Result { try Lexicon.bundled() }

func makeDecoder(userDictionaryAt url: URL? = nil) throws -> Decoder {
    let path = url ?? FileManager.default.temporaryDirectory
        .appendingPathComponent("taipo-tests-\(UUID().uuidString)/user.json")
    return try Decoder(lexicon: sharedLexicon.get(), userDictionaryURL: path)
}

@Test(arguments: try DecoderCase.load())
func decoderCase(_ c: DecoderCase) throws {
    try check(c)
}

@Test(arguments: try DecoderCase.load("mixed-cases"))
func mixedCase(_ c: DecoderCase) throws {
    try check(c)
}

func check(_ c: DecoderCase) throws {
    let decoder = try makeDecoder()
    for pair in c.learn ?? [] {
        try decoder.learn(input: pair[0], chosen: pair[1])
    }
    let result = decoder.decode(c.input, previousLanguage: c.previousLanguage)
    let texts = result.candidates.map(\.text)
    let top3 = Array(texts.prefix(3))
    if let expected = c.expectTop1 { #expect(texts.first == expected, "candidates: \(texts.prefix(5))") }
    if let lang = c.expectTop1Language { #expect(result.candidates.first?.language == lang) }
    for word in c.expectInTop3 ?? [] { #expect(top3.contains(word), "top3: \(top3)") }
    for word in c.expectAbsent ?? [] {
        #expect(!texts.contains(word), "candidates: \(texts)")
        #expect(!texts.isEmpty, "positive control: decoding still produces candidates")
    }
    for word in c.expectInCandidates ?? [] { #expect(texts.contains(word)) }
    if let count = c.expectCount { #expect(texts.count == count) }
    if let fuzzy = c.expectFuzzy { #expect(result.fuzzyEnabled == fuzzy) }
    if let lang = c.expectNoLanguage {
        #expect(!result.candidates.contains { $0.language == lang })
        #expect(texts.contains(c.input), "positive control: literal is present")
    }
}

@Test("X9: every Spec 001 case row still holds with mixed decoding enabled")
func spec001Unchanged() throws {
    let cases = try DecoderCase.load()
    #expect(cases.count > 30, "positive control: the Spec 001 case file is loaded")
    for c in cases { try check(c) }
}

@Test(arguments: try DecoderCase.load("recall-cases"))
func recallCase(_ c: DecoderCase) throws {
    try check(c)
}

@Test("R5: deep decoding changes nothing for short or exactly typed Spec 001 inputs")
func deepLeavesSpec001Alone() throws {
    let decoder = try makeDecoder()
    var compared = 0
    for c in try DecoderCase.load() where !Decoder.canDeepen(c.input) || c.expectTop1 != nil {
        let fast = decoder.decode(c.input, previousLanguage: c.previousLanguage).candidates.map(\.text)
        let deep = decoder.decode(c.input, previousLanguage: c.previousLanguage, deep: true).candidates.map(\.text)
        if !Decoder.canDeepen(c.input) { #expect(fast == deep, "\(c.input)") }
        if let top = c.expectTop1, c.learn == nil { #expect(deep.first == top, "\(c.input): deep keeps the Spec 001 top 1") }
        compared += 1
    }
    #expect(compared > 20, "positive control: the Spec 001 cases were compared")
}
