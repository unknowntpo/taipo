import Foundation
import Testing
@testable import TaipoCore
@testable import TaipoIME

@Test("V1: an inspector event survives the notification round trip, including -inf scores")
func inspectorRoundTrip() throws {
    let candidates = [
        Candidate(text: "你好", language: .zh, edits: [.substitute(at: 2, typed: "e", intended: "3")], score: -18.4, source: .lexicon,
                  segments: [.init(text: "你好", language: .zh, isTail: false, end: 6)]),
        Candidate(text: "suecl3", language: .en, edits: [], score: -.infinity, source: .literal),
    ]
    let event = InspectorEvent(kind: .decision, keys: "suecl3", rows: InspectorEvent.rows(from: candidates, lm: [-8.5, -40]),
                               chosen: 0, millis: 262, note: nil)
    let decoded = try #require(InspectorEvent(userInfo: event.userInfo))
    #expect(decoded == event)
    #expect(decoded.rows[0].edits == ["substitute e→3 at 2"])
    #expect(decoded.rows[0].lm == -8.5)
    #expect(decoded.rows[1].score == nil, "-inf (literal) is sent as no score")
}

@Test("V2: the feed posts nothing while inspection is off")
func feedRespectsSwitch() {
    var posted: [InspectorEvent] = []
    let event = InspectorEvent(kind: .decode, keys: "ji3", rows: [], chosen: nil, millis: 1, note: nil)
    InspectorFeed.publish(event, enabled: { false }) { posted.append($0) }
    #expect(posted.isEmpty)
    InspectorFeed.publish(event, enabled: { true }) { posted.append($0) }
    #expect(posted == [event], "positive control")
}

@Test("V3: inspection defaults to off and round-trips through a preferences domain")
func inspectorSwitch() throws {
    let suite = "taipo-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    #expect(!InspectorFeed.isEnabled(in: defaults))
    InspectorFeed.setEnabled(true, in: defaults)
    #expect(InspectorFeed.isEnabled(in: defaults))
}

/// Answers with scores so the coordinator can report them (V4).
final class ScoringDecider: CandidateDecider, @unchecked Sendable {
    func choose(context: String, keys: String, candidates: [Candidate]) async throws -> Int? { 1 }
    func decide(context: String, keys: String, candidates: [Candidate]) async throws -> Decision {
        Decision(index: 1, scores: candidates.indices.map { -Double($0) })
    }
}

@Test("V4: the coordinator reports the decider's scores, choice and timing")
@MainActor
func coordinatorReportsDecision() async throws {
    let session = try typed("u4")
    let coordinator = DecisionCoordinator(decider: ScoringDecider(), delay: .milliseconds(1), isEnabled: { true })
    var reported: [(String, Decision)] = []
    coordinator.onDecision = { buffer, decision, _ in reported.append((buffer, decision)) }
    coordinator.schedule(session: session, context: "") { _, _ in }
    await coordinator.settle()
    #expect(reported.count == 1)
    #expect(reported.first?.0 == "u4")
    #expect(reported.first?.1.index == 1)
    #expect(reported.first?.1.scores?.count == min(5, session.candidates.count))
}

@Test("V5: every Dachen key has its Zhuyin label for the keycap view")
func dachenLabels() {
    #expect(Layout.zhuyinSymbol(for: "j") == "ㄨ")
    #expect(Layout.zhuyinSymbol(for: "3") == "ˇ")
    #expect(Layout.zhuyinSymbol(for: " ") == "ˉ")
    #expect(Layout.zhuyinSymbol(for: "!") == nil)
    #expect("1qaz2wsxedcrfv5tgbyhnujm8ik,9ol.0p;/-6347 ".allSatisfy { Layout.zhuyinSymbol(for: $0) != nil })
}

@Test("V7: notifications without a valid event are ignored")
func malformedInspectorNotification() {
    #expect(InspectorEvent(userInfo: nil) == nil)
    #expect(InspectorEvent(userInfo: ["event": "{not json"]) == nil)
    #expect(InspectorEvent(userInfo: ["other": "x"]) == nil)
    let valid = InspectorEvent(kind: .decode, keys: "ji3", rows: [], chosen: nil, millis: 1, note: nil)
    #expect(InspectorEvent(userInfo: valid.userInfo) == valid, "positive control")
}
