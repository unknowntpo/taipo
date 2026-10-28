import Foundation
import Testing
import TaipoCore
@testable import TaipoIME

@Test("P1: the learning switch defaults to on and round-trips through a preferences domain")
func learningSwitchRoundTrip() throws {
    let suite = "taipo-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    #expect(LearningSettings.isEnabled(in: defaults), "default keeps today's behaviour")
    LearningSettings.setEnabled(false, in: defaults)
    #expect(!LearningSettings.isEnabled(in: defaults))
}

@Test("P2: with learning off, choosing a non-first candidate is neither remembered nor written")
func learningOffWritesNothing() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("taipo-learning-\(UUID().uuidString)")
    let url = dir.appendingPathComponent("user.json")
    let decoder = try Decoder(lexicon: sharedLexicon.get(), userDictionaryURL: url)
    let session = CompositionSession(decoder: decoder, isLearningEnabled: { false })
    var committed = ""
    for key in parseKeys("up{Space}{Down}{Enter}up{Space}") { committed += session.handle(key).commit ?? "" }
    #expect(committed == "音")
    #expect(session.markedText == "因", "the earlier choice was not learned")
    #expect(!FileManager.default.fileExists(atPath: url.path), "nothing written to disk")
}

@Test("P3: with learning on (positive control), the same choice is remembered and saved")
func learningOnRemembers() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("taipo-learning-\(UUID().uuidString)")
    let url = dir.appendingPathComponent("user.json")
    let decoder = try Decoder(lexicon: sharedLexicon.get(), userDictionaryURL: url)
    let session = CompositionSession(decoder: decoder, isLearningEnabled: { true })
    for key in parseKeys("up{Space}{Down}{Enter}up{Space}") { _ = session.handle(key) }
    #expect(session.markedText == "音")
    #expect(FileManager.default.fileExists(atPath: url.path))
}
