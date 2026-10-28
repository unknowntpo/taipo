import Foundation
import Testing
import TaipoCore
@testable import TaipoIME

private func composing(_ keys: String, learnAt url: URL? = nil) throws -> CompositionSession {
    let session = try makeSession(userDictionaryAt: url)
    for key in parseKeys(keys) { _ = session.handle(key) }
    return session
}

@Test("N1: before ↓/↑ digits compose; after ↓ they select (positive control)")
func digitsComposeUntilSelecting() throws {
    let typing = try composing("ji3")
    #expect(typing.handle(.char("3")) == Response(consumed: true, commit: nil))
    #expect(typing.buffer == "ji33", "3 is the Zhuyin tone key while typing")

    let selecting = try composing("ji3{Down}")
    let third = selecting.displayCandidates[2]
    #expect(selecting.handle(.char("3")) == Response(consumed: true, commit: third))
}

@Test("N2: a digit after ↓ commits that row and learns like Enter")
func digitCommitsAndLearns() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("taipo-digit-\(UUID().uuidString)/user.json")
    let session = try composing("ji3{Down}", learnAt: url)
    let third = session.displayCandidates[2]
    #expect(session.handle(.char("3")).commit == third)
    #expect(session.buffer.isEmpty)
    #expect(!session.isSelecting)
    #expect(FileManager.default.fileExists(atPath: url.path), "learned like Enter")
}

@Test("N3: on the second page, 1 commits the tenth candidate and the window shows only that page")
func secondPage() throws {
    let session = try composing("ji3" + String(repeating: "{Down}", count: 9))
    try #require(session.candidates.count > 10)
    #expect(session.selectedIndex == 9)
    #expect(session.pageStart == 9)
    let page = Array(session.displayCandidates[9..<min(18, session.candidates.count)])
    #expect(session.visibleCandidates == page)
    let tenth = session.displayCandidates[9]
    #expect(session.handle(.char("1")).commit == tenth)
}

@Test("N3: on the first page the window shows at most nine candidates")
func firstPage() throws {
    let session = try composing("ji3")
    try #require(session.candidates.count > 9)
    #expect(session.pageStart == 0)
    #expect(session.visibleCandidates == Array(session.displayCandidates.prefix(9)))
}

@Test("N4: another layout key after ↓ composes and leaves the selecting state")
func layoutKeyLeavesSelecting() throws {
    for key in ["j", "0"] as [Character] {
        let session = try composing("ji3{Down}")
        #expect(session.isSelecting)
        #expect(session.handle(.char(key)) == Response(consumed: true, commit: nil))
        #expect(session.buffer == "ji3" + String(key))
        #expect(!session.isSelecting)
        #expect(session.handle(.char("3")).commit == nil, "3 composes again")
        #expect(session.buffer == "ji3" + String(key) + "3")
    }
}

@Test("N5: while selecting, promote and deepen leave candidates and selection alone")
func noReorderWhileSelecting() throws {
    let control = try composing("ji3")
    #expect(control.promote(2, ifBuffer: "ji3"), "positive control: promote works while typing")

    let session = try composing("ji3{Down}")
    let before = session.displayCandidates
    #expect(!session.promote(2, ifBuffer: "ji3"))
    #expect(!session.deepen())
    #expect(session.displayCandidates == before)
    #expect(session.selectedIndex == 1)
}

@Test("N6: English mode passes ↓ and digits through")
func englishModeUnaffected() throws {
    let session = try makeSession()
    _ = session.toggleEnglishMode()
    for key in parseKeys("ji3{Down}3") {
        #expect(session.handle(key) == Response(consumed: false, commit: nil))
    }
    #expect(session.buffer.isEmpty)
    #expect(!session.isSelecting)
}

@Test("N8: a digit past the last row is swallowed without changing anything")
func digitPastLastRow() throws {
    let session = try composing("ji3")
    let count = session.candidates.count
    for _ in 0..<(count - 1) { _ = session.handle(.down) }
    let lastPageRows = count - session.pageStart
    try #require(lastPageRows < 9, "need a short last page; \(count) candidates")
    let digit = Character(String(lastPageRows + 1))
    #expect(session.handle(.char(digit)) == Response(consumed: true, commit: nil))
    #expect(session.buffer == "ji3")
    #expect(session.selectedIndex == count - 1)
    #expect(session.isSelecting)
}

@Test("N9: Esc clears and Backspace deletes a key and leaves the selecting state")
func escAndBackspaceWhileSelecting() throws {
    let esc = try composing("ji3{Down}")
    #expect(esc.handle(.escape) == Response(consumed: true, commit: nil))
    #expect(esc.buffer.isEmpty && !esc.isSelecting)

    let bs = try composing("ji3{Down}")
    #expect(bs.handle(.backspace) == Response(consumed: true, commit: nil))
    #expect(bs.buffer == "ji" && !bs.isSelecting)
    #expect(bs.handle(.char("3")).commit == nil, "3 composes again")
    #expect(bs.buffer == "ji3")
}
