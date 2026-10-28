#!/usr/bin/env python3
"""Labeled corpus for Spec 004 D7: keys<TAB>intended<TAB>class.

Usage: python3 -I scripts/make_eval_corpus.py Sources/TaipoCore/Resources Tests/TaipoDecisionTests/Cases/eval-corpus.tsv
Classes: zh-typo (one adjacent-key slip in a common phrase), zh-en (Chinese + short English
word), mixed (Spec 003 sentences).
"""
import json
import random
import sys
from pathlib import Path

ROWS = ["1234567890-=", "qwertyuiop[]", "asdfghjkl;'", "zxcvbnm,./"]


def adjacency():
    adj = {}
    for r, row in enumerate(ROWS):
        for c, ch in enumerate(row):
            near = {row[c + d] for d in (-1, 1) if 0 <= c + d < len(row)}
            if r > 0:
                near |= {ROWS[r - 1][cc] for cc in (c, c + 1) if cc < len(ROWS[r - 1])}
            if r < 3:
                near |= {ROWS[r + 1][cc] for cc in (c - 1, c) if 0 <= cc < len(ROWS[r + 1])}
            adj[ch] = near
    return adj


def main():
    res, out = Path(sys.argv[1]), Path(sys.argv[2])
    random.seed(4)
    best = {}
    for line in (res / "zh.tsv").read_text(encoding="utf-8").splitlines():
        keys, text, count = line.split("\t")
        if int(count) > best.get(keys, ("", -1))[1]:
            best[keys] = (text, int(count))
    common = sorted(best.items(), key=lambda kv: -kv[1][1])[:2500]
    adj = adjacency()
    rows = set()
    for keys, (text, _) in common:
        if len(text) < 2:
            continue  # single characters are too ambiguous to label
        i = random.randrange(len(keys))
        options = sorted(adj.get(keys[i], ()))
        if options:
            typo = keys[:i] + random.choice(options) + keys[i + 1:]
            if typo not in best:
                rows.add((typo, text, "zh-typo"))
    prefixes = {"5k4ek7": "這個", "ji3g4": "我是", "su3cl3": "你好", "cl3": "好"}
    for word in "is it no on of to in at by my we he me do us an or if as be am go so up".split():
        for keys, text in prefixes.items():
            rows.add((keys + word, f"{text} {word}", "zh-en"))
    mixed = json.loads((Path("Tests/TaipoCoreTests/Cases/mixed-cases.json")).read_text(encoding="utf-8"))
    for row in mixed:
        if "expectTop1" in row and " " in row["expectTop1"]:
            rows.add((row["input"], row["expectTop1"], "mixed"))
    out.write_text("".join(f"{k}\t{t}\t{c}\n" for k, t, c in sorted(rows, key=lambda r: (r[2], r[0]))), encoding="utf-8")
    print(f"{len(rows)} rows")


if __name__ == "__main__":
    main()
