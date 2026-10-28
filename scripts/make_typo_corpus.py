#!/usr/bin/env python3
"""Multi-typo recall corpus: keys<TAB>intended<TAB>typos<TAB>length.

Usage: python3 -I scripts/make_typo_corpus.py Sources/TaipoCore/Resources out.tsv
For common multi-character phrases (and two-phrase combinations) apply k = 1..3 random
slips: adjacent-key substitution, neighbour transposition, extra key (adjacent or doubled),
missing key. The intended text is the phrase before the slips.
"""
import random
import sys
from pathlib import Path

ROWS = ["1234567890-=", "qwertyuiop[]", "asdfghjkl;'", "zxcvbnm,./"]
LAYOUT = set("1qaz2wsxedcrfv5tgbyhnujm8ik,9ol.0p;/-6347 ")


def adjacency():
    adj = {}
    for r, row in enumerate(ROWS):
        for c, ch in enumerate(row):
            near = {row[c + d] for d in (-1, 1) if 0 <= c + d < len(row)}
            if r > 0:
                near |= {ROWS[r - 1][cc] for cc in (c, c + 1) if cc < len(ROWS[r - 1])}
            if r < 3:
                near |= {ROWS[r + 1][cc] for cc in (c - 1, c) if 0 <= cc < len(ROWS[r + 1])}
            adj[ch] = sorted(n for n in near if n in LAYOUT)
    return adj


def slip(keys, adj, rng):
    k = list(keys)
    kind = rng.choice(["sub", "swap", "extra", "missing"])
    i = rng.randrange(len(k))
    if kind == "sub" and adj.get(k[i]):
        k[i] = rng.choice(adj[k[i]])
    elif kind == "swap" and i + 1 < len(k) and k[i] != k[i + 1]:
        k[i], k[i + 1] = k[i + 1], k[i]
    elif kind == "extra":
        k.insert(i, rng.choice(adj.get(k[i]) or [k[i]]) if rng.random() < 0.5 else k[i])
    elif kind == "missing" and len(k) > 2:
        del k[i]
    else:
        return None
    return "".join(k)


def main():
    res, out = Path(sys.argv[1]), Path(sys.argv[2])
    rng = random.Random(11)
    best = {}
    for line in (res / "zh.tsv").read_text(encoding="utf-8").splitlines():
        keys, text, count = line.split("\t")
        if len(text) >= 2 and int(count) > best.get(keys, ("", -1))[1]:
            best[keys] = (text, int(count))
    common = [(k, t) for k, (t, _) in sorted(best.items(), key=lambda kv: -kv[1][1])[:3000]]
    sources = [(k, t, "phrase") for k, t in rng.sample(common, 400)]
    sources += [(a[0] + b[0], a[1] + b[1], "two-phrases") for a, b in (rng.sample(common, 2) for _ in range(200))]
    adj = adjacency()
    rows = []
    for keys, text, length in sources:
        for typos in (1, 2, 3):
            typed, ok = keys, True
            for _ in range(typos):
                typed = slip(typed, adj, rng) if typed else None
                if typed is None:
                    ok = False
                    break
            if ok and typed != keys and typed not in best:
                rows.append((typed, text, typos, length))
    out.write_text("".join(f"{k}\t{t}\t{n}\t{l}\n" for k, t, n, l in rows), encoding="utf-8")
    print(f"{len(rows)} rows")


if __name__ == "__main__":
    main()
