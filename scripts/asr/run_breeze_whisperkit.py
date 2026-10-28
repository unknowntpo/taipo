# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///
"""Transcribe <id>.wav files with Breeze-ASR-25 on WhisperKit (CoreML) -> results/breeze-whisperkit.jsonl.

Route: `whisperkit-cli serve` (Homebrew whisperkit-cli 1.1.1, WhisperKit's local
OpenAI-compatible server) with fredchu/breeze-asr-25-whisperkit-coreml (whisperkittools
4-bit palettized conversion of MediaTek-Research/Breeze-ASR-25, ~1.05 GB; we did not
convert it ourselves). Compute units: WhisperKit defaults (encoder and decoder
cpuAndNeuralEngine). The server loads the model once; each WAV is one
POST /v1/audio/transcriptions. Decoding: language zh, no prompt, greedy (temperature 0,
default fallback). The tokenizer (Whisper large-v2) is fetched once into the models folder.

Requires: brew install whisperkit-cli; the model folder in ~/Library/Application Support/Taipo/models/.
Usage: uv run scripts/asr/run_breeze_whisperkit.py [--set synth|real] [--dir DIR] [--model DIR]
"""
import shutil
from pathlib import Path

from _common import MODELS_ROOT, parse_args, run, set_dir
from _server import TimedServer

ENGINE = "breeze-whisperkit"
MODEL = MODELS_ROOT / "breeze-asr-25-whisperkit-coreml"
TOKENIZER = MODELS_ROOT / "whisperkit-tokenizers"
PORT = 50072


def main() -> None:
    def extra(p):
        p.add_argument("--model", type=Path, default=MODEL, help=f"model folder (default: {MODEL})")
        p.add_argument("--encoder-units", default="cpuAndNeuralEngine", help="audio encoder compute units")
        p.add_argument("--engine", default=ENGINE, help=f"engine name for results (default: {ENGINE})")
        p.add_argument("--decoder-units", default="cpuAndNeuralEngine", help="text decoder compute units")

    args = parse_args(__doc__.splitlines()[0], extra)
    exe = shutil.which("whisperkit-cli") or "/opt/homebrew/bin/whisperkit-cli"
    server = TimedServer([exe, "serve", "--model-path", str(args.model.expanduser()),
                          "--download-tokenizer-path", str(TOKENIZER), "--language", "zh",
                          "--audio-encoder-compute-units", args.encoder_units,
                          "--text-decoder-compute-units", args.decoder_units,
                          "--host", "127.0.0.1", "--port", str(PORT)],
                         PORT, set_dir(args) / "results" / f"{args.engine}.server.log")

    def load():
        # The first load on a machine compiles the CoreML models for the ANE (can take > 15 min).
        server.start(timeout=3600)
        return server.transcriber("/v1/audio/transcriptions",
                                  {"model": "breeze-asr-25", "language": "zh", "response_format": "json",
                                   "temperature": "0"})

    try:
        run(args.engine, args, load)
    finally:
        server.stop()


if __name__ == "__main__":
    main()
