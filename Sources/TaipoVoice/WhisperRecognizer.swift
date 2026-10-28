import Foundation
import TaipoIME
import whisper

/// Spec 012 Behavior 3: Breeze-ASR-25 through whisper.cpp (Metal), language fixed to zh, greedy.
/// The model loads lazily (first `load()` or `transcribe`) and is freed by `unload()` (W9).
/// All whisper calls run on one serial queue; a whisper context is not thread safe.
public final class WhisperRecognizer: SpeechRecognizer, @unchecked Sendable {
    public enum Failure: LocalizedError {
        case modelMissing(URL)
        case loadFailed(URL)
        case transcriptionFailed(Int32)

        public var errorDescription: String? {
            switch self {
            case let .modelMissing(url): "找不到模型 \(url.lastPathComponent)"
            case let .loadFailed(url): "模型載入失敗 \(url.lastPathComponent)"
            case let .transcriptionFailed(code): "whisper_full 回傳 \(code)"
            }
        }
    }

    public let modelURL: URL
    private let threads: Int32
    private let queue = DispatchQueue(label: "com.unknowntpo.inputmethod.Taipo.whisper", qos: .userInitiated)
    /// Only touched on `queue`.
    private var context: OpaquePointer?

    public init(modelURL: URL = VoiceSettings.modelURL, threads: Int32 = 4) {
        self.modelURL = modelURL
        self.threads = threads
    }

    deinit {
        if let context { whisper_free(context) }
    }

    /// Loads the model now (in the background of the caller) instead of on first use.
    public func load() async throws {
        try await onQueue { _ = try self.loadIfNeeded() }
    }

    /// Frees the model; the next `transcribe` loads it again.
    public func unload() {
        queue.async {
            if let context = self.context { whisper_free(context) }
            self.context = nil
        }
    }

    public func transcribe(_ samples: [Float]) async throws -> String {
        let abort = AbortFlag()
        return try await withTaskCancellationHandler {
            try await onQueue { try self.run(samples, abort: abort) }
        } onCancel: {
            abort.set()
        }
    }

    private func onQueue<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try work() }) }
        }
    }

    private func loadIfNeeded() throws -> OpaquePointer {
        if let context { return context }
        guard FileManager.default.fileExists(atPath: modelURL.path) else { throw Failure.modelMissing(modelURL) }
        var params = whisper_context_default_params()
        params.use_gpu = true
        params.flash_attn = true  // 1.33 s vs 1.75 s per sentence; costs ~15 s of Metal compile per process launch
        guard let loaded = whisper_init_from_file_with_params(modelURL.path, params) else { throw Failure.loadFailed(modelURL) }
        context = loaded
        return loaded
    }

    private func run(_ samples: [Float], abort: AbortFlag) throws -> String {
        if abort.isSet { throw CancellationError() }
        guard !samples.isEmpty else { return "" }
        let context = try loadIfNeeded()
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.n_threads = threads
        params.translate = false
        params.no_context = true
        params.no_timestamps = true
        params.print_special = false
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.abort_callback = { data in
            guard let data else { return false }
            return Unmanaged<AbortFlag>.fromOpaque(data).takeUnretainedValue().isSet
        }
        params.abort_callback_user_data = Unmanaged.passUnretained(abort).toOpaque()
        let status = "zh".withCString { language in
            params.language = language
            return samples.withUnsafeBufferPointer { whisper_full(context, params, $0.baseAddress, Int32($0.count)) }
        }
        if abort.isSet { throw CancellationError() }
        guard status == 0 else { throw Failure.transcriptionFailed(status) }
        var text = ""
        for i in 0..<whisper_full_n_segments(context) {
            if let segment = whisper_full_get_segment_text(context, i) { text += String(cString: segment) }
        }
        return text
    }
}

/// Set from the cancelling task, read by whisper's abort callback on the decoding thread.
final class AbortFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}
