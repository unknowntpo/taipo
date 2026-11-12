#!/usr/bin/env python3
"""Spec 019 leak gate: scan a generated public tree (and a commit) for private data.

Usage:
  public_leak_gate.py --tree DIR --exclude FILE --corpus FILE --patterns FILE [--meta FILE] [--summary FILE]

Findings go to stdout as `path:line rule` (line 0 = the whole file; `commit` = the commit
in --meta). Matched text is never printed. File paths go through the text rules too; when a
path leaks, every finding for that file prints `redacted-<12 hex of sha256(path)>` instead of
the path. Files that are not valid UTF-8 are also decoded as UTF-16 (LE and BE) and Big5
(cp950), and every decoding is scanned. A symlink fails when its target is absolute or leaves
the tree; otherwise its target text is scanned like file text (the target file is scanned as
its own file). Exit 0 = clean, 1 = findings, 2 = missing input.
Standard library only. Python 3.10+.
"""
import argparse
import hashlib
import os
import re
import sys

NOREPLY = "10594519+unknowntpo@users.noreply.github.com"
SIZE_LIMIT = 5 * 1024 * 1024  # 5 MB; the largest public file (zh.tsv) is 2.3 MB
FRAGMENT_LEN = 10  # Example: N=10, K=2 caught all 6 private files with 0 public false positives
FRAGMENT_MIN_NON_ASCII = 2
MEDIA_EXT = set(
    "wav m4a flac caf mp3 aac ogg opus bin gguf ggml safetensors onnx pt pth npz mlmodel mlpackage profraw".split()
)
HOME_PATH = re.compile(r"/Users/[A-Za-z0-9._-]+/")
SECRETS = [
    re.compile(r"(?<![A-Za-z0-9])gh[pousr]_[A-Za-z0-9]{36}"),
    re.compile(r"github_pat_[A-Za-z0-9_]{82}"),
    re.compile(r"(?<![A-Za-z0-9])hf_[A-Za-z0-9]{30,}"),
    re.compile(r"(?<![A-Za-z0-9])AKIA[0-9A-Z]{16}"),
    re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"),
    re.compile(r"(?<![A-Za-z0-9])sk-[A-Za-z0-9_-]{20,}"),
    re.compile(r"(?<![A-Za-z0-9])xox[abp]-[A-Za-z0-9-]{10,}"),
]
RULES = [
    "excluded-path", "private-sentence", "private-fragment", "media", "home-path",
    "private-identity", "secret", "symlink", "author", "committer",
]
ALT_ENCODINGS = ("utf-16-le", "utf-16-be", "cp950")


class MissingInput(Exception):
    pass


def read_nonempty_lines(path, what):
    if not os.path.isfile(path):
        raise MissingInput(f"{what} not found")
    with open(path, encoding="utf-8") as f:
        lines = [l.strip() for l in f.read().splitlines()]
    lines = [l for l in lines if l and not l.startswith("#")]
    if not lines:
        raise MissingInput(f"{what} is empty")
    return lines


def normalize(text):
    return "".join(text.split()).lower()


def load_corpus(path):
    """Return (full sentences, fragment windows), both normalized."""
    sentences = []
    for line in read_nonempty_lines(path, "corpus"):
        text = line.split("\t", 1)[1] if "\t" in line else line
        text = normalize(text)
        if text:
            sentences.append(text)
    if not sentences:
        raise MissingInput("corpus is empty")
    windows = set()
    for s in sentences:
        if len(s) < FRAGMENT_LEN:
            windows.add(s)
            continue
        for i in range(len(s) - FRAGMENT_LEN + 1):
            w = s[i:i + FRAGMENT_LEN]
            if sum(1 for c in w if ord(c) > 127) >= FRAGMENT_MIN_NON_ASCII:
                windows.add(w)
    return sentences, windows


def exclude_regex(pattern):
    """Patterns are anchored at the repo root. `dir/` = everything under dir; `*` and `?` never cross `/`."""
    pattern = pattern.lstrip("/")
    if pattern.endswith("/"):
        return re.compile(re.escape(pattern) + ".*")
    out = ""
    i = 0
    while i < len(pattern):
        if pattern.startswith("**", i):
            out += ".*"
            i += 2
        elif pattern[i] == "*":
            out += "[^/]*"
            i += 1
        elif pattern[i] == "?":
            out += "[^/]"
            i += 1
        else:
            out += re.escape(pattern[i])
            i += 1
    return re.compile(out)


class Gate:
    def __init__(self, sentences, windows, identities):
        self.sentences = sentences
        self.windows = windows
        self.short = [w for w in windows if len(w) < FRAGMENT_LEN]
        self.identities = [i.lower() for i in identities]
        self.findings = []
        self.counts = {r: 0 for r in RULES}

    def hit(self, where, line, rule):
        finding = f"{where}:{line} {rule}"
        if finding in self.findings:  # the same line found again in another decoding
            return
        self.findings.append(finding)
        self.counts[rule] += 1

    def text_rules(self, where, text, rules=("sentence", "home", "identity", "secret")):
        for n, line in enumerate(text.splitlines(), 1):
            rule = self.line_rule(line, rules)
            if rule:
                self.hit(where, n, rule)

    def path_name(self, rel):
        """The name to print for a file: the path itself, or a placeholder when the path leaks."""
        rule = self.line_rule(rel, ("sentence", "home", "identity", "secret"))
        if not rule:
            return rel
        where = "redacted-" + hashlib.sha256(rel.encode("utf-8")).hexdigest()[:12]
        self.hit(where, 0, rule)
        return where

    def line_rule(self, line, rules):
        if "sentence" in rules:
            norm = normalize(line)
            if any(s in norm for s in self.sentences):
                return "private-sentence"
            if any(norm[i:i + FRAGMENT_LEN] in self.windows for i in range(len(norm) - FRAGMENT_LEN + 1)) or any(
                w in norm for w in self.short
            ):
                return "private-fragment"
        if "home" in rules and HOME_PATH.search(line):
            return "home-path"
        if "identity" in rules:
            low = line.lower()
            if any(i in low for i in self.identities):
                return "private-identity"
        if "secret" in rules and any(p.search(line) for p in SECRETS):
            return "secret"
        return None


def is_media(rel, path, size):
    parts = rel.split("/")
    if any(p.rsplit(".", 1)[-1].lower() in MEDIA_EXT for p in parts if "." in p):
        return True
    if size > SIZE_LIMIT:
        return True
    with open(path, "rb") as f:
        head = f.read(12)
    return (head[:4] == b"RIFF" and head[8:12] == b"WAVE") or head[:4] == b"GGUF" or head[4:8] == b"ftyp"


def decodings(data):
    """UTF-8, plus UTF-16 and Big5 when the bytes are not clean UTF-8 text (invalid bytes or NULs)."""
    text = data.decode("utf-8", errors="replace")
    out = [text]
    if "\ufffd" in text or "\x00" in text:
        out += [data.decode(enc, errors="replace") for enc in ALT_ENCODINGS]
    return out


def link_leaves_tree(tree, path, target):
    if os.path.isabs(target):
        return True
    root = os.path.realpath(tree)
    resolved = os.path.realpath(os.path.join(os.path.dirname(path), target))
    return os.path.commonpath([root, resolved]) != root


def scan_tree(gate, tree, excludes):
    for dirpath, dirnames, filenames in os.walk(tree):
        # os.walk lists a symlink to a directory under dirnames and does not follow it.
        links = sorted(d for d in dirnames if os.path.islink(os.path.join(dirpath, d)))
        dirnames[:] = sorted(d for d in dirnames if d not in links)
        for name in sorted(filenames + links):
            path = os.path.join(dirpath, name)
            rel = os.path.relpath(path, tree).replace(os.sep, "/")
            where = gate.path_name(rel)
            if any(r.fullmatch(rel) for r in excludes):
                gate.hit(where, 0, "excluded-path")
                continue
            if os.path.islink(path):
                target = os.readlink(path)
                if link_leaves_tree(tree, path, target):
                    gate.hit(where, 0, "symlink")
                gate.text_rules(where, target)
                continue
            if is_media(rel, path, os.path.getsize(path)):
                gate.hit(where, 0, "media")
                continue
            with open(path, "rb") as f:
                data = f.read()
            for text in decodings(data):
                gate.text_rules(where, text)


def scan_meta(gate, path):
    with open(path, encoding="utf-8", errors="replace") as f:
        raw = f.read()
    header, _, message = raw.partition("\n\n")
    for line in header.splitlines():
        for field in ("author", "committer"):
            if line.startswith(field + " "):
                m = re.search(r"<([^>]*)>", line)
                if not m or m.group(1) != NOREPLY:
                    gate.hit("commit", 0, field)
    gate.text_rules("commit", message)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tree", required=True)
    ap.add_argument("--exclude", required=True)
    ap.add_argument("--corpus", required=True)
    ap.add_argument("--patterns", required=True)
    ap.add_argument("--meta")
    ap.add_argument("--summary", help="append per-rule counts here (markdown)")
    args = ap.parse_args()
    try:
        excludes = [exclude_regex(p) for p in read_nonempty_lines(args.exclude, "exclude list")]
        sentences, windows = load_corpus(args.corpus)
        identities = read_nonempty_lines(args.patterns, "leak patterns")
        if not os.path.isdir(args.tree):
            raise MissingInput("tree not found")
    except MissingInput as e:
        print(f"leak gate: {e}; fail closed", file=sys.stderr)
        return 2
    gate = Gate(sentences, windows, identities)
    scan_tree(gate, args.tree, excludes)
    if args.meta:
        scan_meta(gate, args.meta)
    for f in gate.findings:
        print(f)
    counts = " ".join(f"{r}={n}" for r, n in gate.counts.items())
    print(f"leak gate: {len(gate.findings)} findings ({counts})", file=sys.stderr)
    if args.summary:
        with open(args.summary, "a", encoding="utf-8") as f:
            f.write("| Gate rule | Hits |\n| --- | --- |\n")
            f.writelines(f"| {r} | {n} |\n" for r, n in gate.counts.items())
            f.writelines(f"- `{x}`\n" for x in gate.findings)
    return 1 if gate.findings else 0


if __name__ == "__main__":
    sys.exit(main())
