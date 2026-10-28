import Foundation
import Testing
@testable import TaipoCore
@testable import TaipoIME

/// Records calls and answers with a fixed index (or throws).
final class FakeDecider: CandidateDecider, @unchecked Sendable {
    let answer: Int?
    let fails: Bool
    private let lock = NSLock()
    private var _calls: [String] = []
    var calls: [String] { lock.withLock { _calls } }

    init(answer: Int?, fails: Bool = false) {
        self.answer = answer
        self.fails = fails
    }

    func choose(context: String, keys: String, candidates: [Candidate]) async throws -> Int? {
        lock.withLock { _calls.append(keys) }
        struct Boom: Error {}
        if fails { throw Boom() }
        return answer
    }
}

@MainActor
func typed(_ keys: String) throws -> CompositionSession {
    let session = try makeSession()
    for key in parseKeys(keys) { _ = session.handle(key) }
    return session
}

@MainActor
func decide(_ session: CompositionSession, _ decider: FakeDecider, enabled: Bool = true) async -> [String] {
    let coordinator = DecisionCoordinator(decider: decider, delay: .milliseconds(1), isEnabled: { enabled })
    var applied: [String] = []
    coordinator.schedule(session: session, context: "") { buffer, index in
        if session.promote(index, ifBuffer: buffer) { applied.append(session.markedText) }
    }
    await coordinator.settle()
    return applied
}

@Test("D1: the switch defaults to off and round-trips through a preferences domain")
func toggleRoundTrip() throws {
    let suite = "taipo-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    #expect(!DecisionSettings.isEnabled(in: defaults))
    DecisionSettings.setEnabled(true, in: defaults)
    #expect(DecisionSettings.isEnabled(in: UserDefaults(suiteName: suite)))
}

@Test("D3: ambiguity triggers only for close or cross-language top-2, never for tails")
@MainActor
func ambiguity() throws {
    #expect(DecisionPolicy.isAmbiguous(try typed("u4").candidates), "一 vs 意: scores within one edit")
    #expect(!DecisionPolicy.isAmbiguous(try typed("ji3").candidates), "我 far ahead of 婐")
    #expect(!DecisionPolicy.isAmbiguous(try typed("hrllo").candidates), "hello vs literal: literal never counts")
    let zh = Candidate(text: "彼此", language: .zh, edits: [], score: -9, source: .lexicon)
    let literal = Candidate(text: "1ueh3", language: .en, edits: [], score: -.infinity, source: .literal)
    #expect(!DecisionPolicy.isAmbiguous([zh, literal]), "the literal never counts, even across languages")
    let en = Candidate(text: "ueh", language: .en, edits: [], score: -30, source: .lexicon)
    #expect(DecisionPolicy.isAmbiguous([zh, en]), "positive control: a real cross-language runner-up counts")
}

@Test("D4: an answer for the current buffer is applied")
@MainActor
func appliesAnswer() async throws {
    let session = try typed("u4")
    let second = session.candidates[1].text
    let applied = await decide(session, FakeDecider(answer: 1))
    #expect(applied == [second])
    #expect(session.markedText == second)
}

@Test("D4: an answer that arrives after the buffer changed is dropped")
@MainActor
func dropsStaleAnswer() async throws {
    let session = try typed("u4")
    let coordinator = DecisionCoordinator(decider: FakeDecider(answer: 1), delay: .milliseconds(1), isEnabled: { true })
    var applied = 0
    coordinator.schedule(session: session, context: "") { _, _ in applied += 1 }
    _ = session.handle(.backspace)
    _ = session.handle(.char("3"))
    await coordinator.settle()
    #expect(applied == 0, "the coordinator itself drops the stale answer")
    #expect(session.buffer == "u3" && session.candidates.count > 1, "positive control: the new buffer has candidates")
    #expect(!session.promote(1, ifBuffer: "u4"), "promote refuses a stale buffer")
    #expect(session.promote(1, ifBuffer: "u3"), "positive control: promote accepts the current buffer")
}

@Test("D9: a failing decider keeps the engine order")
@MainActor
func failingDecider() async throws {
    let session = try typed("u4")
    let first = session.markedText
    #expect(await decide(session, FakeDecider(answer: 1, fails: true)).isEmpty)
    #expect(session.markedText == first)
}

@Test("D10: an out-of-range answer keeps the engine order")
@MainActor
func outOfRange() async throws {
    let session = try typed("u4")
    let first = session.markedText
    #expect(await decide(session, FakeDecider(answer: 99)).isEmpty)
    #expect(session.markedText == first)
}

@Test("D11: when the switch is off the decider is never called")
@MainActor
func disabledNeverCalls() async throws {
    let decider = FakeDecider(answer: 1)
    _ = await decide(try typed("u4"), decider, enabled: false)
    #expect(decider.calls.isEmpty)
    _ = await decide(try typed("u4"), decider, enabled: true)
    #expect(decider.calls == ["u4"], "positive control")
}

@Test("D12: repeated pauses on the same buffer ask once")
@MainActor
func asksOnce() async throws {
    let session = try typed("u4")
    let decider = FakeDecider(answer: nil)
    let coordinator = DecisionCoordinator(decider: decider, delay: .milliseconds(1), isEnabled: { true })
    for _ in 0..<3 {
        coordinator.schedule(session: session, context: "") { _, _ in }
        await coordinator.settle()
    }
    #expect(decider.calls == ["u4"])
}
