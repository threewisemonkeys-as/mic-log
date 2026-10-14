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
CONFIG = REC / "config.json"
WHISPER = ROOT / "whisper.cpp/build/bin/whisper-cli"
CLASSIFY = ROOT / "classify"
GROUPS = json.loads((ROOT / "sound_groups.json").read_text())
MODEL = ROOT / "models/ggml-base.en.bin"
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8770

ID_RE = re.compile(r"^[0-9]{8}-[0-9]{6}-[0-9]{3}$")
# Whisper's markers for non-speech, e.g. "[BLANK_AUDIO]", "(wind blowing)", "* music *"
NON_SPEECH_RE = re.compile(r"^(\s*(\[[^\]]*\]|\([^)]*\)|\*[^*]*\*|♪+)\s*)*$")

# Clips are kept (and transcribed) when the sound classifier hears one of these labels.
DEFAULT_CONFIG = {
    "margin_db": 12,
    "keep": ["speech", "whispering", "shout", "yell", "children_shouting", "screaming", "chatter", "babble"],
    "min_confidence": 0.5,
}

PENDING.mkdir(parents=True, exist_ok=True)


def config():
    try:
        return {**DEFAULT_CONFIG, **json.loads(CONFIG.read_text())}
    except (OSError, ValueError):
        return dict(DEFAULT_CONFIG)


def kept(clip, cfg):
    labels = clip.get("labels")
    if not labels:  # not classified (classifier failed or unavailable): keep
        return True
    keep = set(cfg["keep"])
    return any(name in keep and conf >= cfg["min_confidence"] for name, conf in labels)


def write_json(path, data):
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(data))
    tmp.replace(path)


def classify(wavs):
    """{wav path: [[label, confidence], ...]} from the on-device sound classifier."""
    if not wavs:
        return {}
    r = subprocess.run([str(CLASSIFY), *map(str, wavs)], capture_output=True, text=True)
    out = {}
    for line in r.stdout.splitlines():
        try:
            d = json.loads(line)
        except ValueError:
            continue
        if "labels" in d:
            out[d["file"]] = d["labels"][:12]
    return out


def whisper(clip):
    out = REC / f"{clip['id']}.json"
    write_json(out, {**clip, "status": "transcribing"})
    t0 = time.time()
    r = subprocess.run([str(WHISPER), "-m", str(MODEL), "-f", str(REC / f"{clip['id']}.wav"),
                        "-nt", "-np", "-l", "en", "-t", "4"], capture_output=True, text=True)
    text = " ".join(line.strip() for line in r.stdout.splitlines() if line.strip())
    speech = bool(text) and not NON_SPEECH_RE.match(text)
    write_json(out, {**clip, "status": "done" if r.returncode == 0 else "error",
                     "text": text, "speech": speech, "transcribe_sec": round(time.time() - t0, 1)})
    print(f"{clip['id']}: {text!r}", flush=True)


def process(caf):
    cid = caf.stem
    meta_path = PENDING / f"{cid}.meta.json"
    meta = json.loads(meta_path.read_text()) if meta_path.exists() else {"id": cid}
    out = REC / f"{cid}.json"
    write_json(out, {**meta, "status": "transcribing"})

    wav = REC / f"{cid}.wav"
    subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", str(caf), str(wav)],
                   check=True, capture_output=True)
    labels = classify([wav]).get(str(wav))
    clip = {**meta, "status": "done"}
    if labels is not None:
        clip["labels"] = labels
    if kept(clip, config()):
        whisper(clip)
    else:  # not transcribed unless the keep list changes to include it
        write_json(out, clip)
        print(f"{cid}: filtered {[n for n, _ in (labels or [])[:3]]}", flush=True)
    caf.unlink(missing_ok=True)
    meta_path.unlink(missing_ok=True)


def catch_up():
    """Classify clips recorded before the classifier existed, and transcribe clips
    that are now kept but were never transcribed."""
    cfg = config()
    unlabeled = [c for c in clips() if c.get("status") == "done" and "labels" not in c
                 and (REC / f"{c['id']}.wav").exists()]
    if unlabeled:
        found = classify([REC / f"{c['id']}.wav" for c in unlabeled])
        for c in unlabeled:
            # [] marks "tried", so a file the classifier can't read isn't retried forever
            write_json(REC / f"{c['id']}.json", {**c, "labels": found.get(str(REC / f"{c['id']}.wav"), [])})
        print(f"classified {len(unlabeled)} older clips", flush=True)
    for c in clips():
        if c.get("status") == "done" and "text" not in c and kept(c, cfg) and (REC / f"{c['id']}.wav").exists():
            whisper(c)
            if any(PENDING.glob("*.caf")):  # new recordings first
                return


def worker():
    while True:
        for caf in sorted(PENDING.glob("*.caf")):
            try:
                process(caf)
            except Exception as e:  # keep going; leave the clip visible as an error
                print(f"{caf.name}: {e}", flush=True)
                write_json(REC / f"{caf.stem}.json", {"id": caf.stem, "status": "error", "text": str(e)})
                caf.rename(caf.with_suffix(".failed"))
        try:
            catch_up()
        except Exception as e:
            print(f"catch-up: {e}", flush=True)
        time.sleep(0.5)


def clips():
    out = []
    for p in REC.glob("*.json"):
        if p.name in ("state.json", "config.json"):
            continue
        try:
            out.append(json.loads(p.read_text()))
        except (OSError, ValueError):
            pass
    out.sort(key=lambda c: c.get("id", ""))
    return out


def sounds():
    """Label groups, the current keep list, and how many clips each label appears in."""
    cfg = config()
    counts = {}
    for c in clips():
        for name, conf in c.get("labels") or []:
            if conf >= cfg["min_confidence"]:
                counts[name] = counts.get(name, 0) + 1
    return {"groups": GROUPS, "keep": cfg["keep"], "min_confidence": cfg["min_confidence"], "counts": counts}


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
            cfg = config()
            return self.send(200, [{**c, "kept": kept(c, cfg)} for c in clips()])
        if path == "/api/sounds":
            return self.send(200, sounds())
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
        if path == "/api/config":
            known = {name for names in GROUPS.values() for name in names}
            cfg = config()
            try:
                body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
                if "margin_db" in body:
                    cfg["margin_db"] = round(float(body["margin_db"]), 1)
                    assert 3 <= cfg["margin_db"] <= 50, "margin_db must be between 3 and 50"
                if "min_confidence" in body:
                    cfg["min_confidence"] = round(float(body["min_confidence"]), 2)
                    assert 0.05 <= cfg["min_confidence"] <= 1, "min_confidence must be between 0.05 and 1"
                if "keep" in body:
                    cfg["keep"] = sorted(set(body["keep"]))
                    assert set(cfg["keep"]) <= known, "unknown sound label"
            except (ValueError, TypeError, AttributeError) as e:
                return self.send(400, {"error": f"bad config: {e}"})
            except AssertionError as e:
                return self.send(400, {"error": str(e)})
            write_json(CONFIG, cfg)
            return self.send(200, cfg)
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
