import Darwin
import Foundation
import TaipoCore
import TaipoIME
import TaipoDecision

/// Budget measurements for Spec 001 (M1 latency, M2 memory, M3 load). Run with -c release.
func residentBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
    }
    return kr == KERN_SUCCESS ? info.resident_size : 0
}

func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e6 }

let mode = CommandLine.arguments.dropFirst().first ?? "all"
let before = residentBytes()
let t0 = now()
let lexicon = try Lexicon.bundled()
let loadMs = now() - t0
let memMB = Double(residentBytes() - before) / 1_048_576
let dict = FileManager.default.temporaryDirectory.appendingPathComponent("taipo-bench-\(getpid()).json")
let decoder = try Decoder(lexicon: lexicon, userDictionaryURL: dict)

if mode == "load" || mode == "all" { print(String(format: "M3 load: %.1f ms (limit 300)", loadMs)) }
if mode == "memory" || mode == "all" { print(String(format: "M2 memory: %.1f MB (limit 50)", memMB)) }
if mode == "latency" || mode == "all" {
    let inputs = ["hrllo", "teh", "su3cl3", "ji3", "tupinh", "up ", "u4", "form", "su3cl3ji3",
                  "typingspeed", "5j4ek7", "hellowordl", "ji3cl3 ", "vu3fu3", "computerr"]
    var samples: [Double] = []
    for _ in 0..<50 {
        for input in inputs {
            let start = now()
            _ = decoder.decode(input, previousLanguage: nil)
            samples.append(now() - start)
        }
    }
    samples.sort()
    let p95 = samples[Int(Double(samples.count) * 0.95)]
    let worst = inputs.map { input -> (String, Double) in
        let s = now(); _ = decoder.decode(input, previousLanguage: nil); return (input, now() - s)
    }.max { $0.1 < $1.1 }!
    let sentence = "5k4ek7cl3vu;4u.32u03tricky"
    var longKeys: [Double] = []
    for _ in 0..<5 {
        // Spec 005 L4: the user's 47-key sentence typed key by key, with auto-commit.
        let typing = CompositionSession(decoder: decoder)
        for c in "rup wu0 2k7wu0 fu4cp3cl3cp3g4ck6tj ap6m/422j/4i" {
            let s = now(); _ = typing.handle(c == " " ? .space : .char(c)); longKeys.append(now() - s)
        }
        _ = typing.handle(.escape)
    }
    longKeys.sort()
    print(String(format: "L4 long sentence per keystroke p95: %.2f ms (limit 16), max %.2f ms, n=%d", longKeys[Int(Double(longKeys.count) * 0.95)], longKeys.last!, longKeys.count))
    var perKey: [Double] = []
    for _ in 0..<10 {
        let typing = CompositionSession(decoder: decoder)
        for c in sentence {
            let s = now(); _ = typing.handle(.char(c)); perKey.append(now() - s)
        }
        _ = typing.handle(.escape)
    }
    perKey.sort()
    print(String(format: "X11 mixed sentence per keystroke p95: %.2f ms (limit 16), max %.2f ms, n=%d", perKey[Int(Double(perKey.count) * 0.95)], perKey.last!, perKey.count))
    print(String(format: "M1 latency p95: %.2f ms (limit 10), max input \"%@\" %.2f ms, n=%d", p95, worst.0, worst.1, samples.count))
}

if mode == "session" || mode == "all" {
    let session = CompositionSession(decoder: decoder)
    let scripts: [[Key]] = ["su3cl3ji3", "hrllo", "5k4ek7", "typingspeed", "vu3cj0", "computerr"].map { $0.map(Key.char) }
    var samples: [Double] = []
    for _ in 0..<30 {
        for keys in scripts {
            for key in keys + [.down, .enter] {
                let start = now()
                _ = session.handle(key)
                samples.append(now() - start)
            }
        }
    }
    samples.sort()
    print(String(format: "I17 keystroke p95: %.2f ms (limit 16), n=%d", samples[Int(Double(samples.count) * 0.95)], samples.count))
}

if mode == "decision-smoke" {
    let started = now()
    let clef = try await ClefMini.load()
    print(String(format: "Clef-mini loaded in %.0f ms, resident %.0f MB", now() - started, Double(residentBytes()) / 1_048_576))
    for keys in ["5k4ek7is", "suecl3", "u4", "up ", "5k4ek7go", "vu,4vi,4"] {
        let candidates = Array(decoder.candidates(for: keys, previousLanguage: nil).filter { $0.source != .literal }.prefix(5))
        let s = now()
        let lm = try await clef.languageScores(context: "", texts: candidates.map(\.text))
        let choice = try await clef.choose(context: "", keys: keys, candidates: candidates)
        let row = zip(candidates, lm).map { String(format: "%@(%.1f)", $0.text, $1) }.joined(separator: " ")
        print(String(format: "%@ → %@  [%.0f ms]  %@", keys, choice.map { candidates[$0].text } ?? "-", now() - s, row))
    }
}

if mode == "decision" {
    // Spec 004 D7: top-1 accuracy, engine alone vs engine + Clef-mini, on a labeled corpus.
    let corpusPath = CommandLine.arguments.dropFirst(2).first ?? "Tests/TaipoDecisionTests/Cases/eval-corpus.tsv"
    let rows = try String(contentsOfFile: corpusPath, encoding: .utf8).split(separator: "\n").map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
    let clef = try await ClefMini.load()
    let lambdas = [0.25, 0.5, 1.0, 2.0, 4.0]
    struct Tally { var n = 0, engine = 0, ambiguous = 0, oracle = 0; var model: [Int] }
    var tallies: [String: Tally] = [:]
    var latencies: [Double] = []
    for row in rows where row.count == 3 {
        let (keys, label, cls) = (row[0], row[1], row[2])
        let candidates = Array(decoder.candidates(for: keys, previousLanguage: nil).prefix(DecisionPolicy.maxCandidates))
        var t = tallies[cls] ?? Tally(model: Array(repeating: 0, count: lambdas.count))
        t.n += 1
        let engineRight = candidates.first?.text == label
        if engineRight { t.engine += 1 }
        if candidates.contains(where: { $0.text == label }) { t.oracle += 1 }
        let always = ProcessInfo.processInfo.environment["TAIPO_DECIDE_ALWAYS"] == "1"
        let asks = always
            ? candidates.count >= 2 && candidates[0].source != .partial && candidates[1].source != .literal
            : DecisionPolicy.isAmbiguous(candidates)
        if asks {
            t.ambiguous += 1
            let s = now()
            let lm = try await clef.languageScores(context: "", texts: candidates.map(\.text))
            latencies.append(now() - s)
            for (li, lambda) in lambdas.enumerated() {
                let totals = zip(candidates, lm).map { c, score in
                    c.source == .literal ? -Double.infinity : -Decoder.penalty(c.edits) + lambda * score
                }
                let best = totals.indices.max { totals[$0] < totals[$1] || (totals[$0] == totals[$1] && $0 > $1) }!
                if candidates[best].text == label { t.model[li] += 1 }
            }
        } else if engineRight {
            for li in lambdas.indices { t.model[li] += 1 }
        }
        tallies[cls] = t
    }
    latencies.sort()
    print("class      n   engine  " + lambdas.map { String(format: "λ=%-5.2f", $0) }.joined(separator: " ") + "  ambiguous  in-top5")
    for (cls, t) in tallies.sorted(by: { $0.key < $1.key }) {
        let pct = { (x: Int) in String(format: "%5.1f%%", 100 * Double(x) / Double(t.n)) }
        print("\(cls.padding(toLength: 9, withPad: " ", startingAt: 0)) \(String(format: "%4d", t.n))  \(pct(t.engine))  " + t.model.map(pct).joined(separator: "  ") + "   \(String(format: "%4d", t.ambiguous))     \(pct(t.oracle))")
    }
    if !latencies.isEmpty {
        print(String(format: "D13 decision latency p50 %.0f ms, p95 %.0f ms, n=%d", latencies[latencies.count / 2], latencies[Int(Double(latencies.count) * 0.95)], latencies.count))
    }
    print(String(format: "D14 resident with model: %.0f MB", Double(residentBytes()) / 1_048_576))
}
