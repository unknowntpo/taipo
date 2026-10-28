# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///
"""Transcribe <id>.wav files with Breeze-ASR-25 on whisper.cpp (Metal) -> results/breeze-cpp.jsonl.

Route: whisper.cpp `whisper-server` (Homebrew whisper-cpp 1.9.5, Metal + flash attention
on by default) with shdennlin/breeze-asr-25-ggml `ggml-breeze-asr-25-q5_0.bin`
(1.08 GB, sha256 f51573bd...990a). The server loads the model once; each WAV is one
POST /inference. Decoding: language zh, no prompt, greedy (server default beam size -1),
default temperature fallback, 4 threads.

Requires: brew install whisper-cpp; the .bin in ~/Library/Application Support/Taipo/models/.
Usage: uv run scripts/asr/run_breeze_cpp.py [--set synth|real] [--dir DIR] [--model PATH]
"""
import shutil
from pathlib import Path

from _common import MODELS_ROOT, parse_args, run, set_dir
from _server import TimedServer

ENGINE = "breeze-cpp"
MODEL = MODELS_ROOT / "ggml-breeze-asr-25-q5_0.bin"
PORT = 50071


def main() -> None:
    def extra(p):
        p.add_argument("--model", type=Path, default=MODEL, help=f"GGML model (default: {MODEL})")
        p.add_argument("--threads", type=int, default=4, help="CPU threads (default: 4, the server default)")
        p.add_argument("--engine", default=ENGINE, help=f"engine name for results (default: {ENGINE})")

    args = parse_args(__doc__.splitlines()[0], extra)
    exe = shutil.which("whisper-server") or "/opt/homebrew/bin/whisper-server"
    server = TimedServer([exe, "-m", str(args.model.expanduser()), "-l", "zh", "-t", str(args.threads),
                          "--host", "127.0.0.1", "--port", str(PORT)],
                         PORT, set_dir(args) / "results" / f"{args.engine}.server.log")

    def load():
        server.start()
        return server.transcriber("/inference", {"response_format": "json", "language": "zh",
                                                  "temperature": "0.0"})

    try:
        run(args.engine, args, load)
    finally:
        server.stop()


if __name__ == "__main__":
    main()
