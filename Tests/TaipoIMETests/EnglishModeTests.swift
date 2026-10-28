import Foundation
import Testing
import TaipoCore
@testable import TaipoIME

@Test("E1: a Shift tap is a quick press and release with nothing else in between")
func shiftTapDetection() {
    let d = ShiftTapDetector()
    #expect(!d.shift(down: true, at: 0, otherModifiers: false))
    #expect(d.shift(down: false, at: 0.2, otherModifiers: false), "quick tap toggles")

    #expect(!d.shift(down: true, at: 1, otherModifiers: false))
    #expect(!d.shift(down: false, at: 1.6, otherModifiers: false), "held too long")

    #expect(!d.shift(down: true, at: 2, otherModifiers: false))
    d.otherKey()
    #expect(!d.shift(down: false, at: 2.1, otherModifiers: false), "Shift+key is typing, not a tap")

    #expect(!d.shift(down: true, at: 3, otherModifiers: true))
    #expect(!d.shift(down: false, at: 3.1, otherModifiers: false), "with another modifier")

    #expect(!d.shift(down: true, at: 4, otherModifiers: false))
    #expect(!d.shift(down: false, at: 4.1, otherModifiers: true), "another modifier joined before release")

    #expect(!d.shift(down: false, at: 5, otherModifiers: false), "a release without a press")
}

@Test("E1: only left Shift counts; right Shift (the Spec 012 voice trigger) never toggles")
func onlyLeftShiftToggles() throws {
    let down = try #require(ShiftTapDetector.leftShiftEdge(keyCode: 56, flags: 0x20102))
    #expect(down.down && !down.otherModifiers, "left ⇧ down alone")
    let up = try #require(ShiftTapDetector.leftShiftEdge(keyCode: 56, flags: 0x100))
    #expect(!up.down && !up.otherModifiers, "left ⇧ up")
    #expect(ShiftTapDetector.leftShiftEdge(keyCode: 60, flags: 0x20104) == nil, "right ⇧ down is ignored")
    #expect(ShiftTapDetector.leftShiftEdge(keyCode: 60, flags: 0x100) == nil, "right ⇧ up is ignored")
    let bare = try #require(ShiftTapDetector.leftShiftEdge(keyCode: 56, flags: 0x20000))
    #expect(bare.down && !bare.otherModifiers, "left ⇧ down without device bits")
    #expect(ShiftTapDetector.leftShiftEdge(keyCode: 56, flags: 0)?.down == false, "left ⇧ up without device bits")
    let d = ShiftTapDetector()
    #expect(!d.shift(down: true, at: 0, otherModifiers: false))
    d.otherKey()  // right ⇧ pressed during the tap (the caller maps nil to otherKey)
    #expect(!d.shift(down: false, at: 0.1, otherModifiers: false), "right ⇧ during a left tap cancels it")
    #expect(ShiftTapDetector.leftShiftEdge(keyCode: 56, flags: 0x120112)?.otherModifiers == true, "⌘ held")
    #expect(ShiftTapDetector.leftShiftEdge(keyCode: 56, flags: 0x820102)?.otherModifiers == true, "fn held")
}

@Test("E2: in English mode no key is intercepted and nothing composes")
func englishModePassesThrough() throws {
    let session = try makeSession()
    #expect(session.handle(.char("j")).consumed, "positive control: Zhuyin mode composes")
    _ = session.handle(.escape)

    _ = session.toggleEnglishMode()
    #expect(session.isEnglishMode)
    for key in parseKeys("ji3{Space}{Enter}{BS}") {
        #expect(session.handle(key) == Response(consumed: false, commit: nil))
    }
    #expect(session.buffer.isEmpty)
}

@Test("E3: switching while composing commits the shown candidate without learning")
func toggleCommitsWithoutLearning() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("taipo-en-\(UUID().uuidString)/user.json")
    let decoder = try Decoder(lexicon: sharedLexicon.get(), userDictionaryURL: url)
    let session = CompositionSession(decoder: decoder, isLearningEnabled: { true })
    for key in parseKeys("ji3{Down}") { _ = session.handle(key) }
    #expect(session.toggleEnglishMode() == "婐")
    #expect(session.buffer.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: url.path), "not learned")
}

@Test("E4: toggling again returns to Zhuyin mode")
func toggleBack() throws {
    let session = try makeSession()
    _ = session.toggleEnglishMode()
    #expect(session.toggleEnglishMode() == nil, "nothing to commit")
    #expect(!session.isEnglishMode)
    for key in parseKeys("ji3") { _ = session.handle(key) }
    #expect(session.markedText == "我")
}
