import Foundation
import Testing
import TaipoCore
@testable import TaipoIME

private func tempURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("taipo-clear-\(UUID().uuidString)/user.json")
}

@Test("U1: clearing the user dictionary restores the engine's order, and learning still works after")
func clearRestoresOrder() throws {
    let decoder = try Decoder(lexicon: sharedLexicon.get(), userDictionaryURL: tempURL())
    let session = CompositionSession(decoder: decoder, isLearningEnabled: { true })
    for key in parseKeys("up{Space}{Down}{Enter}up{Space}") { _ = session.handle(key) }
    #expect(session.markedText == "音", "positive control: the choice was learned")
    _ = session.handle(.escape)

    decoder.clearUserDictionary()
    for key in parseKeys("up{Space}") { _ = session.handle(key) }
    #expect(session.markedText == "因")

    for key in parseKeys("{Down}{Enter}up{Space}") { _ = session.handle(key) }
    #expect(session.markedText == "音", "learning works again after a clear")
}

@Test("U2: entryCount counts choices plus new words, and is 0 without a file")
func entryCount() throws {
    let url = tempURL()
    #expect(UserDictionaryStore.entryCount(at: url) == 0)
    let decoder = try Decoder(lexicon: sharedLexicon.get(), userDictionaryURL: url)
    try decoder.learn(input: "up ", chosen: "音")
    try decoder.learn(input: "su3cl3", chosen: "你好")
    #expect(UserDictionaryStore.entryCount(at: url) >= 2)
}

@Test("U3: clear removes the file through the injected remover and posts the notification")
func clearRemovesAndNotifies() throws {
    let url = tempURL()
    let decoder = try Decoder(lexicon: sharedLexicon.get(), userDictionaryURL: url)
    try decoder.learn(input: "up ", chosen: "音")
    var removed: [URL] = []
    var posted = 0
    let remove: (URL) throws -> Void = { removed.append($0); try FileManager.default.removeItem(at: $0) }
    #expect(try UserDictionaryStore.clear(at: url, remove: remove, notify: { posted += 1 }))
    #expect(removed == [url])
    #expect(posted == 1)
    #expect(UserDictionaryStore.entryCount(at: url) == 0)

    #expect(try !UserDictionaryStore.clear(at: url, remove: remove, notify: { posted += 1 }), "nothing to clear")
    #expect(removed.count == 1)
    #expect(posted == 2, "the input method still forgets what it holds in memory")
}

@Test("U5: a failed removal throws and posts nothing")
func clearFailure() throws {
    struct Denied: Error {}
    let url = tempURL()
    let decoder = try Decoder(lexicon: sharedLexicon.get(), userDictionaryURL: url)
    try decoder.learn(input: "up ", chosen: "音")
    var posted = 0
    #expect(throws: Denied.self) {
        try UserDictionaryStore.clear(at: url, remove: { _ in throw Denied() }, notify: { posted += 1 })
    }
    #expect(posted == 0)
    #expect(UserDictionaryStore.entryCount(at: url) > 0, "the file is untouched")
}
