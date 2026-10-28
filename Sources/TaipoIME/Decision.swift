import Foundation
import TaipoCore

/// Shared on/off switch for the on-device decision model (Spec 004 D1). Stored in the
/// input method's preferences domain so the IME and the settings app see the same value.
public enum DecisionSettings {
    public static let suiteName = "com.unknowntpo.inputmethod.Taipo"
    public static let enabledKey = "decisionModelEnabled"
    /// Posted (distributed) by the settings app when the switch changes.
    public static let changed = Notification.Name("com.unknowntpo.inputmethod.Taipo.decisionSettingsChanged")

    /// The shared domain. Inside the IME (whose bundle id *is* the suite name) Apple returns nil
    /// for `UserDefaults(suiteName:)`, so the standard defaults are used there.
    public static var sharedDefaults: UserDefaults? {
        Bundle.main.bundleIdentifier == suiteName ? .standard : UserDefaults(suiteName: suiteName)
    }

    public static func isEnabled(in defaults: UserDefaults? = sharedDefaults) -> Bool {
        defaults?.bool(forKey: enabledKey) ?? false
    }

    public static func setEnabled(_ value: Bool, in defaults: UserDefaults? = sharedDefaults) {
        defaults?.set(value, forKey: enabledKey)
        DistributedNotificationCenter.default().postNotificationName(changed, object: nil, deliverImmediately: true)
    }
}

/// Picks the candidate the user most likely meant. Returns an index into `candidates`,
/// or nil to keep the engine's order. Implementations run fully on device.
public protocol CandidateDecider: Sendable {
    func choose(context: String, keys: String, candidates: [Candidate]) async throws -> Int?
    /// Same choice plus the per-candidate scores behind it (for the inspector, Spec 007).
    func decide(context: String, keys: String, candidates: [Candidate]) async throws -> Decision
}

public struct Decision: Sendable, Equatable {
    public let index: Int?
    public let scores: [Double]?

    public init(index: Int?, scores: [Double]?) {
        self.index = index
        self.scores = scores
    }
}

extension CandidateDecider {
    public func decide(context: String, keys: String, candidates: [Candidate]) async throws -> Decision {
        Decision(index: try await choose(context: context, keys: keys, candidates: candidates), scores: nil)
    }
}

public enum DecisionPolicy {
    public static let maxCandidates = 5

    /// Spec 004 D3: only ask the model when the engine is unsure. (A tail-first exclusion was
    /// dropped: no tail in 4,500 corpus inputs had a close or cross-language runner-up.)
    public static func isAmbiguous(_ candidates: [Candidate]) -> Bool {
        guard candidates.count >= 2 else { return false }
        let first = candidates[0], second = candidates[1]
        guard first.source != .literal, second.source != .literal else { return false }
        return first.language != second.language || first.score - second.score < Decoder.editPenalty
    }
}

/// Runs a decider after a pause and applies its answer only if the buffer did not change
/// (Spec 004 D4, D9–D12). Main-actor isolated: the IME calls it from key handling.
@MainActor
public final class DecisionCoordinator {
    public typealias Apply = @MainActor (_ buffer: String, _ index: Int) -> Void

    private let decider: CandidateDecider
    private let delay: Duration
    private let isEnabled: () -> Bool
    private var pending: Task<Void, Never>?
    private var decidedBuffer: String?
    /// Called with every decision that applies to the current buffer (Spec 007 inspector).
    public var onDecision: ((_ buffer: String, _ decision: Decision, _ millis: Double) -> Void)?
    public private(set) var log: [String] = []

    public init(decider: CandidateDecider, delay: Duration = .milliseconds(150), isEnabled: @escaping () -> Bool = { DecisionSettings.isEnabled() }) {
        self.decider = decider
        self.delay = delay
        self.isEnabled = isEnabled
    }

    /// Call after every key. Cancels any pending decision and schedules a new one if useful.
    public func schedule(session: CompositionSession, context: String, apply: @escaping Apply) {
        pending?.cancel()
        pending = nil
        let buffer = session.buffer
        let candidates = Array(session.candidates.prefix(DecisionPolicy.maxCandidates))
        guard isEnabled(), !buffer.isEmpty, buffer != decidedBuffer, DecisionPolicy.isAmbiguous(candidates) else { return }
        pending = Task { [decider, delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            let started = ContinuousClock.now
            let decision: Decision
            do {
                decision = try await decider.decide(context: context, keys: buffer, candidates: candidates)
            } catch {
                self.log.append("decider failed: \(error)")
                return
            }
            guard !Task.isCancelled, session.buffer == buffer else { return }
            self.decidedBuffer = buffer
            let ms = (ContinuousClock.now - started).components.attoseconds / 1_000_000_000_000_000
            let choice = decision.index
            self.log.append("decided \(buffer) → \(choice.map(String.init) ?? "keep") in \(ms) ms")
            self.onDecision?(buffer, decision, Double(ms))
            if let choice, candidates.indices.contains(choice), choice != 0 { apply(buffer, choice) }
        }
    }

    /// Returns and clears the decision log (the IME forwards it to os_log, Spec 004 D16).
    public func takeLog() -> [String] {
        defer { log.removeAll() }
        return log
    }

    /// Waits for the pending decision (tests and tools).
    public func settle() async { await pending?.value }
}

/// Spec 008: "記住我的選擇". When off, choosing a non-first candidate is neither remembered
/// nor written to the user dictionary. Default on (the behaviour before this switch existed).
public enum LearningSettings {
    public static let enabledKey = "learningEnabled"

    public static func isEnabled(in defaults: UserDefaults? = DecisionSettings.sharedDefaults) -> Bool {
        defaults?.object(forKey: enabledKey) as? Bool ?? true
    }

    public static func setEnabled(_ value: Bool, in defaults: UserDefaults? = DecisionSettings.sharedDefaults) {
        defaults?.set(value, forKey: enabledKey)
    }
}
