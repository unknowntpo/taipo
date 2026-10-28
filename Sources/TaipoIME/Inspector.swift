import Foundation
import TaipoCore

/// One step of candidate selection, sent from the IME to the Taipo app's live inspector
/// (Spec 007). Only sent while inspection is switched on.
public struct InspectorEvent: Codable, Sendable, Equatable {
    /// `voice`: one voice input (Spec 012 W10); `note` holds audio length, recognition time and result.
    public enum Kind: String, Codable, Sendable { case decode, deepen, decision, commit, voice }

    public struct Row: Codable, Sendable, Equatable {
        public let text: String
        public let language: String
        public let source: String
        /// Engine score; nil for the literal (−∞ has no JSON form).
        public let score: Double?
        public let edits: [String]
        public let segments: [String]
        /// Decision-model language score, when the model scored this row.
        public let lm: Double?
    }

    public let kind: Kind
    public let keys: String
    public let rows: [Row]
    public let chosen: Int?
    public let millis: Double
    public let note: String?

    public init(kind: Kind, keys: String, rows: [Row], chosen: Int?, millis: Double, note: String?) {
        self.kind = kind
        self.keys = keys
        self.rows = rows
        self.chosen = chosen
        self.millis = millis
        self.note = note
    }

    public static func rows(from candidates: [Candidate], lm: [Double]? = nil, limit: Int = 8) -> [Row] {
        candidates.prefix(limit).enumerated().map { i, c in
            Row(text: c.text, language: c.language.rawValue, source: c.source.rawValue,
                score: c.score.isFinite ? c.score : nil,
                edits: c.edits.map(\.description),
                segments: c.segments.map { $0.isTail ? "\($0.text)[tail]" : "\($0.text)[\($0.language.rawValue)]" },
                lm: lm.flatMap { $0.indices.contains(i) && $0[i].isFinite ? $0[i] : nil })
        }
    }

    static let payloadKey = "event"

    public var userInfo: [String: String] {
        let data = (try? JSONEncoder().encode(self)) ?? Data()
        return [Self.payloadKey: String(decoding: data, as: UTF8.self)]
    }

    public init?(userInfo: [AnyHashable: Any]?) {
        guard let json = userInfo?[Self.payloadKey] as? String,
              let event = try? JSONDecoder().decode(InspectorEvent.self, from: Data(json.utf8)) else { return nil }
        self = event
    }
}

/// Spec 007: the IME → app channel. Off by default because it sends what the user types to
/// another local process.
public enum InspectorFeed {
    public static let name = Notification.Name("com.unknowntpo.inputmethod.Taipo.inspector")
    public static let enabledKey = "inspectorEnabled"

    public static func isEnabled(in defaults: UserDefaults? = DecisionSettings.sharedDefaults) -> Bool {
        defaults?.bool(forKey: enabledKey) ?? false
    }

    public static func setEnabled(_ value: Bool, in defaults: UserDefaults? = DecisionSettings.sharedDefaults) {
        defaults?.set(value, forKey: enabledKey)
    }

    public static func publish(_ event: InspectorEvent, enabled: () -> Bool = { isEnabled() },
                               post: (InspectorEvent) -> Void = postDistributed) {
        guard enabled() else { return }
        post(event)
    }

    public static func postDistributed(_ event: InspectorEvent) {
        DistributedNotificationCenter.default().postNotificationName(name, object: nil, userInfo: event.userInfo, deliverImmediately: true)
    }
}
