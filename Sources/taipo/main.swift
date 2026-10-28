import Foundation
import TaipoCore

let usage = "usage: taipo explain|query <keys> [--prev zh|en] [--user-dict PATH] | taipo batch < lines"
var args = Array(CommandLine.arguments.dropFirst())
@MainActor func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    defer { args.removeSubrange(i...i + 1) }
    return args[i + 1]
}
let prev = option("--prev").flatMap(Language.init(rawValue:))
let userDict = option("--user-dict").map(URL.init(fileURLWithPath:))
    ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Taipo/user.json")
guard args.count == 2 || args == ["batch"] else { print(usage); exit(2) }
let decoder = try Decoder(lexicon: Lexicon.bundled(), userDictionaryURL: userDict)
for line in decoder.diagnostics { FileHandle.standardError.write(Data("warning: \(line)\n".utf8)) }
switch args[0] {
case "batch":
    // One input per line → "input<TAB>candidate…" (top TAIPO_TOP, default 1; literal excluded).
    while let line = readLine(strippingNewline: true) {
        let top = Int(ProcessInfo.processInfo.environment["TAIPO_TOP"] ?? "1") ?? 1
        let deep = ProcessInfo.processInfo.environment["TAIPO_DEEP"] == "1"
        let texts = decoder.decode(line, previousLanguage: prev, deep: deep).candidates
            .filter { $0.source != .literal }.prefix(top).map(\.text)
        print("\(line)\t" + texts.joined(separator: "\t"))
    }
case "explain": print(decoder.explain(args[1], previousLanguage: prev))
case "query": decoder.candidates(for: args[1], previousLanguage: prev).prefix(9).enumerated().forEach { print("\($0 + 1). \($1.text)") }
default: print(usage); exit(2)
}
