# /// script
# requires-python = ">=3.10"
# dependencies = ["mlx-qwen3-asr==0.4.4"]
# ///
"""Transcribe <id>.wav files with Qwen3-ASR-0.6B (MLX, 4-bit) -> results/qwen3-0.6b.jsonl.

Package: mlx-qwen3-asr (github.com/moona3k/mlx-qwen3-asr), a native MLX reimplementation.
Model: moona3k/mlx-qwen3-asr-0.6b-4bit (4-bit decoder, 8-bit encoder, ~540 MB).
Language is forced to Chinese so dense code-switching is transcribed, not translated.

Usage: uv run scripts/asr/run_qwen.py [--set synth|real] [--dir DIR]
"""
from pathlib import Path

from _common import parse_args, run

MODEL = "moona3k/mlx-qwen3-asr-0.6b-4bit"
ENGINE = "qwen3-0.6b"


def load():
    from mlx_qwen3_asr import Session

    session = Session(model=MODEL)

    def transcribe(path: Path) -> str:
        return session.transcribe(str(path), language="Chinese").text

    return transcribe


if __name__ == "__main__":
    run(ENGINE, parse_args(__doc__.splitlines()[0]), load)
