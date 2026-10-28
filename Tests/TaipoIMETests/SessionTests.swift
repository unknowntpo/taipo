import Foundation
import Testing
import TaipoCore
@testable import TaipoIME

struct SessionCase: Decodable, CustomTestStringConvertible, Sendable {
    let id: String
    let name: String
    let keys: String
    var expectMarked: String?
    var expectCommitted: String?
    var expectLastConsumed: Bool?
    var note: String?

    var testDescription: String { "\(id): \(name)" }

    static func load() throws -> [SessionCase] {
        let url = try #require(Bundle.module.url(forResource: "session-cases", withExtension: "json", subdirectory: "Cases"))
        return try JSONDecoder().decode([SessionCase].self, from: Data(contentsOf: url))
    }
}

/// `ji3{Enter}` → [j, i, 3, enter]; `{!}` is a non-layout key, `{Cmd+c}` a modified key.
func parseKeys(_ script: String) -> [Key] {
    var keys: [Key] = []
    var rest = Substring(script)
    while let c = rest.first {
        if c == "{", let close = rest.firstIndex(of: "}") {
            let name = rest[rest.index(after: rest.startIndex)..<close]
            switch name {
            case "Space": keys.append(.space)
            case "Enter": keys.append(.enter)
            case "Esc": keys.append(.escape)
            case "BS": keys.append(.backspace)
            case "Up": keys.append(.up)
            case "Down": keys.append(.down)
            default: keys.append(.other)
            }
            rest = rest[rest.index(after: close)...]
        } else {
            keys.append(.char(c))
            rest = rest.dropFirst()
        }
    }
    return keys
}

let sharedLexicon = Result { try Lexicon.bundled() }

func makeSession(userDictionaryAt url: URL? = nil) throws -> CompositionSession {
    let path = url ?? FileManager.default.temporaryDirectory.appendingPathComponent("taipo-ime-\(UUID().uuidString)/user.json")
    // Tests never read the machine's real switches (Spec 008).
    return CompositionSession(decoder: try Decoder(lexicon: sharedLexicon.get(), userDictionaryURL: path),
                              isLearningEnabled: { true })
}

@Test(arguments: try SessionCase.load())
func sessionCase(_ c: SessionCase) throws {
    let session = try makeSession()
    var committed = ""
    var last: Response?
    for key in parseKeys(c.keys) {
        let r = session.handle(key)
        committed += r.commit ?? ""
        last = r
    }
    if let marked = c.expectMarked { #expect(session.markedText == marked, "candidates: \(session.displayCandidates.prefix(5))") }
    if let text = c.expectCommitted { #expect(committed == text) }
    if let consumed = c.expectLastConsumed { #expect(last?.consumed == consumed) }
}

@Test("I11: commitComposition commits the selected candidate and clears")
func commitOnFocusLoss() throws {
    let session = try makeSession()
    for key in parseKeys("ji3{Down}") { _ = session.handle(key) }
    #expect(session.commitComposition() == "婐")
    #expect(session.buffer.isEmpty)
    #expect(session.markedText.isEmpty)
    #expect(session.commitComposition() == nil)
}

@Test("I13: router passes every key through when the session cannot be created")
func routerFallback() throws {
    struct Broken: Error {}
    let broken = KeyRouter { throw Broken() }
    #expect(broken.session == nil)
    #expect(broken.failure != nil)
    for key in parseKeys("ji3{Space}{Enter}") { #expect(broken.handle(key) == Response(consumed: false, commit: nil)) }
    let working = KeyRouter { try makeSession() }
    #expect(working.handle(.char("j")).consumed, "positive control")
}

@Test("I14: learn write failure still commits and records a diagnostic")
func learnWriteFailure() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("taipo-ime-ro-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }
    let session = try makeSession(userDictionaryAt: dir.appendingPathComponent("user.json"))
    var committed = ""
    for key in parseKeys("ji3{Down}{Enter}") { committed += session.handle(key).commit ?? "" }
    #expect(committed == "婐")
    #expect(session.diagnostics.contains { $0.contains("learn failed") })
    #expect(session.handle(.char("j")).consumed, "I22: typing still works after a failed save")
}

@Test("I22: session keeps working after a failed learn")
func afterLearnFailure() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("taipo-ime-ro2-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }
    let session = try makeSession(userDictionaryAt: dir.appendingPathComponent("user.json"))
    for key in parseKeys("ji3{Down}{Enter}") { _ = session.handle(key) }
    var committed = ""
    for key in parseKeys("ji3{Enter}") { committed += session.handle(key).commit ?? "" }
    #expect(committed == "婐", "Spec 001 F6: the choice still applies in memory")
}

@Test("I23: selecting an out-of-range candidate commits nothing")
func selectOutOfRange() throws {
    let session = try makeSession()
    for key in parseKeys("ji3") { _ = session.handle(key) }
    #expect(session.select(99) == nil)
    #expect(session.markedText == "我")
    #expect(session.select(1) == "婐", "positive control")
}

@Test("I24: a non-input key with an empty buffer is not handled")
func otherKeyEmpty() throws {
    let session = try makeSession()
    #expect(session.handle(.other) == Response(consumed: false, commit: nil))
    #expect(session.previousLanguage == nil)
}

@Test("I23: highlight moves the selection without committing; out of range is ignored")
func highlightSelection() throws {
    let session = try makeSession()
    for key in parseKeys("ji3") { _ = session.handle(key) }
    session.highlight(99)
    #expect(session.markedText == "我")
    session.highlight(1)
    #expect(session.markedText == "婐")
    #expect(session.handle(.enter).commit == "婐")
}

@Test("I14: diagnostics are drained once taken")
func diagnosticsDrain() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("taipo-ime-ro3-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }
    let session = try makeSession(userDictionaryAt: dir.appendingPathComponent("user.json"))
    for key in parseKeys("ji3{Down}{Enter}") { _ = session.handle(key) }
    #expect(session.takeDiagnostics().count == 1)
    #expect(session.takeDiagnostics().isEmpty)
}

@Test("X2: the IME commits a mixed sentence and adds a space after the English word")
func mixedSentenceCommit() throws {
    let session = try makeSession()
    var committed = ""
    for key in parseKeys("5k4ek7cl3vu;4u.32u03tricky{Space}") { committed += session.handle(key).commit ?? "" }
    #expect(committed == "這個好像有點 tricky ")
    for key in parseKeys("5k4ek7j") { _ = session.handle(key) }
    #expect(session.markedText == "這個j", "X4: unfinished tail stays visible while typing")
}

@Test("X14: Space commits the first complete candidate instead of an unfinished tail")
func spaceSkipsTail() throws {
    let session = try makeSession()
    for key in parseKeys("5k4ek7go") { _ = session.handle(key) }
    #expect(session.markedText == "這個go", "positive control: the tail is shown while typing")
    #expect(session.handle(.space).commit == "這個 go ")
    var committed = ""
    for key in parseKeys("5k4ek7go{Enter}") { committed += session.handle(key).commit ?? "" }
    #expect(committed == "這個go", "Enter commits what is shown")
}

@Test("L1: a long Zhuyin sentence commits its leading phrases instead of becoming raw keys")
func longSentenceAutoCommits() throws {
    let session = try makeSession()
    var committed = ""
    for key in parseKeys("rup{Space}wu0{Space}2k7wu0{Space}fu4cp3cl3cp3g4ck6tj{Space}ap6m/422j/4i{Enter}") { committed += session.handle(key).commit ?? "" }
    #expect(committed.hasPrefix("今天的天氣很好很"), "\(committed)")
    #expect(!committed.contains("rup"), "no raw keys from the start of the sentence")
    #expect(session.buffer.isEmpty)
}

@Test("L2: the composition never grows beyond the auto-commit threshold while it parses")
func bufferStaysBounded() throws {
    let session = try makeSession()
    var longest = 0
    for key in parseKeys("rup{Space}wu0{Space}2k7wu0{Space}fu4cp3cl3cp3g4ck6tj{Space}ap6") {
        _ = session.handle(key)
        longest = max(longest, session.buffer.count)
    }
    #expect(longest <= CompositionSession.autoCommitAbove)
    #expect(longest > CompositionSession.keepKeys, "positive control: the buffer did grow")
}

@Test("L3: short input never auto-commits")
func shortInputKeepsComposing() throws {
    let session = try makeSession()
    var committed = ""
    for key in parseKeys("rup{Space}wu0{Space}2k7wu0{Space}fu4") { committed += session.handle(key).commit ?? "" }
    #expect(committed.isEmpty)
    #expect(session.markedText == "今天的天氣")
}

@Test("R1: after a pause, a deep pass recovers a three-slip phrase the fast pass misses")
func deepenRecoversMessyPhrase() throws {
    let session = try makeSession()
    for key in parseKeys("ao6vu;3q2lr3") { _ = session.handle(key) }
    #expect(!session.displayCandidates.prefix(5).contains("沒想到"), "positive control: the fast pass misses it")
    #expect(session.deepen())
    #expect(session.markedText == "沒想到")
    #expect(!session.deepen(), "the same buffer is not deepened twice")
}

@Test("R2: deepening is a no-op for short input and for input that already has an exact parse")
func deepenNoOp() throws {
    let short = try makeSession()
    for key in parseKeys("123") { _ = short.handle(key) }
    #expect(!short.deepen())
    #expect(short.markedText == "123")
    let exact = try makeSession()
    for key in parseKeys("su3cl3ji3") { _ = exact.handle(key) }
    #expect(!exact.deepen())
    #expect(exact.markedText == "你好我")
}
