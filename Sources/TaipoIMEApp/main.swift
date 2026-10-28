import AppKit
import InputMethodKit
import os
import TaipoCore
import TaipoDecision
import TaipoIME
import TaipoVoice

let log = Logger(subsystem: "com.unknowntpo.inputmethod.Taipo", category: "app")
/// Spec 012 Behavior 9: non-content voice diagnostics only; never recognized text or audio.
let voiceLog = Logger(subsystem: "com.unknowntpo.inputmethod.Taipo", category: "voice")

/// Process-wide state shared by every client's controller.
enum AppState {
    static var candidates: IMKCandidates!
    static let shiftTap = ShiftTapDetector()
    /// Spec 013: one mode for the whole input method; each client's session follows it on activation.
    static var englishMode = false

    /// Loaded once at launch; a failure leaves every controller in pass-through mode (Spec 002 I13).
    static let decoder: Result<Decoder, Error> = {
        let start = Date()
        let result = Result<Decoder, Error> {
            guard let zh = Bundle.main.url(forResource: "zh", withExtension: "tsv"),
                  let en = Bundle.main.url(forResource: "en", withExtension: "tsv")
            else { throw LexiconError.unreadable(Bundle.main.bundleURL) }
            return try Decoder(lexicon: Lexicon(zhURL: zh, enURL: en), userDictionaryURL: UserDictionaryStore.defaultURL)
        }
        switch result {
        case let .success(decoder):
            log.notice("lexicon loaded in \(Int(Date().timeIntervalSince(start) * 1000)) ms")
            for line in decoder.diagnostics { log.error("\(line, privacy: .public)") }
        case let .failure(error):
            log.error("lexicon failed to load: \(String(describing: error), privacy: .public)")
        }
        return result
    }()
}

/// Spec 004: the Clef-mini decider, loaded in the background the first time the switch is on.
@MainActor
enum DecisionState {
    static var coordinator: DecisionCoordinator?
    private static var loading = false

    static func refresh() {
        guard DecisionSettings.isEnabled(), coordinator == nil, !loading else { return }
        loading = true
        Task { @MainActor in
            let start = Date()
            do {
                let clef = try await ClefMini.load()
                coordinator = DecisionCoordinator(decider: clef, delay: .zero)  // the IME already waits for the pause
                log.notice("decision model loaded in \(Int(Date().timeIntervalSince(start) * 1000)) ms")
            } catch {
                log.error("decision model unavailable: \(String(describing: error), privacy: .public)")
            }
            loading = false
        }
    }
}

/// Spec 012: the microphone and the whisper.cpp model are shared by every client's controller.
/// The model loads only while voice input is available (switch on, model installed) and is freed
/// when the switch goes off (W9).
@MainActor
enum VoiceState {
    static let recorder = MicrophoneRecorder()
    static let recognizer = WhisperRecognizer()
    private static var loaded = false

    static func refresh() {
        if VoiceSettings.isAvailable() {
            guard !loaded else { return }
            loaded = true
            Task { @MainActor in
                let start = Date()
                do {
                    try await recognizer.load()
                    log.notice("voice model loaded in \(Int(Date().timeIntervalSince(start) * 1000)) ms")
                } catch {
                    loaded = false
                    log.error("voice model unavailable: \(String(describing: error), privacy: .public)")
                }
            }
        } else if loaded {
            recognizer.unload()
            loaded = false
            log.notice("voice model unloaded")
        }
    }
}

/// Lets a `VoiceSession` drive one controller's client without the controller conforming itself.
@MainActor
final class VoiceBridge: VoiceHost {
    weak var controller: TaipoInputController?
    weak var session: VoiceSession?
    func commitComposition() { controller?.commitForVoice() }
    func showVoiceBar(_ bar: VoiceBar) {
        if case let .error(message) = bar { voiceLog.notice("error shown: \(message, privacy: .public)") }
        VoiceBarPanel.show(bar, session: session, client: controller?.voiceClient)
    }
    func insertVoiceText(_ text: String) { controller?.insertForVoice(text) }
}

@objc(TaipoInputController)
final class TaipoInputController: IMKInputController {
    private lazy var router = KeyRouter { CompositionSession(decoder: try AppState.decoder.get()) }
    /// Whether the client currently shows marked text; avoids redundant empty updates.
    private var showsMarkedText = false
    /// True while `apply` reloads the candidate window, whose delegate callbacks must not move the selection.
    private var isApplying = false

    // MARK: Spec 012 voice input
    /// The client that sent the last right-Shift event; used when `client()` is nil at insert time.
    private(set) var voiceClient: IMKTextInput?
    private var voiceSession: VoiceSession?
    private var voiceBridge: VoiceBridge?

    @MainActor private var voice: VoiceSession {
        if let voiceSession { return voiceSession }
        let session = VoiceSession(
            recorder: VoiceState.recorder, recognizer: VoiceState.recognizer,
            isAvailable: { VoiceSettings.isAvailable() },
            schedule: { delay, work in
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { work() } }
            },
            now: { ProcessInfo.processInfo.systemUptime })
        let bridge = VoiceBridge()
        bridge.controller = self
        bridge.session = session
        session.host = bridge
        session.onReport = { report in
            voiceLog.notice("""
                recognition done in \(report.recognitionSeconds, format: .fixed(precision: 2), privacy: .public) s, \
                audio \(report.audioSeconds, format: .fixed(precision: 1), privacy: .public) s, \
                \(report.text?.count ?? 0, privacy: .public) chars, error \(report.error ?? "none", privacy: .public)
                """)
            guard InspectorFeed.isEnabled() else { return }
            let note = String(format: "音長 %.1f 秒，辨識 %.2f 秒：", report.audioSeconds, report.recognitionSeconds)
                + (report.error.map { "失敗（\($0)）" } ?? (report.text?.isEmpty == false ? report.text! : "（空）"))
            InspectorFeed.publish(InspectorEvent(kind: .voice, keys: "", rows: [], chosen: nil,
                                                 millis: report.recognitionSeconds * 1000, note: note))
        }
        voiceSession = session
        voiceBridge = bridge
        return session
    }

    /// Right Shift alone is the trigger (Behavior 1). `flagsChanged` is always passed on so the app
    /// keeps an accurate modifier state; voice input only watches it.
    private func handleVoiceFlags(_ event: NSEvent, client: IMKTextInput?) {
        let mapped = RightShift.event(keyCode: event.keyCode, flags: event.modifierFlags.rawValue)
        if mapped != .otherKey { voiceClient = client }
        MainActor.assumeIsolated {
            let voice = self.voice
            let handled = voice.handle(mapped)
            guard mapped != .otherKey else { return }
            voiceLog.notice("""
                trigger \(mapped == .triggerDown ? "down" : "up", privacy: .public), handled \(handled, privacy: .public), \
                state \(String(describing: voice.state), privacy: .public), \
                client \(client?.bundleIdentifier() ?? "nil", privacy: .public)
                """)
        }
    }

    func commitForVoice() {
        guard let client = client() else { return }
        apply(Response(consumed: true, commit: router.session?.commitComposition()), client: client)
    }

    /// Behavior 5. Voice input sets no marked text (Behavior 8); `commitForVoice` has already
    /// replaced any composition. The replacement range is {NSNotFound, 0}, "insert at the selection".
    func insertForVoice(_ text: String) {
        let current = client()
        let target = current ?? voiceClient
        voiceLog.notice("""
            insert called, client() nil \(current == nil, privacy: .public), \
            client \(target?.bundleIdentifier() ?? "nil", privacy: .public), \
            marked text shown \(self.showsMarkedText, privacy: .public), \(text.count, privacy: .public) chars
            """)
        guard let target else { return }
        target.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        showsMarkedText = false
    }

    override func recognizedEvents(_ sender: Any!) -> Int {
        Int(NSEvent.EventTypeMask.keyDown.rawValue | NSEvent.EventTypeMask.flagsChanged.rawValue)
    }

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event else { return false }
        if event.type == .flagsChanged {
            handleVoiceFlags(event, client: sender as? IMKTextInput)
            if let client = sender as? IMKTextInput { handleShift(event, client: client) }
            return false
        }
        guard event.type == .keyDown, let client = sender as? IMKTextInput else { return false }
        AppState.shiftTap.otherKey()
        if MainActor.assumeIsolated({ voice.handle(event.keyCode == 53 ? .escape : .otherKey) }) { return true }
        let started = Date()
        let response = router.handle(Self.key(for: event))
        let millis = Date().timeIntervalSince(started) * 1000
        apply(response, client: client)
        Self.inspect(.decode, session: router.session, millis: millis)
        if let text = response.commit { Self.inspect(.commit, session: router.session, millis: 0, note: text) }
        scheduleDecision(client: client)
        return response.consumed
    }

    /// Spec 013: a lone left-Shift tap flips English mode (shared by every client, Behavior 4).
    /// Right Shift is left to Spec 012 voice input.
    private func handleShift(_ event: NSEvent, client: IMKTextInput) {
        guard let edge = ShiftTapDetector.leftShiftEdge(keyCode: event.keyCode, flags: event.modifierFlags.rawValue) else {
            AppState.shiftTap.otherKey()  // right Shift or another modifier: not a lone left-Shift tap
            return
        }
        guard let session = router.session else { return }
        guard AppState.shiftTap.shift(down: edge.down, at: event.timestamp, otherModifiers: edge.otherModifiers) else { return }
        let text = session.toggleEnglishMode()
        AppState.englishMode = session.isEnglishMode
        apply(Response(consumed: true, commit: text), client: client)
        let label = session.isEnglishMode ? "A" : "注"
        MainActor.assumeIsolated { ModeHUD.show(label, near: client) }
    }

    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        if let session = router.session, session.isEnglishMode != AppState.englishMode { _ = session.toggleEnglishMode() }
    }

    override func commitComposition(_ sender: Any!) {
        guard let client = sender as? IMKTextInput else { return }
        apply(Response(consumed: true, commit: router.session?.commitComposition()), client: client)
    }

    override func deactivateServer(_ sender: Any!) {
        if let voiceSession {
            MainActor.assumeIsolated {
                if voiceSession.state != .idle {
                    voiceLog.notice("deactivateServer cancels voice input in state \(String(describing: voiceSession.state), privacy: .public)")
                }
                voiceSession.cancel()
            }
        }
        commitComposition(sender)
        AppState.candidates.hide()
    }

    override func candidates(_ sender: Any!) -> [Any]! {
        router.session?.visibleCandidates ?? []  // Spec 014: one page, so the window's 1–9 labels match digit keys
    }

    override func candidateSelected(_ candidateString: NSAttributedString!) {
        guard let session = router.session, let client = self.client(),
              let index = selectedLine(matching: candidateString) else { return }
        apply(Response(consumed: true, commit: session.select(index)), client: client)
    }

    override func candidateSelectionChanged(_ candidateString: NSAttributedString!) {
        guard !isApplying, let session = router.session, let index = selectedLine(matching: candidateString) else { return }
        session.highlight(index)
        if let client = self.client() { updateMarkedText(client: client) }
    }

    /// The session index of the window's selected line; text matching alone is ambiguous when two
    /// candidates display the same. The window shows one page (Spec 014), so lines are page-relative.
    private func selectedLine(matching candidate: NSAttributedString?) -> Int? {
        guard let session = router.session else { return nil }
        let line = AppState.candidates.lineNumberForCandidate(withIdentifier: AppState.candidates.selectedCandidate())
        let page = session.visibleCandidates
        if page.indices.contains(line), page[line] == candidate?.string {
            return session.pageStart + line
        }
        return page.firstIndex(of: candidate?.string ?? "").map { session.pageStart + $0 }
    }

    private func apply(_ response: Response, client: IMKTextInput) {
        isApplying = true
        defer { isApplying = false }
        let none = NSRange(location: NSNotFound, length: NSNotFound)
        if let text = response.commit {
            client.insertText(text, replacementRange: none)
            showsMarkedText = false
        }
        updateMarkedText(client: client)
        for line in router.session?.takeDiagnostics() ?? [] { log.error("\(line, privacy: .public)") }

        guard let session = router.session, !session.buffer.isEmpty, session.candidates.count > 1 else {
            AppState.candidates.hide()
            return
        }
        let line = session.selectedIndex - session.pageStart
        AppState.candidates.update()
        AppState.candidates.show(kIMKLocateCandidatesBelowHint)
        AppState.candidates.selectCandidate(withIdentifier: AppState.candidates.candidateIdentifier(atLineNumber: line))
    }

    /// Spec 004 Behavior 4: after a pause, let the decision model re-pick the first candidate.
    /// Spec 006 / Spec 004: after a 150 ms pause, first deepen the search (adaptive retry), then
    /// let the decision model re-pick. A new key cancels both; neither blocks a keystroke.
    private var pauseWork: DispatchWorkItem?

    private func scheduleDecision(client: IMKTextInput) {
        pauseWork?.cancel()
        guard let session = router.session, !session.buffer.isEmpty else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated {
                let started = Date()
                let changed = session.deepen()
                if changed { self.apply(Response(consumed: true, commit: nil), client: client) }
                Self.inspect(.deepen, session: session, millis: Date().timeIntervalSince(started) * 1000,
                             note: changed ? "候選已更新" : "沒有變化")
                DecisionState.refresh()
                guard let coordinator = DecisionState.coordinator else { return }
                coordinator.onDecision = { buffer, decision, millis in
                    // Rows are the candidates the model saw (the decision applies before promotion).
                    guard session.buffer == buffer else { return }
                    Self.inspect(.decision, session: session, millis: millis,
                                 note: decision.index.map { $0 == 0 ? "保留引擎第一名" : "改選第 \($0 + 1) 名" } ?? "不改",
                                 lm: decision.scores, chosen: decision.index)
                }
                coordinator.schedule(session: session, context: Self.textBeforeCursor(client)) { [weak self] buffer, index in
                    guard let self, session.promote(index, ifBuffer: buffer) else { return }
                    log.info("decision model promoted \(session.markedText, privacy: .private) for \(buffer, privacy: .private)")
                    self.apply(Response(consumed: true, commit: nil), client: client)
                }
                for line in coordinator.takeLog() { log.info("\(line, privacy: .private)") }
            }
        }
        pauseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// Spec 007: send one step to the Taipo app's live inspector (no-op while it is off).
    static func inspect(_ kind: InspectorEvent.Kind, session: CompositionSession?, millis: Double,
                        note: String? = nil, lm: [Double]? = nil, chosen: Int? = nil) {
        guard InspectorFeed.isEnabled(), let session else { return }
        InspectorFeed.publish(InspectorEvent(kind: kind, keys: session.buffer,
                                             rows: InspectorEvent.rows(from: session.candidates, lm: lm),
                                             chosen: chosen ?? (session.candidates.isEmpty ? nil : session.selectedIndex),
                                             millis: millis, note: note))
    }

    private static func textBeforeCursor(_ client: IMKTextInput) -> String {
        let cursor = client.selectedRange().location
        guard cursor != NSNotFound, cursor > 0 else { return "" }
        let start = max(0, cursor - 20)
        return client.attributedSubstring(from: NSRange(location: start, length: cursor - start))?.string ?? ""
    }

    private func updateMarkedText(client: IMKTextInput) {
        let marked = router.session?.markedText ?? ""
        guard !marked.isEmpty || showsMarkedText else { return }
        let none = NSRange(location: NSNotFound, length: NSNotFound)
        let attributed = NSAttributedString(string: marked, attributes: [
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .markedClauseSegment: 0,
        ])
        client.setMarkedText(attributed, selectionRange: NSRange(location: marked.utf16.count, length: 0), replacementRange: none)
        showsMarkedText = !marked.isEmpty
    }

    /// Maps an AppKit key event to the session's key vocabulary (Spec 002 Behavior 2–9).
    static func key(for event: NSEvent) -> Key {
        if !event.modifierFlags.intersection([.command, .control, .option]).isEmpty { return .other }
        switch event.keyCode {
        case 49: return .space
        case 36, 76: return .enter
        case 53: return .escape
        case 51: return .backspace
        case 126: return .up
        case 125: return .down
        default: break
        }
        // Keypad digits and operators are not Zhuyin keys.
        if event.modifierFlags.contains(.numericPad) { return .other }
        guard let chars = event.characters, chars.count == 1, let c = chars.first, Key.isLayoutCharacter(c) else { return .other }
        return .char(c)
    }
}

/// Spec 012 Behavior 8: the floating bar. A borderless, non-activating panel that never takes focus
/// from the app: a flat pill with ✕ (cancel) and the waveform, a spinner with "Thinking…" while
/// recognizing, or one error line. It fades in and out; releasing right Shift finishes recording.
@MainActor
enum VoiceBarPanel {
    /// The session the ✕ button and the microphone levels go to.
    static weak var session: VoiceSession?
    static let height: CGFloat = 40
    /// Above the Dock, from the bottom of the screen's visible frame.
    static let bottomOffset: CGFloat = 15
    static let fadeDuration = 0.2
    static let resizeDuration = 0.25
    private static var panel: NSPanel?
    /// W18, W25: whether the bar is shown, and what a show or an ended fade-out does to the panel.
    private static var fade = BarFade()
    /// The running fade. The fade steps the window alpha itself, so a new fade cancels the old one
    /// and the last show or hide always writes the final alpha.
    private static var fadeTimer: Timer?
    private static let content = VoiceBarView(frame: NSRect(x: 0, y: 0, width: 120, height: height))

    static func show(_ bar: VoiceBar, session: VoiceSession?, client: IMKTextInput?) {
        guard bar != .hidden else {
            hide()
            return
        }
        self.session = session
        let panel = self.panel ?? make()
        let width = content.apply(bar)
        let opaque = panel.alphaValue == 1
        if fade.show(visible: panel.isVisible, opaque: opaque) == .fadeIn {
            let area = screen(for: client)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            panel.setFrame(NSRect(x: (area.midX - width / 2).rounded(), y: area.minY + bottomOffset,
                                  width: width, height: height), display: true)
            fadeIn(panel)
        } else if panel.frame.width != width {
            var frame = panel.frame
            frame.origin.x = (frame.midX - width / 2).rounded()
            frame.size.width = width
            NSAnimationContext.runAnimationGroup { context in
                context.duration = resizeDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(frame, display: true)
            }
        }
    }

    private static func hide() {
        guard let panel, let token = fade.hide() else { return }
        fade(panel, to: 0) {
            switch fade.fadeOutEnded(token) {
            case .orderOut:
                panel.orderOut(nil)
                content.stopAnimations()
            case .restore:
                if !panel.isVisible || panel.alphaValue != 1 { fadeIn(panel) }
            case .ignore:
                break
            }
        }
    }

    private static func fadeIn(_ panel: NSPanel) {
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        fade(panel, to: 1)
    }

    /// Cancels any running fade and steps the alpha from its current value to `target` in `fadeDuration`.
    private static func fade(_ panel: NSPanel, to target: CGFloat, then completion: (@MainActor () -> Void)? = nil) {
        fadeTimer?.invalidate()
        let start = panel.alphaValue
        let began = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { timer in
            MainActor.assumeIsolated {
                let progress = min(1, (CACurrentMediaTime() - began) / fadeDuration)
                panel.alphaValue = start + (target - start) * progress
                guard progress >= 1, fadeTimer === timer else { return }
                timer.invalidate()
                fadeTimer = nil
                completion?()
            }
        }
        fadeTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// The screen with the caret, else the one with the mouse.
    private static func screen(for client: IMKTextInput?) -> NSScreen? {
        var line = NSRect.zero
        if let client { _ = client.attributes(forCharacterIndex: 0, lineHeightRectangle: &line) }
        let point = line != .zero ? NSPoint(x: line.midX, y: line.midY) : NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
    }

    private static func make() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 120, height: height),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.isMovable = false
        content.autoresizingMask = [.width, .height]
        p.contentView = content
        panel = p
        return p
    }
}

/// A button that acts on the first click although its window is never key.
final class FirstClickButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The pill: a flat surface in the system appearance with a 1 px hairline border and no shadow.
final class VoiceBarView: NSView {
    static let inset: CGFloat = 8, buttonSide: CGFloat = 24, gap: CGFloat = 10, trailing: CGFloat = 16
    private let cancel = FirstClickButton(frame: .zero)
    private let wave = WaveformView(frame: NSRect(x: 0, y: 0, width: WaveformView.width, height: WaveformView.height))
    private let spinner = NSProgressIndicator()
    private let working = NSTextField(labelWithString: "Thinking…")
    private let message = NSTextField(labelWithString: "")
    private var bar = VoiceBar.hidden

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = VoiceBarPanel.height / 2
        layer?.borderWidth = 1
        layer?.masksToBounds = true
        cancel.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "取消")?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        cancel.imagePosition = .imageOnly
        cancel.isBordered = false
        cancel.wantsLayer = true
        cancel.layer?.cornerRadius = Self.buttonSide / 2
        cancel.toolTip = "取消"
        cancel.target = self
        cancel.action = #selector(cancelTapped)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        for label in [working, message] {
            label.font = .systemFont(ofSize: 12)
            label.lineBreakMode = .byTruncatingTail
        }
        message.alignment = .center
        for view in [cancel, wave, spinner, working, message] as [NSView] { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.98).cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
        cancel.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        cancel.contentTintColor = .secondaryLabelColor
        working.textColor = .labelColor
        message.textColor = .labelColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        wave.refreshColors()
    }

    /// Shows `bar` and returns the pill width it needs.
    func apply(_ bar: VoiceBar) -> CGFloat {
        self.bar = bar
        let leading = Self.inset + Self.buttonSide + Self.gap
        var width = leading + WaveformView.width + Self.trailing
        switch bar {
        case .hidden:
            break
        case .arming:
            wave.arm()
        case let .listening(levels):
            wave.show(levels)
        case .recognizing:
            width = leading + 16 + 6 + working.intrinsicContentSize.width + Self.trailing
        case let .error(text):
            message.stringValue = "⚠︎ " + text
            width = min(560, max(160, message.intrinsicContentSize.width + 32))
        }
        let isError: Bool = if case .error = bar { true } else { false }
        let isRecording: Bool = switch bar { case .arming, .listening: true; default: false }
        wave.isHidden = !isRecording
        if !isRecording { wave.stop() }
        if bar == .recognizing { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        spinner.isHidden = bar != .recognizing
        working.isHidden = bar != .recognizing
        message.isHidden = !isError
        cancel.isHidden = isError
        needsLayout = true
        return width.rounded(.up)
    }

    func stopAnimations() {
        wave.stop()
        spinner.stopAnimation(nil)
    }

    override func layout() {
        super.layout()
        let h = bounds.height, side = Self.buttonSide
        cancel.frame = NSRect(x: Self.inset, y: (h - side) / 2, width: side, height: side)
        let x = Self.inset + side + Self.gap
        wave.frame = NSRect(x: x, y: (h - WaveformView.height) / 2, width: WaveformView.width, height: WaveformView.height)
        spinner.frame = NSRect(x: x, y: (h - 16) / 2, width: 16, height: 16)
        let labelHeight = working.intrinsicContentSize.height
        working.frame = NSRect(x: x + 16 + 6, y: (h - labelHeight) / 2,
                               width: max(0, bounds.width - x - 22 - Self.trailing + 2), height: labelHeight)
        message.frame = NSRect(x: 16, y: (h - labelHeight) / 2, width: max(0, bounds.width - 32), height: labelHeight)
    }

    @objc private func cancelTapped() { VoiceBarPanel.session?.cancel() }
}

/// Nine bars, one per band (W13). While arming (W16) they are muted grey with a pulse travelling
/// left to right; once levels arrive they follow the microphone.
final class WaveformView: NSView {
    static let count = VoiceSpectrum.bandCount
    static let barWidth: CGFloat = 4, gap: CGFloat = 3, height: CGFloat = 18, minimumBar: CGFloat = 3
    static let width = CGFloat(count) * barWidth + CGFloat(count - 1) * gap
    private var bars: [CALayer] = []
    private var isArming = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for i in 0..<Self.count {
            let bar = CALayer()
            bar.cornerRadius = Self.barWidth / 2
            bar.frame = Self.rect(i, height: Self.minimumBar)
            layer?.addSublayer(bar)
            bars.append(bar)
        }
        refreshColors()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private static func rect(_ i: Int, height: CGFloat) -> CGRect {
        CGRect(x: CGFloat(i) * (barWidth + gap), y: (Self.height - height) / 2, width: barWidth, height: height)
    }

    func refreshColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let color = (isArming ? NSColor.secondaryLabelColor : NSColor.labelColor).cgColor
            for bar in bars { bar.backgroundColor = color }
        }
    }

    func arm() {
        guard !isArming else { return }
        isArming = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        refreshColors()
        let start = CACurrentMediaTime()
        for (i, bar) in bars.enumerated() {
            bar.frame = Self.rect(i, height: 6)
            bar.opacity = 0.35
            let scale = CABasicAnimation(keyPath: "transform.scale.y")
            scale.fromValue = 0.55
            scale.toValue = 1.5
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.25
            fade.toValue = 0.7
            let pulse = CAAnimationGroup()
            pulse.animations = [scale, fade]
            pulse.duration = 0.45
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            pulse.beginTime = start + Double(i) * 0.075
            pulse.fillMode = .backwards
            bar.add(pulse, forKey: "arming")
        }
        CATransaction.commit()
    }

    func show(_ levels: [Float]) {
        if isArming { stop() }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.08)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .linear))
        for (i, bar) in bars.enumerated() {
            let level = i < levels.count ? CGFloat(levels[i]) : 0
            let h = max(Self.minimumBar, min(Self.height, Self.minimumBar + pow(level, 0.7) * (Self.height - Self.minimumBar)))
            bar.frame = Self.rect(i, height: h)
        }
        CATransaction.commit()
    }

    /// Back to flat bars in the live color, with no animation.
    func stop() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        isArming = false
        for (i, bar) in bars.enumerated() {
            bar.removeAnimation(forKey: "arming")
            bar.opacity = 1
            bar.frame = Self.rect(i, height: Self.minimumBar)
        }
        refreshColors()
        CATransaction.commit()
    }
}

/// Spec 013 Behavior 5: a brief "A" / "注" near the caret after a mode switch.
@MainActor
enum ModeHUD {
    private static var panel: NSPanel?
    private static var hide: DispatchWorkItem?

    static func show(_ text: String, near client: IMKTextInput) {
        var line = NSRect.zero
        _ = client.attributes(forCharacterIndex: 0, lineHeightRectangle: &line)
        guard line != .zero else { return }
        let size = NSSize(width: 36, height: 30)
        let panel = self.panel ?? {
            let p = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
            p.level = .popUpMenu
            p.isOpaque = false
            p.backgroundColor = .clear
            p.ignoresMouseEvents = true
            let label = NSTextField(labelWithString: "")
            label.font = .systemFont(ofSize: 17, weight: .medium)
            label.alignment = .center
            label.frame = NSRect(x: 0, y: 5, width: size.width, height: 20)
            let box = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
            box.material = .hudWindow
            box.state = .active
            box.wantsLayer = true
            box.layer?.cornerRadius = 7
            box.addSubview(label)
            p.contentView = box
            self.panel = p
            return p
        }()
        (panel.contentView?.subviews.first as? NSTextField)?.stringValue = text
        panel.setFrameOrigin(NSPoint(x: line.minX, y: line.minY - size.height - 4))
        panel.orderFrontRegardless()
        hide?.cancel()
        let work = DispatchWorkItem { panel.orderOut(nil) }
        hide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }
}

let server = IMKServer(name: "com.unknowntpo.inputmethod.Taipo_Connection", bundleIdentifier: Bundle.main.bundleIdentifier)
AppState.candidates = IMKCandidates(server: server, panelType: kIMKSingleColumnScrollingCandidatePanel)
_ = AppState.decoder
DistributedNotificationCenter.default().addObserver(forName: DecisionSettings.changed, object: nil, queue: .main) { _ in
    MainActor.assumeIsolated { DecisionState.refresh() }
}
MainActor.assumeIsolated { DecisionState.refresh() }
// Spec 012: load or free the voice model when the switch changes or the model is downloaded.
DistributedNotificationCenter.default().addObserver(forName: VoiceSettings.changed, object: nil, queue: .main) { _ in
    MainActor.assumeIsolated { VoiceState.refresh() }
}
MainActor.assumeIsolated { VoiceState.refresh() }
// Spec 012 W13, W16: the microphone band levels drive the floating bar's waveform.
MainActor.assumeIsolated {
    VoiceState.recorder.onLevels = { levels in
        DispatchQueue.main.async { MainActor.assumeIsolated { VoiceBarPanel.session?.updateLevels(levels) } }
    }
}
// Spec 010: the Taipo app cleared the learned choices; forget them in memory, and trash the file again
// in case a choice learned during the clear wrote the old entries back.
DistributedNotificationCenter.default().addObserver(forName: UserDictionaryStore.cleared, object: nil, queue: .main) { _ in
    guard let decoder = try? AppState.decoder.get() else { return }
    decoder.clearUserDictionary()
    do {
        try UserDictionaryStore.clear(notify: {})
        log.notice("user dictionary cleared")
    } catch {
        log.error("user dictionary clear failed: \(String(describing: error), privacy: .public)")
    }
}
log.notice("Taipo input method started")
NSApplication.shared.run()
