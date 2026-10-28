// taipo-asr: speech engine evaluation (Spec 011).
//   taipo-asr synth                     say -v Meijia every sentence into <set>/<id>.wav
//   taipo-asr record [--redo id]        record each sentence: Enter to start, Enter to stop
//   taipo-asr transcribe --engine apple SpeechTranscriber (zh_TW) into <set>/results/apple.jsonl
//   taipo-asr transcribe --engine taipo-asr  the IME's whisper.cpp runtime (Spec 012) into results/taipo-asr.jsonl
//   taipo-asr score                     MER, s2twp MER, latency, RTF, worst sentences
// Common options:
//   --set real|synth   real = <dir>, synth = <dir>/synth (default real)
//   --dir PATH         default ~/Library/Application Support/Taipo/asr-eval
//   --sentences PATH   default <dir>/sentences.tsv (id<TAB>text per line; see Data/asr-eval/sentences.example.tsv)
import Foundation
import TaipoSpeech

struct Options {
    var command = ""
    var audioSet = "real"
    var dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Taipo/asr-eval")
    var sentencesPath: URL?
    var engine: String?
    var redo: Set<String> = []

    var sentences: URL { sentencesPath ?? dir.appendingPathComponent("sentences.tsv") }
    var setDir: URL { audioSet == "synth" ? dir.appendingPathComponent("synth") : dir }
    var resultsDir: URL { setDir.appendingPathComponent("results") }
    func wav(_ id: String) -> URL { setDir.appendingPathComponent("\(id).wav") }
}

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func parse(_ args: [String]) throws -> Options {
    var options = Options()
    var rest = args[...]
    guard let command = rest.popFirst() else { throw Failure("usage: taipo-asr synth|record|transcribe|score [options]") }
    options.command = command
    while let flag = rest.popFirst() {
        guard let value = rest.popFirst() else { throw Failure("missing value for \(flag)") }
        switch flag {
        case "--set":
            guard ["real", "synth"].contains(value) else { throw Failure("--set must be real or synth") }
            options.audioSet = value
        case "--dir": options.dir = URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
        case "--sentences": options.sentencesPath = URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
        case "--engine": options.engine = value
        case "--redo": options.redo.insert(value)
        default: throw Failure("unknown option \(flag)")
        }
    }
    return options
}

func loadSentences(_ options: Options) throws -> [Sentence] {
    guard FileManager.default.fileExists(atPath: options.sentences.path) else {
        throw Failure("""
            no sentence list at \(options.sentences.path)
            Create it (one "id<TAB>reference text" per line; see Data/asr-eval/sentences.example.tsv) or pass --sentences PATH.
            """)
    }
    let sentences = Corpus.sentences(tsv: try String(contentsOf: options.sentences, encoding: .utf8))
    if sentences.isEmpty { throw Failure("no sentences in \(options.sentences.path)") }
    return sentences
}

do {
    let options = try parse(Array(CommandLine.arguments.dropFirst()))
    let sentences = try loadSentences(options)
    try FileManager.default.createDirectory(at: options.setDir, withIntermediateDirectories: true)
    switch options.command {
    case "synth": try synth(sentences, options)
    case "record": try await record(sentences, options)
    case "transcribe": try await transcribe(sentences, options)
    case "score": try score(sentences, options)
    default: throw Failure("unknown command \(options.command)")
    }
} catch {
    FileHandle.standardError.write(Data("taipo-asr: \(error)\n".utf8))
    exit(1)
}
