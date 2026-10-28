"""Shared CLI, file discovery, timing and JSONL output for the Python ASR runners.

Not a script; imported by the run_*.py runners (their directory is on sys.path).
"""
from __future__ import annotations

import argparse
import json
import time
import wave
from pathlib import Path
from typing import Callable

EVAL_ROOT = Path.home() / "Library" / "Application Support" / "Taipo" / "asr-eval"
MODELS_ROOT = Path.home() / "Library" / "Application Support" / "Taipo" / "models"


def parse_args(description: str,
               extra: Callable[[argparse.ArgumentParser], None] | None = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(description=description)
    p.add_argument("--set", dest="set_name", choices=["real", "synth"], default="real",
                   help="real: recordings in asr-eval/; synth: asr-eval/synth/ (default: real)")
    p.add_argument("--dir", type=Path, help="override the audio directory (results go to <dir>/results)")
    if extra is not None:
        extra(p)
    return p.parse_args()


def set_dir(args: argparse.Namespace) -> Path:
    if args.dir is not None:
        return args.dir.expanduser()
    return EVAL_ROOT / "synth" if args.set_name == "synth" else EVAL_ROOT


def audio_seconds(path: Path) -> float:
    with wave.open(str(path), "rb") as w:
        return w.getnframes() / w.getframerate()


def percentile(values: list[float], q: float) -> float:
    """Linear-interpolated percentile (same as numpy's default)."""
    xs = sorted(values)
    k = (len(xs) - 1) * q / 100
    lo = int(k)
    hi = min(lo + 1, len(xs) - 1)
    return xs[lo] + (xs[hi] - xs[lo]) * (k - lo)


def run(engine: str, args: argparse.Namespace, load: Callable[[], Callable[[Path], str]]) -> Path:
    """Load the model once, warm up, then transcribe every <id>.wav and write results JSONL.

    `load` returns a transcribe(path) -> text function. `seconds` covers only that call.
    """
    directory = set_dir(args)
    wavs = sorted(directory.glob("*.wav"))
    if not wavs:
        raise SystemExit(f"no .wav files in {directory}")

    t0 = time.perf_counter()
    transcribe = load()
    print(f"[{engine}] model load: {time.perf_counter() - t0:.2f}s", flush=True)

    t0 = time.perf_counter()
    transcribe(wavs[0])
    print(f"[{engine}] warm-up decode ({wavs[0].name}): {time.perf_counter() - t0:.2f}s", flush=True)

    out_path = directory / "results" / f"{engine}.jsonl"
    out_path.parent.mkdir(parents=True, exist_ok=True)
    total_s = total_audio = 0.0
    latencies = []
    with out_path.open("w", encoding="utf-8") as out:
        for wav in wavs:
            dur = audio_seconds(wav)
            t0 = time.perf_counter()
            text = transcribe(wav).strip()
            seconds = time.perf_counter() - t0
            total_s += seconds
            latencies.append(seconds)
            total_audio += dur
            row = {"id": wav.stem, "engine": engine, "text": text,
                   "seconds": round(seconds, 4), "audio_seconds": round(dur, 4)}
            out.write(json.dumps(row, ensure_ascii=False) + "\n")
            out.flush()
            print(f"[{engine}] {wav.stem} {seconds:.2f}s / {dur:.2f}s  {text}", flush=True)
    print(f"[{engine}] {len(wavs)} files, mean {total_s / len(wavs):.3f}s, "
          f"p50 {percentile(latencies, 50):.3f}s, p95 {percentile(latencies, 95):.3f}s, "
          f"RTF {total_s / total_audio:.3f} -> {out_path}", flush=True)
    return out_path
