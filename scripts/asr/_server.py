"""Run a local transcription server under /usr/bin/time -l and POST each WAV to it.

Not a script; imported by run_breeze_cpp.py and run_breeze_whisperkit.py.
A per-file CLI invocation would reload the model for every sentence, so the runners
start the engine's own server once (load once), then time each HTTP request
(`seconds` = request wall time, model already loaded; localhost HTTP overhead is
included and is a few ms). The server runs under `/usr/bin/time -l`, so stopping it
prints the process's peak RSS and peak memory footprint.
"""
from __future__ import annotations

import json
import os
import re
import signal
import socket
import subprocess
import time
import urllib.request
import uuid
from pathlib import Path
from typing import Callable


def _post_multipart(url: str, fields: dict[str, str], wav: Path, timeout: float) -> dict:
    boundary = uuid.uuid4().hex
    parts = []
    for name, value in fields.items():
        parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n{value}\r\n'.encode())
    parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="{wav.name}"\r\n'
                 f'Content-Type: audio/wav\r\n\r\n'.encode() + wav.read_bytes() + b"\r\n")
    parts.append(f"--{boundary}--\r\n".encode())
    req = urllib.request.Request(url, data=b"".join(parts), method="POST",
                                 headers={"Content-Type": f"multipart/form-data; boundary={boundary}"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8"))


class TimedServer:
    """`cmd` must start a server on 127.0.0.1:`port` that loads its model before listening."""

    def __init__(self, cmd: list[str], port: int, log_path: Path):
        self.cmd, self.port, self.log_path = cmd, port, log_path
        self.proc: subprocess.Popen | None = None

    def start(self, timeout: float = 900) -> None:
        self.log = self.log_path.open("w")
        print("[server] " + " ".join(self.cmd), flush=True)
        self.proc = subprocess.Popen(["/usr/bin/time", "-l", *self.cmd],
                                     stdout=self.log, stderr=subprocess.STDOUT)
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self.proc.poll() is not None:
                raise SystemExit(f"server exited early; see {self.log_path}")
            with socket.socket() as s:
                if s.connect_ex(("127.0.0.1", self.port)) == 0:
                    return
            time.sleep(0.05)
        raise SystemExit(f"server not listening after {timeout}s; see {self.log_path}")

    def transcriber(self, path: str, fields: dict[str, str], timeout: float = 120) -> Callable[[Path], str]:
        url = f"http://127.0.0.1:{self.port}{path}"
        return lambda wav: _post_multipart(url, fields, wav, timeout)["text"]

    def stop(self) -> dict[str, int]:
        """SIGTERM the server (child of /usr/bin/time) and return time -l's memory figures in bytes."""
        assert self.proc is not None
        child = subprocess.run(["pgrep", "-P", str(self.proc.pid)], capture_output=True, text=True).stdout.split()
        for pid in child:
            os.kill(int(pid), signal.SIGTERM)
        try:
            self.proc.wait(timeout=30)
        except subprocess.TimeoutExpired:
            for pid in child:
                os.kill(int(pid), signal.SIGKILL)
            self.proc.wait()
        self.log.close()
        text = self.log_path.read_text(errors="replace")
        mem = {}
        for key, label in (("max_rss", "maximum resident set size"), ("peak_footprint", "peak memory footprint")):
            m = re.search(rf"(\d+)\s+{label}", text)
            if m:
                mem[key] = int(m.group(1))
        print(f"[server] peak RSS {mem.get('max_rss', 0) / 2**30:.2f} GiB, "
              f"peak footprint {mem.get('peak_footprint', 0) / 2**30:.2f} GiB (log: {self.log_path})", flush=True)
        return mem
