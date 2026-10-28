import Foundation

// Repository gates (see docs/process/workflow.md):
//   taipo-dev render-test-plan [--check]   render case files into specs; --check fails on drift
//   taipo-dev check-traceability            every untagged acceptance ID has a test or case row

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let marker = try! NSRegularExpression(pattern: #"<!-- test-plan:start (\S+) -->\n[\s\S]*?<!-- test-plan:end -->"#)

@MainActor func specs() throws -> [URL] {
    let dir = root.appendingPathComponent("docs/specs")
    return try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        .filter { !$0.lastPathComponent.hasPrefix("_") }
        .map { $0.appendingPathComponent("spec.md") }
        .filter { FileManager.default.fileExists(atPath: $0.path) }
        .sorted { $0.path < $1.path }
}

@MainActor func caseRows(_ path: String) throws -> [[String: Any]] {
    let data = try Data(contentsOf: root.appendingPathComponent(path))
    return try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
}

@MainActor func display(_ input: String) -> String {
    if input.count > 12, Set(input).count == 1 { return "\(input.first!)×\(input.count)" }
    if input.count > 12, Set(input).count > 1, !input.contains(" ") || input.count > 32 { return input.count > 32 ? "\(input.count) 鍵" : "`\(input)`" }
    return "`\(input.replacingOccurrences(of: " ", with: "␣"))`"
}

@MainActor func expectations(_ row: [String: Any]) -> String {
    var parts: [String] = []
    let top1 = row["expectTop1"] as? String
    let lang = row["expectTop1Language"] as? String
    if let top1 { parts.append("top1 = \(top1)" + (lang.map { " (\($0))" } ?? "")) }
    else if let lang { parts.append("top1 language = \(lang)") }
    for w in row["expectInTop3"] as? [String] ?? [] { parts.append("top3 ∋ \(w)") }
    for w in row["expectAbsent"] as? [String] ?? [] { parts.append("∌ \(w)") }
    for w in row["expectInCandidates"] as? [String] ?? [] { parts.append("∋ \(w)") }
    if let f = row["expectFuzzy"] as? Bool { parts.append("fuzzy = \(f ? "on" : "off")") }
    if let n = row["expectCount"] as? Int { parts.append("count = \(n)") }
    if let l = row["expectNoLanguage"] as? String { parts.append("無 \(l)") }
    return parts.joined(separator: "; ")
}

@MainActor func renderSessionTable(_ rows: [[String: Any]]) -> String {
    var lines = ["| ID | Case | Keys | Expect |", "| --- | --- | --- | --- |"]
    for row in rows {
        var keys = row["keys"] as? String ?? ""
        if let run = keys.range(of: #"a{13,}"#, options: .regularExpression) {
            keys.replaceSubrange(run, with: "a×\(keys[run].count)")
        }
        var parts: [String] = []
        if let m = row["expectMarked"] as? String { parts.append("組字區 = \(m.isEmpty ? "（空）" : m)") }
        if let c = row["expectCommitted"] as? String {
            parts.append("送出 = " + (c.isEmpty ? "（無）" : "`\(c.replacingOccurrences(of: " ", with: "␣"))`"))
        }
        if let consumed = row["expectLastConsumed"] as? Bool { parts.append(consumed ? "最後一鍵被吃掉" : "最後一鍵交給 App") }
        let cells = [row["id"] as? String ?? "?", row["name"] as? String ?? "?", "`\(keys)`", parts.joined(separator: "; ")]
        lines.append("| " + cells.joined(separator: " | ") + " |")
    }
    return lines.joined(separator: "\n")
}

@MainActor func renderTable(_ path: String) throws -> String {
    let rows = try caseRows(path)
    if rows.first?["keys"] != nil { return renderSessionTable(rows) }
    var lines = ["| ID | Case | Input | Prev | Learn first | Expect |", "| --- | --- | --- | --- | --- | --- |"]
    for row in try caseRows(path) {
        let learn = (row["learn"] as? [[String]])?.map { "\($0[0])→\($0[1])" }.joined(separator: ", ") ?? "—"
        let cells = [row["id"] as? String ?? "?", row["name"] as? String ?? "?", display(row["input"] as? String ?? ""),
                     row["previousLanguage"] as? String ?? "—", learn, expectations(row)]
        lines.append("| " + cells.joined(separator: " | ") + " |")
    }
    return lines.joined(separator: "\n")
}

@MainActor func renderTestPlan(check: Bool) throws -> Int32 {
    var drift: [String] = []
    for spec in try specs() {
        let text = try String(contentsOf: spec, encoding: .utf8)
        let ns = text as NSString
        var output = text
        for match in marker.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let path = ns.substring(with: match.range(at: 1))
            let block = "<!-- test-plan:start \(path) -->\n\(try renderTable(path))\n<!-- test-plan:end -->"
            output = (output as NSString).replacingCharacters(in: match.range, with: block)
        }
        guard output != text else { continue }
        if check { drift.append(spec.path) } else { try output.write(to: spec, atomically: true, encoding: .utf8) }
    }
    for path in drift { print("test plan out of date: \(path) (run: swift run taipo-dev render-test-plan)") }
    return drift.isEmpty ? 0 : 1
}

@MainActor func testSources() throws -> String {
    let dir = root.appendingPathComponent("Tests")
    let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?
        .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
    return try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
}

@MainActor func checkTraceability() throws -> Int32 {
    let tests = try testSources()
    let idLine = try NSRegularExpression(pattern: #"^- ([A-Z]\d+)[:：](.*)$"#, options: .anchorsMatchLines)
    var missing: [String] = []
    var checked = 0
    for spec in try specs() {
        let text = try String(contentsOf: spec, encoding: .utf8)
        guard text.contains("Traceability: enforced"),
              let acceptance = text.range(of: "## Acceptance") else { continue }
        let section = String(text[acceptance.upperBound...])
        let body = section.components(separatedBy: "\n## ").first ?? section
        let ns = text as NSString
        var caseIDs = Set<String>()
        for match in marker.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            for row in try caseRows(ns.substring(with: match.range(at: 1))) { if let id = row["id"] as? String { caseIDs.insert(id) } }
        }
        let bns = body as NSString
        for match in idLine.matches(in: body, range: NSRange(location: 0, length: bns.length)) {
            let id = bns.substring(with: match.range(at: 1))
            let rest = bns.substring(with: match.range(at: 2))
            if ["[measure]", "[deploy]", "[manual]"].contains(where: rest.contains) { continue }
            checked += 1
            if caseIDs.contains(id) || tests.contains("\"\(id):") { continue }
            missing.append("\(spec.deletingLastPathComponent().lastPathComponent) \(id)")
        }
    }
    for item in missing { print("no test or case row for acceptance ID: \(item)") }
    if checked == 0 { print("no acceptance IDs found in enforced specs"); return 1 }
    if missing.isEmpty { print("traceability ok: \(checked) IDs") }
    return missing.isEmpty ? 0 : 1
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "render-test-plan": exit(try renderTestPlan(check: args.contains("--check")))
case "check-traceability": exit(try checkTraceability())
default:
    print("usage: taipo-dev render-test-plan [--check] | check-traceability")
    exit(2)
}
