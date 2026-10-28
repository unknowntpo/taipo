#!/usr/bin/env python3
"""Build TaipoCore lexicons from McBopomofo and SCOWL source data.

Usage: python3 -I scripts/build_lexicon.py Data/raw Sources/TaipoCore/Resources

Outputs (sorted, tab separated):
  zh.tsv  keys<TAB>phrase<TAB>count   keys are Dachen (大千) key strokes; tone 1 is a space.
  en.tsv  word<TAB>size               SCOWL size (35 = most common).
"""
import math
import re
import sys
from pathlib import Path

DACHEN = {
    "ㄅ": "1", "ㄆ": "q", "ㄇ": "a", "ㄈ": "z", "ㄉ": "2", "ㄊ": "w", "ㄋ": "s", "ㄌ": "x",
    "ㄍ": "e", "ㄎ": "d", "ㄏ": "c", "ㄐ": "r", "ㄑ": "f", "ㄒ": "v", "ㄓ": "5", "ㄔ": "t",
    "ㄕ": "g", "ㄖ": "b", "ㄗ": "y", "ㄘ": "h", "ㄙ": "n", "ㄧ": "u", "ㄨ": "j", "ㄩ": "m",
    "ㄚ": "8", "ㄛ": "i", "ㄜ": "k", "ㄝ": ",", "ㄞ": "9", "ㄟ": "o", "ㄠ": "l", "ㄡ": ".",
    "ㄢ": "0", "ㄣ": "p", "ㄤ": ";", "ㄥ": "/", "ㄦ": "-",
}
TONES = {"ˊ": "6", "ˇ": "3", "ˋ": "4", "˙": "7"}
EN_MAX_SIZE = 60


def syllable_keys(syllable):
    keys, tone = [], " "
    for ch in syllable:
        if ch in TONES:
            tone = TONES[ch]
        elif ch in DACHEN:
            keys.append(DACHEN[ch])
        else:
            return None
    return "".join(keys) + tone if keys else None


def reading_keys(readings):
    parts = [syllable_keys(s) for s in readings]
    return None if any(p is None for p in parts) else "".join(parts)


def build_zh(raw):
    occ = {}
    for line in (raw / "phrase.occ").read_text(encoding="utf-8").splitlines():
        parts = line.split()
        if len(parts) == 2:
            occ[parts[0]] = int(parts[1])
    rows = set()
    for line in (raw / "BPMFBase.txt").read_text(encoding="utf-8").splitlines():
        parts = line.split()
        if len(parts) < 5:
            continue
        char, reading, category = parts[0], parts[1], parts[-1]
        count = occ.get(char, 0)
        if category not in ("big5", "big5e") and count == 0:
            continue
        keys = reading_keys([reading])
        if keys:
            rows.add((keys, char, count))
    for line in (raw / "BPMFMappings.txt").read_text(encoding="utf-8").splitlines():
        parts = line.split()
        if len(parts) < 3:
            continue
        phrase, readings = parts[0], parts[1:]
        count = occ.get(phrase, 0)
        if count == 0 or len(readings) != len(phrase):
            continue
        keys = reading_keys(readings)
        if keys:
            rows.add((keys, phrase, count))
    return sorted(rows)


def inflections(word, pos):
    forms = set()
    if "v" in pos:
        if word.endswith("e") and not word.endswith("ee"):
            stem = word[:-1]
            forms |= {word + "s", stem + "ed", stem + "ing"}
        elif re.fullmatch(r"[^aeiou]*[aeiou][^aeiouwxy]", word):
            forms |= {word + "s", word + word[-1] + "ed", word + word[-1] + "ing"}
        elif re.search(r"[^aeiou]y$", word):
            forms |= {word[:-1] + "ies", word[:-1] + "ied", word + "ing"}
        elif re.search(r"(s|x|z|ch|sh)$", word):
            forms |= {word + "es", word + "ed", word + "ing"}
        else:
            forms |= {word + "s", word + "ed", word + "ing"}
    if "n" in pos:
        if re.search(r"(s|x|z|ch|sh)$", word):
            forms.add(word + "es")
        elif re.search(r"[^aeiou]y$", word):
            forms.add(word[:-1] + "ies")
        else:
            forms.add(word + "s")
    return forms


def build_en(raw):
    best = {}
    for line in (raw / "scowl-pre.txt").read_text(encoding="utf-8").splitlines():
        if ": " not in line:
            continue
        head, _, rest = line.partition(": ")
        sizes = [int(t) for t in head.split() if t.isdigit()]
        if not sizes or min(sizes) > EN_MAX_SIZE:
            continue
        size = min(sizes)
        m = re.match(r"([a-z]+)(?: <([^>]*)>)?(?:: (.*))?", rest.split(" #")[0].strip())
        if not m or m.end() != len(rest.split(" #")[0].strip()):
            continue
        word, pos = m.group(1), m.group(2) or ""
        listed = set(re.findall(r"[a-z]+", m.group(3) or ""))
        derived_size = min(size + 5, EN_MAX_SIZE)
        for form, s in [(word, size)] + [(f, derived_size) for f in inflections(word, pos) | listed]:
            if best.get(form, math.inf) > s:
                best[form] = s
    return sorted(best.items())


def main():
    raw, out = Path(sys.argv[1]), Path(sys.argv[2])
    out.mkdir(parents=True, exist_ok=True)
    zh = build_zh(raw)
    with open(out / "zh.tsv", "w", encoding="utf-8") as f:
        for keys, phrase, count in zh:
            f.write(f"{keys}\t{phrase}\t{count}\n")
    en = build_en(raw)
    with open(out / "en.tsv", "w", encoding="utf-8") as f:
        for word, size in en:
            f.write(f"{word}\t{size}\n")
    print(f"zh rows: {len(zh)}  en rows: {len(en)}")


if __name__ == "__main__":
    main()
