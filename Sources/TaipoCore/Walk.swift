/// One correction applied to the typed keys. Positions index the typed input.
public enum Edit: Sendable, Equatable, CustomStringConvertible {
    case substitute(at: Int, typed: Character, intended: Character)
    case transpose(at: Int)
    case extra(at: Int, typed: Character)
    case missing(at: Int, intended: Character)

    /// Index in the typed input the edit applies to.
    public var position: Int {
        switch self {
        case let .substitute(at, _, _), let .transpose(at), let .extra(at, _), let .missing(at, _): at
        }
    }

    public var description: String {
        switch self {
        case let .substitute(at, typed, intended): "substitute \(typed)→\(intended) at \(at)"
        case let .transpose(at): "transpose at \(at)"
        case let .extra(at, typed): "extra \(typed) at \(at)"
        case let .missing(at, intended): "missing \(intended) at \(at)"
        }
    }
}

struct Match {
    let end: Int
    let node: Int32
    let edits: [Edit]
}

/// Bounded edit-distance walk over a trie, starting at `start` in `input`.
/// Substitutions are allowed only between physically adjacent keys.
/// `maxMissing` caps the "missing key" edits, the only kind that branches over every child
/// of a node; Spec 006's retry pass allows one more edit but keeps this at 1.
func fuzzyMatches(in trie: Trie, input: [UInt8], start: Int, maxEdits: Int, requireEnd: Bool,
                  maxMissing: Int = .max) -> [Match] {
    var best: [Int64: Match] = [:]
    var edits: [Edit] = []
    var missing = 0
    edits.reserveCapacity(maxEdits)
    func ch(_ b: UInt8) -> Character { Character(Unicode.Scalar(b)) }

    func visit(_ node: Int32, _ pos: Int) {
        if node != Trie.root, trie.hasEntries(node), !requireEnd || pos == input.count {
            let key = Int64(node) << 8 | Int64(pos)
            if best[key].map({ $0.edits.count > edits.count }) ?? true {
                best[key] = Match(end: pos, node: node, edits: edits)
            }
        }
        if pos < input.count, let next = trie.child(of: node, input[pos]) {
            visit(next, pos + 1)
        }
        guard edits.count < maxEdits else { return }
        func with(_ edit: Edit, _ body: () -> Void) {
            edits.append(edit)
            body()
            edits.removeLast()
        }
        if pos < input.count {
            let typed = input[pos]
            trie.forEachChild(of: node) { child, label in
                if Layout.isAdjacent(typed, label) {
                    with(.substitute(at: pos, typed: ch(typed), intended: ch(label))) { visit(child, pos + 1) }
                }
            }
            with(.extra(at: pos, typed: ch(typed))) { visit(node, pos + 1) }
            if pos + 1 < input.count, input[pos] != input[pos + 1],
               let a = trie.child(of: node, input[pos + 1]), let b = trie.child(of: a, input[pos]) {
                with(.transpose(at: pos)) { visit(b, pos + 2) }
            }
        }
        guard missing < maxMissing else { return }
        missing += 1
        trie.forEachChild(of: node) { child, label in
            with(.missing(at: pos, intended: ch(label))) { visit(child, pos) }
        }
        missing -= 1
    }

    visit(Trie.root, start)
    // Dictionary order varies per process; callers rely on a deterministic order.
    return best.values.sorted { ($0.end, $0.node) < ($1.end, $1.node) }
}
