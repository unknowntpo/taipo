import AVFoundation
import Foundation
import Speech
import TaipoSpeech
import TaipoVoice

func transcribe(_ sentences: [Sentence], _ options: Options) async throws {
    let engine = options.engine ?? ""
    guard ["apple", "taipo-asr"].contains(engine) else {
        throw Failure("only --engine apple and taipo-asr run in Swift; Python engines live in scripts/asr")
    }
    let wavs = sentences.map { ($0.id, options.wav($0.id)) }.filter { FileManager.default.fileExists(atPath: $0.1.path) }
    if wavs.isEmpty { throw Failure("no recordings in \(options.setDir.path)") }
    let records: [ResultRecord]
    if engine == "taipo-asr" {
        records = try await InProcessEngine.transcribe(wavs)
    } else {
        guard #available(macOS 26, *) else { throw Failure("--engine apple needs macOS 26 (SpeechTranscriber)") }
        records = try await AppleEngine.transcribe(wavs)
    }
    try FileManager.default.createDirectory(at: options.resultsDir, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let lines = try records.map { String(decoding: try encoder.encode($0), as: UTF8.self) }
    let url = options.resultsDir.appendingPathComponent("\(engine).jsonl")
    try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    print("wrote \(records.count) results to \(url.path)")
}

/// Spec 012 W8: the IME's own runtime (whisper.cpp XCFramework through `WhisperRecognizer`), in process.
/// Seconds are per sentence, model load excluded; output is the raw recognizer text (no filler removal).
enum InProcessEngine {
    static func transcribe(_ wavs: [(String, URL)]) async throws -> [ResultRecord] {
        let recognizer = WhisperRecognizer()
        let clock = ContinuousClock()
        let loadStart = clock.now
        try await recognizer.load()
        print("model loaded in \(clock.now - loadStart)")
        var records: [ResultRecord] = []
        for (id, url) in wavs {
            let samples = try monoSamples(url)
            let start = clock.now
            let text = try await recognizer.transcribe(samples)
            let elapsed = clock.now - start
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            let audio = Double(samples.count) / MicrophoneRecorder.sampleRate
            records.append(ResultRecord(id: id, engine: "taipo-asr", text: text, seconds: seconds, audioSeconds: audio))
            print(String(format: "%@  %.2fs  %@", id, seconds, text))
        }
        return records
    }

    /// The recordings are 16 kHz mono (Spec 011); other formats are rejected rather than resampled.
    static func monoSamples(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard format.sampleRate == MicrophoneRecorder.sampleRate, format.channelCount == 1 else {
            throw Failure("\(url.lastPathComponent): need 16 kHz mono, got \(format.sampleRate) Hz × \(format.channelCount)")
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw Failure("\(url.lastPathComponent): cannot allocate buffer")
        }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else { throw Failure("\(url.lastPathComponent): not Float32") }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }
}

@available(macOS 26, *)
enum AppleEngine {
    static func transcribe(_ wavs: [(String, URL)]) async throws -> [ResultRecord] {
        guard SpeechTranscriber.isAvailable else { throw Failure("SpeechTranscriber is not available on this Mac") }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "zh_TW")) else {
            let supported = await SpeechTranscriber.supportedLocales.map(\.identifier).sorted()
            throw Failure("SpeechTranscriber does not support zh_TW; supported: \(supported.joined(separator: " "))")
        }
        if let request = try await AssetInventory.assetInstallationRequest(
            supporting: [SpeechTranscriber(locale: locale, preset: .transcription)]
        ) {
            print("installing speech assets for \(locale.identifier)…")
            try await request.downloadAndInstall()
        }
        var records: [ResultRecord] = []
        for (id, url) in wavs {
            let clock = ContinuousClock()
            let start = clock.now
            let file = try AVAudioFile(forReading: url)
            let audio = Double(file.length) / file.processingFormat.sampleRate
            let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            async let text = transcriber.results.reduce(into: "") { $0 += String($1.text.characters) }
            if let last = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: last)
            } else {
                await analyzer.cancelAndFinishNow()
            }
            let hypothesis = try await text
            let elapsed = clock.now - start
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            records.append(ResultRecord(id: id, engine: "apple", text: hypothesis, seconds: seconds, audioSeconds: audio))
            print(String(format: "%@  %.2fs  %@", id, seconds, hypothesis))
        }
        return records
    }
}

/// OpenCC s2twp through the uv-managed script; nil (with a warning) when it is missing or fails.
func s2twp(_ texts: [String]) -> [String]? {
    if texts.isEmpty { return [] }
    let script = "scripts/asr/s2twp.py"
    guard FileManager.default.fileExists(atPath: script) else {
        print("warning: \(script) not found; skipping s2twp column")
        return nil
    }
    let input = texts.map { $0.replacingOccurrences(of: "\n", with: " ") }.joined(separator: "\n") + "\n"
    guard let (status, output) = try? run("/usr/bin/env", ["uv", "run", script], input: input), status == 0 else {
        print("warning: \(script) failed; skipping s2twp column")
        return nil
    }
    let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let converted = Array(lines.prefix(texts.count))
    guard converted.count == texts.count else {
        print("warning: \(script) returned \(converted.count) lines for \(texts.count); skipping s2twp column")
        return nil
    }
    return converted
}

func score(_ sentences: [Sentence], _ options: Options) throws {
    let ids = sentences.map(\.id)
    let recorded = Set(ids.filter { FileManager.default.fileExists(atPath: options.wav($0).path) })
    var durations: [String: Double] = [:]
    for id in recorded { durations[id] = audioSeconds(options.wav(id)) }
    let files = ((try? FileManager.default.contentsOfDirectory(at: options.resultsDir, includingPropertiesForKeys: nil)) ?? [])
        .filter { $0.pathExtension == "jsonl" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    if files.isEmpty { throw Failure("no results/*.jsonl in \(options.setDir.path)") }
    var reports: [EngineReport] = []
    for file in files {
        let results = Corpus.results(jsonl: try String(contentsOf: file, encoding: .utf8))
        let scoredIDs = ids.filter { recorded.contains($0) && results.records[$0] != nil }
        let converted = s2twp(scoredIDs.map { results.records[$0]!.text })
            .map { Dictionary(uniqueKeysWithValues: zip(scoredIDs, $0)) }
        reports.append(Report.engine(file.deletingPathExtension().lastPathComponent, sentences: sentences,
                                     recorded: recorded, results: results, audioSeconds: durations, converted: converted))
    }
    if options.audioSet == "synth" { print("synthetic speech: smoke test only, do not pick an engine from these numbers\n") }
    print(Report.render(reports))
}
