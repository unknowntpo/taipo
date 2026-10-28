# /// script
# requires-python = ">=3.10"
# dependencies = ["mlx-whisper==0.4.3", "mlx==0.32.4"]
# ///
"""Transcribe <id>.wav files with MediaTek Breeze-ASR-25 (MLX, 5-bit) -> results/breeze.jsonl.

Route: mlx-whisper 0.4.3 decoding with MarkChen1214/Breeze-ASR-25-MLX-5bit
(uniform 5-bit, group 64, ~1.07 GB; BF16 MLX base is 3.08 GB).
That repo ships its own runtime module (mlx_whisper_mixed.py); we do not download
or execute it. Its weights use mlx-whisper's tensor names, but stock
mlx_whisper.load_models cannot read its config (extra `quantization_config`,
per-module quantization map, `model.safetensors` filename), so load_model() below
builds the stock mlx_whisper Whisper model and quantizes it from that map.
Decoding is stock mlx_whisper.transcribe with language="zh"; WAVs are read with
the stdlib (no ffmpeg needed), so input must be 16 kHz mono 16-bit PCM.

Usage: uv run scripts/asr/run_breeze.py [--set synth|real] [--dir DIR]
"""
import json
from pathlib import Path

from _common import parse_args, run

MODEL = "MarkChen1214/Breeze-ASR-25-MLX-5bit"
ENGINE = "breeze"
QUANT_KEYS = {"group_size", "bits", "mode"}


def load_model(repo: str):
    import mlx.core as mx
    import mlx.nn as nn
    from huggingface_hub import snapshot_download
    from mlx.utils import tree_unflatten
    from mlx_whisper import whisper

    path = Path(snapshot_download(repo_id=repo, allow_patterns=["config.json", "model.safetensors"]))
    config = json.loads((path / "config.json").read_text())
    quant = config.pop("quantization", None) or {}
    config.pop("quantization_config", None)
    config.pop("model_type", None)
    default_q = {k: v for k, v in quant.items() if k in QUANT_KEYS}
    per_module = {k: v for k, v in quant.items() if isinstance(v, dict)}

    weights = mx.load(str(path / "model.safetensors"))
    model = whisper.Whisper(whisper.ModelDimensions(**config), mx.float16)

    def predicate(p, m):
        if not isinstance(m, (nn.Linear, nn.Embedding)) or f"{p}.scales" not in weights:
            return False
        return per_module.get(p, default_q)

    if quant:
        nn.quantize(model, **default_q, class_predicate=predicate)
    model.update(tree_unflatten(list(weights.items())))
    mx.eval(model.parameters())
    return model


def read_wav_16k(path: Path):
    """16 kHz mono 16-bit PCM WAV -> float32 array (avoids mlx_whisper's ffmpeg dependency)."""
    import wave

    import numpy as np

    with wave.open(str(path), "rb") as w:
        if (w.getframerate(), w.getnchannels(), w.getsampwidth()) != (16000, 1, 2):
            raise SystemExit(f"{path}: expected 16 kHz mono 16-bit PCM WAV")
        pcm = w.readframes(w.getnframes())
    return np.frombuffer(pcm, dtype="<i2").astype(np.float32) / 32768.0


def load():
    import mlx_whisper
    from mlx_whisper.transcribe import ModelHolder

    # Pre-seed mlx_whisper's model cache so transcribe() reuses our loaded model.
    ModelHolder.model = load_model(MODEL)
    ModelHolder.model_path = MODEL

    def transcribe(path: Path) -> str:
        result = mlx_whisper.transcribe(read_wav_16k(path), path_or_hf_repo=MODEL, language="zh",
                                        condition_on_previous_text=False, verbose=None)
        return result["text"]

    return transcribe


if __name__ == "__main__":
    run(ENGINE, parse_args(__doc__.splitlines()[0]), load)
