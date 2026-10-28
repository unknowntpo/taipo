struct Entry: Sendable {
    let text: String
    let logp: Float
}

/// Byte trie in first-child / next-sibling form to keep ~10^5 keys compact.
/// Rows must be inserted grouped by key so each node's entries are contiguous.
struct Trie: Sendable {
    private(set) var label: [UInt8] = [0]
    private(set) var firstChild: [Int32] = [-1]
    private(set) var nextSibling: [Int32] = [-1]
    private(set) var entryStart: [Int32] = [0]
    private(set) var entryCount: [Int32] = [0]
    private(set) var entries: [Entry] = []

    static let root: Int32 = 0

    private var lastKey: [UInt8]? = nil
    private var lastNode: Int32 = 0

    init() {}

    init(rows: [(key: [UInt8], entry: Entry)]) {
        for row in rows.sorted(by: { $0.key.lexicographicallyPrecedes($1.key) }) {
            _ = append(key: row.key, entry: row.entry)
        }
        finish()
    }

    /// Appends one row; rows sharing a key must arrive consecutively, otherwise
    /// returns false and adds nothing. Call `finish()` after the last row.
    mutating func append<K: Collection<UInt8>>(key: K, entry: Entry) -> Bool {
        if lastKey.map({ !$0.elementsEqual(key) }) ?? true {
            let node = insertPath(key)
            guard entryCount[Int(node)] == 0 else { return false }
            lastNode = node
            entryStart[Int(lastNode)] = Int32(entries.count)
            lastKey = Array(key)
        }
        entries.append(entry)
        entryCount[Int(lastNode)] += 1
        return true
    }

    /// Orders each node's entries best first and drops build state.
    /// `logpOffset` is added to every entry, e.g. to normalise raw log-counts.
    mutating func finish(logpOffset: Float = 0) {
        lastKey = nil
        if logpOffset != 0 {
            entries = entries.map { Entry(text: $0.text, logp: $0.logp + logpOffset) }
        }
        for node in 0..<label.count where entryCount[node] > 1 {
            let range = Int(entryStart[node])..<Int(entryStart[node] + entryCount[node])
            entries[range].sort { $0.logp > $1.logp }
        }
    }

    private mutating func insertPath<K: Collection<UInt8>>(_ key: K) -> Int32 {
        var node = Trie.root
        for byte in key {
            if let next = child(of: node, byte) {
                node = next
            } else {
                let new = Int32(label.count)
                label.append(byte)
                firstChild.append(-1)
                nextSibling.append(firstChild[Int(node)])
                entryStart.append(0)
                entryCount.append(0)
                firstChild[Int(node)] = new
                node = new
            }
        }
        return node
    }

    func child(of node: Int32, _ byte: UInt8) -> Int32? {
        var c = firstChild[Int(node)]
        while c >= 0 {
            if label[Int(c)] == byte { return c }
            c = nextSibling[Int(c)]
        }
        return nil
    }

    func forEachChild(of node: Int32, _ body: (Int32, UInt8) -> Void) {
        var c = firstChild[Int(node)]
        while c >= 0 {
            body(c, label[Int(c)])
            c = nextSibling[Int(c)]
        }
    }

    func entries(at node: Int32) -> ArraySlice<Entry> {
        let start = Int(entryStart[Int(node)])
        return entries[start..<start + Int(entryCount[Int(node)])]
    }

    func hasEntries(_ node: Int32) -> Bool { entryCount[Int(node)] > 0 }

    /// Node reached by exactly `key`, if any.
    func node(for key: some Sequence<UInt8>) -> Int32? {
        var node = Trie.root
        for byte in key {
            guard let next = child(of: node, byte) else { return nil }
            node = next
        }
        return node
    }
}
