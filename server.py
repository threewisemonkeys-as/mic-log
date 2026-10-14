#!/usr/bin/env python3
"""Mic dashboard: transcribes clips captured by ./vad and serves them on localhost.

    python3 server.py [port]     (default 8770)
"""
import json
import re
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parent
REC = ROOT / "recordings"
PENDING = REC / "pending"
PAUSE = REC / "PAUSED"
WHISPER = ROOT / "whisper.cpp/build/bin/whisper-cli"
MODEL = ROOT / "models/ggml-base.en.bin"
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8770

ID_RE = re.compile(r"^[0-9]{8}-[0-9]{6}-[0-9]{3}$")
# Whisper's markers for non-speech, e.g. "[BLANK_AUDIO]", "(wind blowing)", "* music *"
NON_SPEECH_RE = re.compile(r"^(\s*(\[[^\]]*\]|\([^)]*\)|\*[^*]*\*|♪+)\s*)*$")

PENDING.mkdir(parents=True, exist_ok=True)


def write_json(path, data):
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(data))
    tmp.replace(path)


def transcribe(caf):
    cid = caf.stem
    meta_path = PENDING / f"{cid}.meta.json"
    meta = json.loads(meta_path.read_text()) if meta_path.exists() else {"id": cid}
    out = REC / f"{cid}.json"
    write_json(out, {**meta, "status": "transcribing"})

    wav = REC / f"{cid}.wav"
    subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", str(caf), str(wav)],
                   check=True, capture_output=True)
    t0 = time.time()
    r = subprocess.run([str(WHISPER), "-m", str(MODEL), "-f", str(wav), "-nt", "-np", "-l", "en", "-t", "4"],
                       capture_output=True, text=True)
    text = " ".join(line.strip() for line in r.stdout.splitlines() if line.strip())
    speech = bool(text) and not NON_SPEECH_RE.match(text)
    write_json(out, {**meta, "status": "done" if r.returncode == 0 else "error",
                     "text": text, "speech": speech, "transcribe_sec": round(time.time() - t0, 1)})
    caf.unlink(missing_ok=True)
    meta_path.unlink(missing_ok=True)
    print(f"{cid}: {text!r}", flush=True)


def worker():
    while True:
        for caf in sorted(PENDING.glob("*.caf")):
            try:
                transcribe(caf)
            except Exception as e:  # keep going; leave the clip visible as an error
                print(f"{caf.name}: {e}", flush=True)
                write_json(REC / f"{caf.stem}.json", {"id": caf.stem, "status": "error", "text": str(e)})
                caf.rename(caf.with_suffix(".failed"))
        time.sleep(0.5)


def clips():
    out = []
    for p in REC.glob("*.json"):
        if p.name == "state.json":
            continue
        try:
            out.append(json.loads(p.read_text()))
        except (OSError, ValueError):
            pass
    out.sort(key=lambda c: c.get("id", ""))
    return out


def state():
    s = {"online": False}
    try:
        s = json.loads((REC / "state.json").read_text())
        s["online"] = time.time() - s.get("ts", 0) < 3
    except (OSError, ValueError):
        pass
    s["paused"] = PAUSE.exists()
    s["queue"] = len(list(PENDING.glob("*.caf")))
    return s


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, code, body, ctype="application/json", extra=None):
        if not isinstance(body, bytes):
            body = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/":
            return self.send(200, (ROOT / "dashboard.html").read_bytes(), "text/html; charset=utf-8")
        if path == "/api/clips":
            return self.send(200, clips())
        if path == "/api/state":
            return self.send(200, state())
        m = re.match(r"^/audio/([0-9-]+)\.wav$", path)
        if m and ID_RE.match(m.group(1)) and (REC / f"{m.group(1)}.wav").exists():
            return self.serve_audio(REC / f"{m.group(1)}.wav")
        self.send(404, {"error": "not found"})

    def serve_audio(self, f):
        data = f.read_bytes()
        rng = re.match(r"bytes=(\d*)-(\d*)", self.headers.get("Range", ""))
        if rng and (rng.group(1) or rng.group(2)):
            start = int(rng.group(1)) if rng.group(1) else len(data) - int(rng.group(2))
            end = int(rng.group(2)) if rng.group(1) and rng.group(2) else len(data) - 1
            end = min(end, len(data) - 1)
            return self.send(206, data[start:end + 1], "audio/wav",
                             {"Content-Range": f"bytes {start}-{end}/{len(data)}", "Accept-Ranges": "bytes"})
        self.send(200, data, "audio/wav", {"Accept-Ranges": "bytes"})

    def do_POST(self):
        path = urlparse(self.path).path
        if path == "/api/pause":
            PAUSE.touch()
            return self.send(200, state())
        if path == "/api/resume":
            PAUSE.unlink(missing_ok=True)
            return self.send(200, state())
        self.send(404, {"error": "not found"})

    def do_DELETE(self):
        m = re.match(r"^/api/clips/([0-9-]+)$", urlparse(self.path).path)
        if not m or not ID_RE.match(m.group(1)):
            return self.send(404, {"error": "not found"})
        for ext in (".json", ".wav"):
            (REC / f"{m.group(1)}{ext}").unlink(missing_ok=True)
        self.send(200, {"ok": True})


if __name__ == "__main__":
    threading.Thread(target=worker, daemon=True).start()
    print(f"dashboard: http://localhost:{PORT}", flush=True)
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
