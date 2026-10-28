import TaipoCore

/// A key press as the composition state machine sees it (no AppKit types).
public enum Key: Equatable, Sendable {
    /// Unmodified layout key: a–z, A–Z, 0–9, `,` `.` `;` `/` `-`.
    case char(Character)
    case space, enter, escape, backspace, up, down
    /// Any other key, or any key with ⌘ / ⌃ / ⌥.
    case other

    public static func isLayoutCharacter(_ c: Character) -> Bool {
        guard c.isASCII, let v = c.asciiValue else { return false }
        return c.isLetter || c.isNumber || ",.;/-".utf8.contains(v)
    }
}

public struct Response: Equatable, Sendable {
    /// False means the app should receive the original key.
    public let consumed: Bool
    /// Text to insert into the client before anything else.
    public let commit: String?

    public init(consumed: Bool, commit: String?) {
        self.consumed = consumed
        self.commit = commit
    }
}

/// Composition state for one input client (Spec 002 Behavior 1–12).
public final class CompositionSession {
    /// Spec 005: above this many keys, leading phrases are committed automatically…
    public static let autoCommitAbove = 24
    /// …keeping at least this many keys composing.
    public static let keepKeys = 12

    private let decoder: Decoder
    public private(set) var buffer = ""
    public private(set) var candidates: [Candidate] = []
    public private(set) var selectedIndex = 0
    public private(set) var previousLanguage: Language?
    public private(set) var diagnostics: [String] = []
    /// Spec 013: while on, every key goes to the app untouched.
    public private(set) var isEnglishMode = false
    private var deepenedBuffer: String?

    private let isLearningEnabled: () -> Bool

    public init(decoder: Decoder, isLearningEnabled: @escaping () -> Bool = { LearningSettings.isEnabled() }) {
        self.decoder = decoder
        self.isLearningEnabled = isLearningEnabled
    }

    /// What the composition area shows: the selected candidate as it would be committed.
    public var markedText: String {
        candidates.indices.contains(selectedIndex) ? displayText(candidates[selectedIndex]) : ""
    }

    public var displayCandidates: [String] { candidates.map(displayText) }

    /// Spec 014: candidates per candidate-window page; digit keys 1–9 address one page.
    public static let pageSize = 9
    /// Spec 014: true after ↓/↑ until the composition changes; digits then select instead of composing.
    public private(set) var isSelecting = false
    /// Spec 014: index of the first candidate on the selection's page.
    public var pageStart: Int { selectedIndex / Self.pageSize * Self.pageSize }
    /// Spec 014: the candidates the window shows (the selection's page).
    public var visibleCandidates: [String] {
        Array(displayCandidates[min(pageStart, candidates.count)..<min(pageStart + Self.pageSize, candidates.count)])
    }

    public func handle(_ key: Key) -> Response {
        if isEnglishMode { return pass() }
        if case let .char(c) = key, let digit = c.wholeNumberValue, (1...Self.pageSize).contains(digit),
           isSelecting || digitSelectsDirectly(c) {
            // Spec 014 Behavior 2: a row past the last candidate swallows the key.
            let index = pageStart + digit - 1
            guard candidates.indices.contains(index) else { return Response(consumed: true, commit: nil) }
            selectedIndex = index
            return Response(consumed: true, commit: commitSelected())
        }
        switch key {
        case let .char(c) where Key.isLayoutCharacter(c):
            buffer.append(c)
            refresh()
            return Response(consumed: true, commit: autoCommit())
        case .space:
            guard !buffer.isEmpty else { return pass() }
            let withTone = buffer + " "
            if let top = decoder.decode(withTone, previousLanguage: previousLanguage).candidates.first,
               top.language == .zh, top.edits.isEmpty, top.source != .literal {
                buffer = withTone
                refresh()
                return Response(consumed: true, commit: autoCommit())
            }
            // Space never commits an unfinished tail (Spec 003 X14): take the first candidate that
            // explains every key without edits. This is not the user's choice, so nothing is learned.
            var learn = true
            if candidates[selectedIndex].source == .partial,
               let complete = candidates.firstIndex(where: { $0.edits.isEmpty && $0.source != .partial && $0.source != .literal }) {
                selectedIndex = complete
                learn = false
            }
            let language = candidates[selectedIndex].language
            let text = commitSelected(learn: learn)
            return Response(consumed: true, commit: language == .en ? text + " " : text)
        case .enter:
            guard !buffer.isEmpty else { return pass() }
            return Response(consumed: true, commit: commitSelected())
        case .escape:
            guard !buffer.isEmpty else { return pass() }
            clear()
            return Response(consumed: true, commit: nil)
        case .backspace:
            guard !buffer.isEmpty else { return pass() }
            buffer.removeLast()
            refresh()
            return Response(consumed: true, commit: nil)
        case .up, .down:
            guard !buffer.isEmpty else { return pass() }
            let step = key == .down ? 1 : -1
            selectedIndex = min(max(selectedIndex + step, 0), candidates.count - 1)
            isSelecting = true
            return Response(consumed: true, commit: nil)
        case .char, .other:
            guard !buffer.isEmpty else { return pass() }
            return Response(consumed: false, commit: commitSelected())
        }
    }

    /// Spec 017: without ↓/↑, a digit still selects when the first candidate is an English dictionary
    /// word and the digit does not continue a Chinese reading (`Decoder.continuesChinese`).
    private func digitSelectsDirectly(_ digit: Character) -> Bool {
        guard let first = candidates.first, first.language == .en,
              [.lexicon, .user, .learned].contains(first.source) else { return false }
        return !decoder.continuesChinese(buffer, with: digit, previousLanguage: previousLanguage)
    }

    /// Spec 013: commits what is shown (without learning) and flips English mode.
    public func toggleEnglishMode() -> String? {
        let text = buffer.isEmpty ? nil : commitSelected(learn: false)
        isEnglishMode.toggle()
        return text
    }

    /// Commits candidate `index` (e.g. clicked in the candidate window).
    public func select(_ index: Int) -> String? {
        guard candidates.indices.contains(index) else { return nil }
        selectedIndex = index
        return commitSelected()
    }

    /// Moves the selection without committing (e.g. highlight in the candidate window).
    public func highlight(_ index: Int) {
        if candidates.indices.contains(index) { selectedIndex = index }
    }

    /// Moves candidate `index` to the front when the buffer is still `buffer` (Spec 004 D4).
    /// Spec 014: never while the user is selecting, so a digit still names the row it shows.
    @discardableResult
    public func promote(_ index: Int, ifBuffer expected: String) -> Bool {
        guard !isSelecting, buffer == expected, candidates.indices.contains(index), index != 0 else { return false }
        let chosen = candidates.remove(at: index)
        candidates.insert(chosen, at: 0)
        selectedIndex = 0
        return true
    }

    /// Spec 006: after a pause, decode the buffer again with the adaptive retry. Returns true when
    /// the candidates changed. Cheap no-op for short input, a buffer already deepened, or while selecting (Spec 014).
    @discardableResult
    public func deepen() -> Bool {
        guard !isSelecting, !buffer.isEmpty, buffer != deepenedBuffer, Decoder.canDeepen(buffer) else { return false }
        deepenedBuffer = buffer
        let deeper = decoder.decode(buffer, previousLanguage: previousLanguage, deep: true).candidates
        guard deeper.map(\.text) != candidates.map(\.text) else { return false }
        candidates = deeper
        selectedIndex = 0
        return true
    }

    /// Returns and clears diagnostics collected since the last call.
    public func takeDiagnostics() -> [String] {
        defer { diagnostics.removeAll() }
        return diagnostics
    }

    /// Focus loss: commit what is shown (Behavior 12).
    public func commitComposition() -> String? {
        buffer.isEmpty ? nil : commitSelected()
    }

    private func pass() -> Response { Response(consumed: false, commit: nil) }

    /// Spec 005: once the buffer is longer than `autoCommitAbove` keys, commit the leading
    /// complete segments of the first candidate, keeping at least `keepKeys` keys composing.
    /// Without this, inputs beyond Spec 001's 32-key cap decode to raw keys.
    private func autoCommit() -> String? {
        let keys = buffer.utf8.count
        guard keys > Self.autoCommitAbove, let top = candidates.first else { return nil }
        let leading = Array(top.segments.prefix { !$0.isTail && $0.end <= keys - Self.keepKeys })
        guard let last = leading.last else { return nil }
        let text = Candidate.Segment.join(leading)
        buffer = String(decoding: buffer.utf8.dropFirst(last.end), as: UTF8.self)
        previousLanguage = last.language
        refresh()
        return text
    }

    private func refresh() {
        selectedIndex = 0
        isSelecting = false
        candidates = buffer.isEmpty ? [] : decoder.decode(buffer, previousLanguage: previousLanguage).candidates
    }

    private func clear() {
        buffer = ""
        candidates = []
        selectedIndex = 0
        isSelecting = false
    }

    private func commitSelected(learn: Bool = true) -> String {
        let candidate = candidates[selectedIndex]
        if learn, selectedIndex != 0, isLearningEnabled() {
            do {
                try decoder.learn(input: buffer, chosen: candidate.text)
            } catch {
                diagnostics.append("learn failed: \(error)")
            }
        }
        let text = displayText(candidate)
        previousLanguage = candidate.language
        clear()
        return text
    }

    private func displayText(_ c: Candidate) -> String {
        guard c.language == .en, c.source != .literal,
              let first = buffer.first, first.isUppercase else { return c.text }
        return c.text.prefix(1).uppercased() + c.text.dropFirst()
    }
}

/// Routes keys to a session, or passes everything through when the session
/// could not be created (e.g. the lexicon failed to load; Spec 002 I13).
public final class KeyRouter {
    public let session: CompositionSession?
    public let failure: String?

    public init(provider: () throws -> CompositionSession) {
        do {
            session = try provider()
            failure = nil
        } catch {
            session = nil
            failure = "\(error)"
        }
    }

    public func handle(_ key: Key) -> Response {
        session?.handle(key) ?? Response(consumed: false, commit: nil)
    }
}
