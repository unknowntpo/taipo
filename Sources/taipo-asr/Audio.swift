import AVFoundation
import Foundation
import TaipoSpeech

func run(_ executable: String, _ arguments: [String], input: String? = nil) throws -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let stdout = Pipe()
    process.standardOutput = stdout
    let stdin = Pipe()
    if input != nil { process.standardInput = stdin }
    try process.run()
    if let input {
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try stdin.fileHandleForWriting.close()
    }
    let data = stdout.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

func audioSeconds(_ url: URL) -> Double? {
    guard let file = try? AVAudioFile(forReading: url) else { return nil }
    return Double(file.length) / file.processingFormat.sampleRate
}

/// Synthetic speech for smoke runs; never use these scores to pick an engine.
func synth(_ sentences: [Sentence], _ options: Options) throws {
    for sentence in sentences {
        let url = options.wav(sentence.id)
        let (status, _) = try run("/usr/bin/say", [
            "-v", "Meijia", "-o", url.path, "--file-format=WAVE", "--data-format=LEI16@16000", sentence.text,
        ])
        if status != 0 { throw Failure("say failed for \(sentence.id)") }
    }
    print("synthesized \(sentences.count) sentences into \(options.setDir.path)")
}

/// 16 kHz mono 16-bit WAV, one file per sentence; existing files are kept unless named by --redo.
func record(_ sentences: [Sentence], _ options: Options) async throws {
    guard await AVCaptureDevice.requestAccess(for: .audio) else {
        throw Failure("microphone access denied; allow it for this terminal in System Settings > Privacy & Security")
    }
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 16_000,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
    ]
    let todo = sentences.filter { options.redo.contains($0.id) || !FileManager.default.fileExists(atPath: options.wav($0.id).path) }
    print("\(todo.count) of \(sentences.count) sentences to record into \(options.setDir.path)")
    for (n, sentence) in todo.enumerated() {
        print("\n[\(n + 1)/\(todo.count)] \(sentence.id)  \(sentence.text)")
        print("Enter to start (s skip, q quit): ", terminator: "")
        let answer = readLine()
        if answer == nil || answer == "q" { return }
        if answer == "s" { continue }
        let partial = options.setDir.appendingPathComponent("\(sentence.id).part.wav")
        let recorder = try AVAudioRecorder(url: partial, settings: settings)
        guard recorder.record() else { throw Failure("could not start recording") }
        print("recording… Enter to stop: ", terminator: "")
        _ = readLine()
        recorder.stop()
        let url = options.wav(sentence.id)
        _ = try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: partial, to: url)
        print(String(format: "saved %.1f s", audioSeconds(url) ?? 0))
    }
}
