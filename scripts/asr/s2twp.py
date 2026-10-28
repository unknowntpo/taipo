# /// script
# requires-python = ">=3.10"
# dependencies = ["opencc==1.4.2"]
# ///
"""OpenCC s2twp filter: Simplified -> Traditional (Taiwan, with phrases).

Reads UTF-8 lines from stdin and writes converted lines to stdout, line for line.
Usage: printf '这个软件\n' | uv run scripts/asr/s2twp.py
"""
import sys

import opencc


def main() -> None:
    converter = opencc.OpenCC("s2twp")
    stdin = open(sys.stdin.fileno(), encoding="utf-8", newline="")
    stdout = open(sys.stdout.fileno(), "w", encoding="utf-8", newline="")
    for line in stdin:
        body = line.rstrip("\r\n")
        stdout.write(converter.convert(body) + line[len(body):])
    stdout.flush()


if __name__ == "__main__":
    main()
