import Foundation
import Testing

// Spec 019: scripts/public-sync.sh and scripts/public_leak_gate.py against fixture git repositories.
// Every fixture sentence, email, key and home path here is made up. Fake keys and home paths are built
// at run time so this file itself passes the leak gate (G19).

let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let syncScript = repoRoot.appendingPathComponent("scripts/public-sync.sh").path
let gateScript = repoRoot.appendingPathComponent("scripts/public_leak_gate.py").path
let noreply = "10594519+unknowntpo@users.noreply.github.com"

/// Made-up corpus. S1 has an 11-letter ASCII run so the K boundary of the fragment rule can be tested.
let fixtureSentences = ["企鵝在 Zorbletonia 圖書館借了三本 cookbook", "河馬喜歡在月亮上烤 marshmallow", "短句測試"]
let fixtureCorpus = fixtureSentences.enumerated().map { "f\($0.offset + 1)\t\($0.element)" }.joined(separator: "\n") + "\n"
let fixturePatterns = "someone@example.com\n"

struct Run {
    let status: Int32
    let out: String
    let err: String
    var all: String { out + err }
}

/// The interpreter for the gate: a uv-managed Python when uv is installed (never the system one), else python3 (CI).
let python: String = {
    if let p = ProcessInfo.processInfo.environment["TAIPO_PYTHON"], !p.isEmpty { return p }
    let candidates = ["/opt/homebrew/bin/uv", "/usr/local/bin/uv", NSHomeDirectory() + "/.local/bin/uv"]
    if let uv = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }),
       let found = try? run(uv, ["python", "find", "--python-preference", "only-managed", "--no-project", ">=3.10"]),
       found.status == 0 {
        return found.out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return "python3"
}()

@discardableResult
func run(_ exe: String, _ args: [String], cwd: URL? = nil, env: [String: String] = [:]) throws -> Run {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = [exe] + args
    if let cwd { p.currentDirectoryURL = cwd }
    var environment = ProcessInfo.processInfo.environment
    environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
    environment["GIT_CONFIG_NOSYSTEM"] = "1"
    environment["GIT_AUTHOR_NAME"] = "Fixture"
    environment["GIT_AUTHOR_EMAIL"] = "fixture@example.com"
    environment["GIT_COMMITTER_NAME"] = "Fixture"
    environment["GIT_COMMITTER_EMAIL"] = "fixture@example.com"
    for (k, v) in env { environment[k] = v }
    p.environment = environment
    let outURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let errURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    FileManager.default.createFile(atPath: outURL.path, contents: nil)
    FileManager.default.createFile(atPath: errURL.path, contents: nil)
    defer { try? FileManager.default.removeItem(at: outURL); try? FileManager.default.removeItem(at: errURL) }
    p.standardOutput = try FileHandle(forWritingTo: outURL)
    p.standardError = try FileHandle(forWritingTo: errURL)
    try p.run()
    p.waitUntilExit()
    return Run(status: p.terminationStatus,
               out: (try? String(contentsOf: outURL, encoding: .utf8)) ?? "",
               err: (try? String(contentsOf: errURL, encoding: .utf8)) ?? "")
}

func git(_ dir: URL, _ args: String...) throws -> String {
    let r = try run("git", ["-C", dir.path] + args)
    guard r.status == 0 else { throw FixtureError(message: "git \(args.joined(separator: " ")): \(r.err)") }
    return r.out.trimmingCharacters(in: .whitespacesAndNewlines)
}

struct FixtureError: Error { let message: String }

func write(_ dir: URL, _ files: [String: String]) throws {
    for (path, text) in files {
        let url = dir.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}

func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("taipo-019-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A bare public repo whose main has one commit (P0, not a sync commit) and a private repo
/// whose first commit carries `Ported-From: unknowntpo/taipo@<P0>`.
struct Fixture {
    let dir: URL
    let priv: URL
    let pub: URL
    let seed: URL
    let p0: String

    static let baseFiles: [String: String] = [
        ".public-exclude": "# fixture\nprivate/\n.public-exclude\n",
        "private/asr-eval/sentences.tsv": fixtureCorpus,
        "private/leak-patterns.txt": fixturePatterns,
        "README.md": "hello\n",
    ]

    init(files: [String: String] = Fixture.baseFiles, omit: [String] = []) throws {
        dir = try tempDir()
        priv = dir.appendingPathComponent("private")
        pub = dir.appendingPathComponent("public.git")
        seed = dir.appendingPathComponent("seed")
        try run("git", ["init", "-q", "--bare", "-b", "main", pub.path])
        try run("git", ["init", "-q", "-b", "main", seed.path])
        try write(seed, ["README.md": "hello\n"])
        _ = try git(seed, "add", "-A")
        try commitAs(seed, noreply, "Initial public release")
        _ = try git(seed, "push", "-q", pub.path, "main")
        p0 = try git(seed, "rev-parse", "HEAD")

        try run("git", ["init", "-q", "-b", "main", priv.path])
        var all = files
        for path in omit { all[path] = nil }
        try write(priv, all)
        _ = try git(priv, "add", "-A")
        _ = try git(priv, "commit", "-q", "-m", "Port the public release\n\nPorted-From: unknowntpo/taipo@\(p0.prefix(7))")
    }

    func commitPrivate(_ files: [String: String], _ message: String) throws {
        try write(priv, files)
        _ = try git(priv, "add", "-A")
        _ = try git(priv, "commit", "-q", "-m", message)
    }

    /// Pushes a commit made directly on the public repo (through the seed clone).
    func commitPublic(_ files: [String: String], _ message: String) throws -> String {
        _ = try git(seed, "pull", "-q", pub.path, "main")
        try write(seed, files)
        _ = try git(seed, "add", "-A")
        try commitAs(seed, noreply, message)
        _ = try git(seed, "push", "-q", pub.path, "main")
        return try git(seed, "rev-parse", "HEAD")
    }

    func publicState() throws -> String {
        try git(pub, "for-each-ref", "--format=%(refname) %(objectname)") + "|" + (try git(pub, "symbolic-ref", "HEAD"))
    }

    func publicHead() throws -> String { try git(pub, "rev-parse", "main") }

    func sync(dryRun: Bool = false, _ extra: [String] = [], env: [String: String] = [:]) throws -> Run {
        var args = [syncScript, "--repo", priv.path, "--public", pub.path]
        if dryRun { args.append("--dry-run") }
        return try run("bash", args + extra, env: ["TAIPO_PYTHON": python].merging(env) { $1 })
    }
}

func commitAs(_ dir: URL, _ email: String, _ message: String) throws {
    let r = try run("git", ["-C", dir.path, "commit", "-q", "-m", message],
                    env: ["GIT_AUTHOR_EMAIL": email, "GIT_COMMITTER_EMAIL": email, "GIT_AUTHOR_NAME": "Eric Chang", "GIT_COMMITTER_NAME": "Eric Chang"])
    guard r.status == 0 else { throw FixtureError(message: r.err) }
}

/// The generated tree directory printed by a dry run (`tree: <dir>`).
func treeDir(_ r: Run) -> URL? {
    r.out.split(separator: "\n").first { $0.hasPrefix("tree: ") }.map { URL(fileURLWithPath: String($0.dropFirst(6))) }
}

func exists(_ dir: URL, _ path: String) -> Bool { FileManager.default.fileExists(atPath: dir.appendingPathComponent(path).path) }

/// Runs the gate directly on a tree directory built from `files` (or `data` for binary files).
func gate(_ files: [String: String], data: [String: Data] = [:], links: [String: String] = [:], meta: String? = nil,
          exclude: String = "private/\n.public-exclude\n",
          corpus: String = fixtureCorpus, patterns: String = fixturePatterns) throws -> Run {
    let dir = try tempDir()
    let tree = dir.appendingPathComponent("tree")
    try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
    try write(tree, files)
    for (path, bytes) in data {
        let url = tree.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url)
    }
    for (path, target) in links {
        let url = tree.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: target)
    }
    try write(dir, ["exclude": exclude, "corpus.tsv": corpus, "patterns.txt": patterns])
    var args = ["-I", gateScript, "--tree", tree.path, "--exclude", dir.appendingPathComponent("exclude").path,
                "--corpus", dir.appendingPathComponent("corpus.tsv").path, "--patterns", dir.appendingPathComponent("patterns.txt").path]
    if let meta {
        try write(dir, ["meta": meta])
        args += ["--meta", dir.appendingPathComponent("meta").path]
    }
    return try run(python, args)
}

func meta(author: String = noreply, committer: String = noreply, message: String = "Sync from private main\n") -> String {
    "tree 0000000000000000000000000000000000000000\nauthor Eric Chang <\(author)> 1761609600 +0000\ncommitter Eric Chang <\(committer)> 1761609600 +0000\n\n\(message)"
}

// MARK: Behavior

@Test("G1: the generated tree drops excluded paths and keeps the rest (dir/ and * glob boundaries)")
func g1Exclusion() throws {
    var files = Fixture.baseFiles
    files[".public-exclude"] = "private/\n.public-exclude\nnotes/*.tmp\n"
    files["private/a.tsv"] = "a\tb\n"
    files["docs/x.md"] = "x\n"
    files["private.md"] = "not the private directory\n"
    files["notes/a.tmp"] = "scratch\n"
    files["notes/sub/b.tmp"] = "* does not cross /\n"
    files["notes/a.tmpx"] = "not *.tmp\n"
    let f = try Fixture(files: files)
    let r = try f.sync(dryRun: true)
    #expect(r.status == 0, "\(r.all)")
    let tree = try #require(treeDir(r))
    #expect(!exists(tree, "private/a.tsv"))
    #expect(!exists(tree, "private"))
    #expect(!exists(tree, ".public-exclude"))
    #expect(!exists(tree, "notes/a.tmp"))
    #expect(exists(tree, "docs/x.md"))      // positive control
    #expect(exists(tree, "private.md"))     // dir/ matches the directory only
    #expect(exists(tree, "notes/sub/b.tmp"))
    #expect(exists(tree, "notes/a.tmpx"))
}

@Test("G2: --dry-run leaves both repos unchanged, keeps the generated tree and lists the changed files")
func g2DryRun() throws {
    let f = try Fixture()
    try f.commitPrivate(["docs/x.md": "x\n"], "Add docs (#12)")
    let publicBefore = try f.publicState()
    let privateBefore = try git(f.priv, "for-each-ref", "--format=%(refname) %(objectname)")
    let r = try f.sync(dryRun: true)
    #expect(r.status == 0, "\(r.all)")
    #expect(try f.publicState() == publicBefore)
    #expect(try git(f.priv, "for-each-ref", "--format=%(refname) %(objectname)") == privateBefore)
    let tree = try #require(treeDir(r))
    #expect(exists(tree, "docs/x.md"))
    #expect(r.out.contains("A\tdocs/x.md"))
}

@Test("G3: a second sync with no new private commit makes no public commit and says already in sync")
func g3Idempotent() throws {
    let f = try Fixture()
    try f.commitPrivate(["docs/x.md": "x\n"], "Add docs")
    let first = try f.sync()
    #expect(first.status == 0, "\(first.all)")
    let head = try f.publicHead()
    let second = try f.sync()
    #expect(second.status == 0, "\(second.all)")
    #expect(second.out.contains("already in sync"))
    #expect(try f.publicHead() == head)
}

@Test("G4: the sync commit sits on the old public head, by noreply, with Synced-From and no #number")
func g4CommitShape() throws {
    let f = try Fixture()
    try f.commitPrivate(["docs/x.md": "x\n"], "Add docs (#12)")
    try run("git", ["-C", f.priv.path, "checkout", "-q", "-b", "topic"])
    try f.commitPrivate(["docs/y.md": "y\n"], "Spec 099: y")
    try run("git", ["-C", f.priv.path, "checkout", "-q", "main"])
    _ = try git(f.priv, "merge", "-q", "--no-ff", "topic", "-m", "Merge pull request #13 from someone/topic\n\nSpec 099: add y for #7")
    let privateHead = try git(f.priv, "rev-parse", "HEAD")
    let r = try f.sync()
    #expect(r.status == 0, "\(r.all)")
    let shape = try git(f.pub, "log", "-1", "--format=%P%n%ae%n%ce", "main").split(separator: "\n").map(String.init)
    #expect(shape == [f.p0, noreply, noreply])
    let message = try git(f.pub, "log", "-1", "--format=%B", "main")
    #expect(message.hasPrefix("Sync from private main\n"))
    #expect(message.contains("- Add docs\n"))
    #expect(message.contains("- Spec 099: add y for\n"))   // merge commit → PR title (third line)
    #expect(message.contains("Synced-From: \(privateHead)"))
    #expect(message.range(of: #"#[0-9]"#, options: .regularExpression) == nil)
    #expect(!message.contains("Merge pull request"))
}

// MARK: Failure and retry

@Test("G8: a full private sentence (other spacing and case) fails as path:line private-sentence without printing it")
func g8FullSentence() throws {
    let f = try Fixture()
    try f.commitPrivate(["docs/s.md": "intro\n企鵝在zorbletonia   圖書館借了三本 COOKBOOK!\n"], "Add s")
    let r = try f.sync(dryRun: true)
    #expect(r.status != 0)
    #expect(r.out.contains("docs/s.md:2 private-sentence"), "\(r.all)")
    for leak in ["Zorbletonia", "zorbletonia", "企鵝", "圖書館", "cookbook"] { #expect(!r.all.contains(leak)) }
    #expect(try f.publicHead() == f.p0)

    let control = try Fixture()
    try control.commitPrivate(["docs/s.md": "intro\n長頸鹿在 Quibbleton 公園跳了兩小時 tango\n"], "Add s")
    let ok = try control.sync(dryRun: true)
    #expect(ok.status == 0, "\(ok.all)")
}

@Test("G9: a 10-character fragment with 2 non-ASCII characters fails; 9 characters, 1 non-ASCII or ASCII-only pass")
func g9Fragment() throws {
    let hit = try gate(["docs/f.md": "note: 鵝在zorbleto\n"])
    #expect(hit.status != 0)
    #expect(hit.out.contains("docs/f.md:1 private-fragment"), "\(hit.all)")
    #expect(!hit.all.contains("zorbleto"))
    for line in ["note: 圖書館借了三本co", "note: 在zorbleton", "note: zorbletoni"] {
        let r = try gate(["docs/f.md": line + "\n"])
        #expect(r.status == 0, "\(line.count) chars: \(r.all)")
    }
}

@Test("G10: the gate fails a tree that still has an excluded path, independently of the generator")
func g10ExcludedPath() throws {
    let r = try gate(["private/x": "anything\n", "docs/ok.md": "ok\n"])
    #expect(r.status != 0)
    #expect(r.out.contains("private/x:0 excluded-path"), "\(r.all)")
    #expect(try gate(["docs/ok.md": "ok\n"]).status == 0)
}

@Test("G11: audio and weight files fail by extension, header or size; a 5 MB text file passes")
func g11Media() throws {
    let limit = 5 * 1024 * 1024
    var riff = Data("RIFF".utf8); riff.append(Data([0x24, 0, 0, 0])); riff.append(Data("WAVEfmt ".utf8))
    var gguf = Data("GGUF".utf8); gguf.append(Data(repeating: 3, count: 12))
    let cases: [(String, Data)] = [
        ("Data/clip.wav", Data("plain text\n".utf8)),
        ("Data/renamed.txt", riff),
        ("Data/model.dat", gguf),
        ("Data/big.txt", Data(repeating: 0x61, count: limit + 1)),
    ]
    for (path, bytes) in cases {
        let r = try gate([:], data: [path: bytes])
        #expect(r.status != 0, "\(path)")
        #expect(r.out.contains("\(path):0 media"), "\(path): \(r.all)")
    }
    let ok = try gate([:], data: ["Data/exact.txt": Data(repeating: 0x61, count: limit)])
    #expect(ok.status == 0, "\(ok.all)")
}

@Test("G12: an absolute home path fails; ~/Library/Application Support/Taipo passes")
func g12HomePath() throws {
    let home = "/Us" + "ers/" + "alice/Projects/taipo"
    let r = try gate(["docs/p.md": "a\nsee \(home)\n"])
    #expect(r.status != 0)
    #expect(r.out.contains("docs/p.md:2 home-path"), "\(r.all)")
    #expect(!r.all.contains("alice"))
    #expect(try gate(["docs/p.md": "see ~/Library/Application Support/Taipo\n"]).status == 0)
}

@Test("G13: a string listed in leak-patterns.txt fails; an unlisted email passes")
func g13Identity() throws {
    let r = try gate(["docs/m.md": "contact Someone@Example.com\n"])
    #expect(r.status != 0)
    #expect(r.out.contains("docs/m.md:1 private-identity"), "\(r.all)")
    #expect(!r.all.lowercased().contains("someone@"))
    #expect(try gate(["docs/m.md": "contact other@example.com\n"]).status == 0)
}

@Test("G14: each key format fails; one character shorter passes")
func g14Keys() throws {
    let x = { (n: Int) in String(repeating: "x", count: n) }
    let keys: [(String, String)] = [
        ("gh" + "p_" + x(36), "gh" + "p_" + x(35)),
        ("gh" + "s_" + x(36), "gh" + "s_" + x(35)),
        ("github" + "_pat_" + x(82), "github" + "_pat_" + x(81)),
        ("h" + "f_" + x(30), "h" + "f_" + x(29)),
        ("AK" + "IA" + String(repeating: "X", count: 16), "AK" + "IA" + String(repeating: "X", count: 15)),
        ("-----BEGIN OPENSSH " + "PRIVATE KEY-----", "-----BEGIN OPENSSH " + "PRIVATE KEY----"),
        ("s" + "k-" + x(20), "s" + "k-" + x(19)),
        ("xo" + "xb-" + x(10), "xo" + "xb-" + x(9)),
    ]
    for (bad, short) in keys {
        let r = try gate(["docs/k.md": "key = \(bad)\n"])
        #expect(r.status != 0, "\(bad.prefix(4))")
        #expect(r.out.contains("docs/k.md:1 secret"), "\(bad.prefix(4)): \(r.all)")
        #expect(!r.all.contains(bad))
        let ok = try gate(["docs/k.md": "key = \(short)\n"])
        #expect(ok.status == 0, "\(short.prefix(4)) short: \(ok.all)")
    }
    #expect(try gate(["docs/k.md": "a desk-organizer-with-long-name\n"]).status == 0)
}

@Test("G15: commit author or committer other than noreply fails; a private sentence in the message fails")
func g15CommitMeta() throws {
    #expect(try gate(["docs/ok.md": "ok\n"], meta: meta()).status == 0)
    let author = try gate(["docs/ok.md": "ok\n"], meta: meta(author: "someone@example.org"))
    #expect(author.status != 0)
    #expect(author.out.contains("commit:0 author"), "\(author.all)")
    let committer = try gate(["docs/ok.md": "ok\n"], meta: meta(committer: "someone@example.org"))
    #expect(committer.status != 0)
    #expect(committer.out.contains("commit:0 committer"), "\(committer.all)")
    let message = try gate(["docs/ok.md": "ok\n"], meta: meta(message: "Sync from private main\n\n- 河馬喜歡在月亮上烤 marshmallow\n"))
    #expect(message.status != 0)
    #expect(message.out.contains("commit:3 private-sentence"), "\(message.all)")
    #expect(!message.all.contains("河馬"))
}

@Test("G16: a missing or empty corpus, missing leak-patterns.txt or missing .public-exclude fails closed")
func g16FailClosed() throws {
    var empty = Fixture.baseFiles
    empty["private/asr-eval/sentences.tsv"] = "\n"
    let fixtures = [
        ("missing corpus", try Fixture(omit: ["private/asr-eval/sentences.tsv"])),
        ("empty corpus", try Fixture(files: empty)),
        ("missing leak-patterns", try Fixture(omit: ["private/leak-patterns.txt"])),
        ("missing .public-exclude", try Fixture(omit: [".public-exclude"])),
    ]
    for (name, f) in fixtures {
        try f.commitPrivate(["docs/x.md": "x\n"], "Add docs")
        let before = try f.publicState()
        let r = try f.sync()
        #expect(r.status != 0, "\(name)")
        #expect(r.all.contains("fail closed"), "\(name): \(r.all)")
        #expect(try f.publicState() == before, "\(name)")
    }
}

@Test("G17: an unported public commit blocks the sync and is listed; after Ported-From the sync fast-forwards")
func g17ForeignCommit() throws {
    let f = try Fixture()
    let foreign = try f.commitPublic(["CONTRIBUTING.md": "be nice\n"], "Add contributing guide")
    let before = try f.publicState()
    let blocked = try f.sync()
    #expect(blocked.status != 0)
    #expect(blocked.all.contains(foreign), "\(blocked.all)")
    #expect(try f.publicState() == before)

    try f.commitPrivate(["CONTRIBUTING.md": "be nice\n", "docs/x.md": "x\n"], "Add contributing guide\n\nPorted-From: unknowntpo/taipo@\(foreign)")
    let r = try f.sync()
    #expect(r.status == 0, "\(r.all)")
    #expect(try git(f.pub, "log", "-1", "--format=%P", "main") == foreign)
}

@Test("G18: when public main moves during a sync the push is rejected without force; a rerun succeeds")
func g18Race() throws {
    let f = try Fixture()
    try f.commitPrivate(["docs/x.md": "x\n"], "Add docs")
    let root = try git(f.priv, "rev-list", "--max-parents=0", "HEAD")
    let racer = f.dir.appendingPathComponent("racer")
    try run("git", ["clone", "-q", f.pub.path, racer.path])
    try write(racer, ["README.md": "hello again\n"])
    _ = try git(racer, "add", "-A")
    try commitAs(racer, noreply, "Sync from private main\n\nSynced-From: \(root)")
    let hook = "git -C '\(racer.path)' push -q origin main"
    let raced = try f.sync(env: ["PUBLIC_SYNC_BEFORE_PUSH": hook])
    #expect(raced.status != 0, "\(raced.all)")
    let racerHead = try git(racer, "rev-parse", "HEAD")
    #expect(try f.publicHead() == racerHead)

    let r = try f.sync()
    #expect(r.status == 0, "\(r.all)")
    #expect(try git(f.pub, "log", "-1", "--format=%P", "main") == racerHead)
}

@Test("G19: the gate passes this repository's own generated public tree")
func g19OwnTree() throws {
    var args = [syncScript, "--repo", repoRoot.path, "--dry-run", "--source", "worktree"]
    // The public copy has no private/ and no .public-exclude: scan it with made-up inputs instead.
    if !exists(repoRoot, ".public-exclude") {
        let dir = try tempDir()
        // Built at run time: the fixture sentences above appear in this file, so they would match it.
        let token = UUID().uuidString
        let corpus = "g1\t企鵝 \(token) 圖書館\n", patterns = "\(token.lowercased())@example.invalid\n"
        try write(dir, ["exclude": "private/\n", "corpus.tsv": corpus, "patterns.txt": patterns])
        args += ["--exclude-file", dir.appendingPathComponent("exclude").path,
                 "--corpus", dir.appendingPathComponent("corpus.tsv").path,
                 "--patterns", dir.appendingPathComponent("patterns.txt").path]
    }
    let r = try run("bash", args, env: ["TAIPO_PYTHON": python])
    #expect(r.status == 0, "\(r.all)")
    #expect(r.out.contains("gate: ok"))
}

// MARK: Follow-up cases (verifier review of bff194f)

@Test("G1: a comment line in .public-exclude is ignored even when it names a real path")
func g1CommentLine() throws {
    var files = Fixture.baseFiles
    files[".public-exclude"] = "#notes.md\n  # docs/\nprivate/\n.public-exclude\n"
    files["#notes.md"] = "kept\n"
    files["docs/x.md"] = "kept\n"
    let f = try Fixture(files: files)
    let r = try f.sync(dryRun: true)
    #expect(r.status == 0, "\(r.all)")
    let tree = try #require(treeDir(r))
    #expect(exists(tree, "#notes.md"))
    #expect(exists(tree, "docs/x.md"))
    #expect(!exists(tree, "private"))   // positive control: the real patterns still apply
    let g = try gate(["#notes.md": "kept\n", "docs/x.md": "kept\n"], exclude: "#notes.md\n  # docs/\nprivate/\n")
    #expect(g.status == 0, "\(g.all)")
}

@Test("G1: dir/ is anchored at the repo root; a nested directory with the same name is kept")
func g1AnchoredDir() throws {
    var files = Fixture.baseFiles
    files["docs/private/x.md"] = "kept\n"
    let f = try Fixture(files: files)
    let r = try f.sync(dryRun: true)
    #expect(r.status == 0, "\(r.all)")
    let tree = try #require(treeDir(r))
    #expect(exists(tree, "docs/private/x.md"))
    #expect(!exists(tree, "private"))
    let g = try gate(["docs/private/x.md": "kept\n"])
    #expect(g.status == 0, "\(g.all)")
    let hit = try gate(["private/x.md": "x\n"])
    #expect(hit.out.contains("private/x.md:0 excluded-path"), "\(hit.all)")
}

@Test("G9: a fragment that is the last window of the line and of the sentence fails")
func g9LastWindow() throws {
    // "三本cookbook" is the last 10-character window of fixture sentence 1 and ends the line.
    let r = try gate(["docs/f.md": "note: 三本cookbook\n"])
    #expect(r.status != 0)
    #expect(r.out.contains("docs/f.md:1 private-fragment"), "\(r.all)")
    #expect(try gate(["docs/f.md": "note: 本cookbook\n"]).status == 0)   // 9 characters
}

@Test("G11: an ftyp header fails; a file inside a directory with a media extension fails")
func g11FtypAndPackage() throws {
    var ftyp = Data([0, 0, 0, 0x18]); ftyp.append(Data("ftypM4A ".utf8)); ftyp.append(Data(repeating: 1, count: 8))
    let header = try gate([:], data: ["Data/clip.dat": ftyp])
    #expect(header.out.contains("Data/clip.dat:0 media"), "\(header.all)")
    let package = try gate(["Models/x.mlpackage/Manifest.json": "{}\n"])
    #expect(package.out.contains("Models/x.mlpackage/Manifest.json:0 media"), "\(package.all)")
    #expect(try gate(["Models/x/Manifest.json": "{}\n"]).status == 0)   // positive control
}

@Test("G14: AKIA right after a letter or digit is not a key")
func g14AkiaBoundary() throws {
    let tail = "AK" + "IA" + String(repeating: "X", count: 16)
    for prefix in ["X", "x", "7"] {
        let r = try gate(["docs/k.md": "id \(prefix)\(tail)\n"])
        #expect(r.status == 0, "\(prefix): \(r.all)")
    }
    #expect(try gate(["docs/k.md": "id=\(tail)\n"]).status != 0)   // positive control
}

/// A finding whose path was redacted: `redacted-<12 hex>:<line> <rule>`.
func redacted(_ r: Run, _ suffix: String) -> String? {
    let re = try! NSRegularExpression(pattern: #"^redacted-[0-9a-f]{12}:"# + NSRegularExpression.escapedPattern(for: suffix) + "$", options: .anchorsMatchLines)
    let ns = r.out as NSString
    return re.firstMatch(in: r.out, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
}

@Test("G22: a private sentence, home path or key in a file path fails as a redacted path; the path is never printed")
func g22PathNames() throws {
    let sentencePath = "docs/企鵝在 Zorbletonia 圖書館借了三本 cookbook.md"
    let home = "/Us" + "ers/" + "alice/"
    let key = "gh" + "p_" + String(repeating: "x", count: 36)
    let cases: [(String, String)] = [
        (sentencePath, "private-sentence"),
        ("docs/n" + "鵝在zorbleto.md", "private-fragment"),
        ("docs" + home + "notes.md", "home-path"),
        ("docs/someone@example.com.md", "private-identity"),
        ("docs/\(key).md", "secret"),
    ]
    for (path, rule) in cases {
        let r = try gate([path: "intro\nsee \(home)x\n"])
        #expect(r.status != 0, "\(rule)")
        #expect(redacted(r, "0 \(rule)") != nil, "\(rule): \(r.all)")
        // Other findings in the same file use the same placeholder, never the raw path.
        let line = try #require(redacted(r, "0 \(rule)")).split(separator: ":").first.map(String.init)
        #expect(r.out.contains("\(line ?? "?"):2 home-path"), "\(rule): \(r.all)")
        for leak in ["Zorbletonia", "zorbleto", "企鵝", "alice", "someone@", key, path] { #expect(!r.all.contains(leak), "\(rule)") }
    }
    // The placeholder is stable across runs.
    let a = try gate([sentencePath: "ok\n"]), b = try gate([sentencePath: "ok\n"])
    #expect(redacted(a, "0 private-sentence") == redacted(b, "0 private-sentence"))
    // An excluded path that also leaks is redacted too.
    let ex = try gate(["private/企鵝在 Zorbletonia 圖書館借了三本 cookbook.md": "x\n"])
    #expect(redacted(ex, "0 excluded-path") != nil, "\(ex.all)")
    #expect(!ex.all.contains("Zorbletonia"))
    // Through the sync script: the changed-file list is not printed when the gate fails.
    let f = try Fixture()
    try f.commitPrivate([sentencePath: "x\n"], "Add notes")
    let s = try f.sync(dryRun: true)
    #expect(s.status != 0)
    #expect(redacted(s, "0 private-sentence") != nil, "\(s.all)")
    #expect(!s.all.contains("Zorbletonia"))
    #expect(try gate(["docs/plain-name.md": "ok\n"]).status == 0)   // positive control
}

@Test("G23: a private sentence in UTF-16 (with or without BOM) or Big5 fails")
func g23Encodings() throws {
    let line = "intro\n河馬喜歡在月亮上烤 marshmallow\n"
    let big5 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue)))
    var bom = Data([0xFF, 0xFE]); bom.append(try #require(line.data(using: .utf16LittleEndian)))
    let cases: [(String, Data)] = [
        ("utf16-bom", bom),
        ("utf16le", try #require(line.data(using: .utf16LittleEndian))),
        ("utf16be", try #require(line.data(using: .utf16BigEndian))),
        ("big5", try #require(line.data(using: big5))),
    ]
    for (name, bytes) in cases {
        let r = try gate([:], data: ["docs/\(name).txt": bytes])
        #expect(r.status != 0, "\(name)")
        #expect(r.out.contains("docs/\(name).txt:2 private-sentence"), "\(name): \(r.all)")
        #expect(!r.all.contains("河馬"))
    }
    let control = try #require("intro\n長頸鹿在 Quibbleton 公園跳了兩小時 tango\n".data(using: big5))
    #expect(try gate([:], data: ["docs/ok.txt": control]).status == 0)
    let key = "AK" + "IA" + String(repeating: "X", count: 16)
    let utf16Key = try #require("id=\(key)\n".data(using: .utf16LittleEndian))
    #expect(try gate([:], data: ["docs/k.txt": utf16Key]).out.contains("docs/k.txt:1 secret"))
}

@Test("G24: a symlink pointing outside the tree fails; an in-tree symlink passes and its target text is scanned")
func g24Symlinks() throws {
    let outside = try gate(["docs/a.md": "a\n"], links: ["docs/up": "../../outside.txt", "docs/abs": "/etc/hosts"])
    #expect(outside.out.contains("docs/up:0 symlink"), "\(outside.all)")
    #expect(outside.out.contains("docs/abs:0 symlink"), "\(outside.all)")
    let dirLink = try gate(["docs/a.md": "a\n"], links: ["docs/dir": "/tmp"])
    #expect(dirLink.out.contains("docs/dir:0 symlink"), "\(dirLink.all)")
    let inside = try gate(["docs/a.md": "a\n"], links: ["docs/b.md": "a.md", "c": "docs"])
    #expect(inside.status == 0, "\(inside.all)")
    let leaky = try gate(["docs/a.md": "a\n"], links: ["docs/l": "企鵝在zorbletonia圖書館借了三本cookbook"])
    #expect(leaky.out.contains("docs/l:1 private-sentence"), "\(leaky.all)")
    #expect(!leaky.all.contains("zorbletonia"))
}

@Test("G25: --source worktree includes untracked files that are not ignored and leaves out ignored ones")
func g25WorktreeSource() throws {
    let f = try Fixture()
    try f.commitPrivate([".gitignore": "build/\n"], "Ignore build")
    try write(f.priv, ["docs/new.md": "untracked\n", "build/out.txt": "ignored\n"])
    let r = try run("bash", [syncScript, "--repo", f.priv.path, "--dry-run", "--source", "worktree"], env: ["TAIPO_PYTHON": python])
    #expect(r.status == 0, "\(r.all)")
    let tree = try #require(treeDir(r))
    #expect(exists(tree, "docs/new.md"))
    #expect(!exists(tree, "build/out.txt"))
    #expect(exists(tree, "README.md"))
    #expect(try git(f.priv, "status", "--porcelain", "--untracked-files=all").contains("?? docs/new.md"))   // the real index is untouched
}

@Test("G21: a dry run writes the changed files and the gate counts to the job summary, without file content")
func g21DryRunSummary() throws {
    let f = try Fixture()
    try f.commitPrivate(["docs/x.md": "quietly unique body text\n"], "Add docs")
    let summaryFile = f.dir.appendingPathComponent("summary.md")
    let r = try f.sync(dryRun: true, env: ["GITHUB_STEP_SUMMARY": summaryFile.path])
    #expect(r.status == 0, "\(r.all)")
    let text = (try? String(contentsOf: summaryFile, encoding: .utf8)) ?? ""
    #expect(text.contains("docs/x.md"), "\(text)")
    #expect(text.contains("| private-sentence | 0 |"), "\(text)")
    #expect(text.lowercased().contains("dry run"), "\(text)")
    #expect(!text.contains("quietly unique body text"))
}
