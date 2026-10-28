/// Key geometry of the MacBook ANSI keyboard and the Dachen (大千) Zhuyin layout.
/// Rows start at the key above-left of `q` (`1`), so column c in a row sits
/// between columns c and c+1 of the row above.
public enum Layout {
    static let rows: [[UInt8]] = [
        Array("1234567890-=".utf8),
        Array("qwertyuiop[]".utf8),
        Array("asdfghjkl;'".utf8),
        Array("zxcvbnm,./".utf8),
    ]

    /// Keys physically adjacent (same row left/right, staggered rows above/below).
    static let adjacency: [UInt8: Set<UInt8>] = {
        var map: [UInt8: Set<UInt8>] = [:]
        for (r, row) in rows.enumerated() {
            for (c, key) in row.enumerated() {
                var near = Set<UInt8>()
                for dc in [-1, 1] where row.indices.contains(c + dc) { near.insert(row[c + dc]) }
                if r > 0 { for cc in [c, c + 1] where rows[r - 1].indices.contains(cc) { near.insert(rows[r - 1][cc]) } }
                if r + 1 < rows.count { for cc in [c - 1, c] where rows[r + 1].indices.contains(cc) { near.insert(rows[r + 1][cc]) } }
                map[key] = near
            }
        }
        return map
    }()

    static func isAdjacent(_ a: UInt8, _ b: UInt8) -> Bool { adjacency[a]?.contains(b) ?? false }

    /// The Zhuyin symbol or tone mark printed on a Dachen key (space shows tone 1 as ˉ).
    public static func zhuyinSymbol(for key: Character) -> String? {
        dachenSymbols[key]
    }

    private static let dachenSymbols: [Character: String] = {
        let keys = Array("1qaz2wsxedcrfv5tgbyhnujm8ik,9ol.0p;/-") + [" ", "6", "3", "4", "7"]
        let symbols = Array("ㄅㄆㄇㄈㄉㄊㄋㄌㄍㄎㄏㄐㄑㄒㄓㄔㄕㄖㄗㄘㄙㄧㄨㄩㄚㄛㄜㄝㄞㄟㄠㄡㄢㄣㄤㄥㄦ").map(String.init) + ["ˉ", "ˊ", "ˇ", "ˋ", "˙"]
        return Dictionary(uniqueKeysWithValues: zip(keys, symbols))
    }()

    /// Keys that carry a Zhuyin symbol or tone in the Dachen layout; space is tone 1.
    static let zhuyinKeys = Set("1qaz2wsxedcrfv5tgbyhnujm8ik,9ol.0p;/-6347 ".utf8)
}
