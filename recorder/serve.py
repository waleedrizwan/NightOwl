#!/usr/bin/env python3
"""Night Owl file server (Raspberry Pi): lets the iPhone app fetch a night
directly over Wi-Fi and stop the recorder, with no Mac in between.

Stdlib only. Read-only: nothing here deletes a recording (the Mac's pull.sh
still owns cleanup, after a checksummed copy). Every request but GET / needs
the token in ~/nightowl/server.token, sent as "Authorization: Bearer <token>";
it is created on first start. Run by cron (install.sh), one copy at a time.

    GET  /                          {"service": "nightowl", "version": 1}  (no token)
    GET  /status                    recording now? until when? the schedule; stopped early? mic plugged in?
    GET  /nights                    every night with its files, sizes, and which are complete
    GET  /nights/<night>/<file>     the WAV, with Range support so a dropped download resumes
    GET  /nights/<night>/<file>.sha256    {"sha256": ...} to verify a copy
    POST /stop                      end tonight's recording (stop.sh, the "I'm up" button)
    POST /start                     record now until the next scheduled stop time (or {"until": "HH:MM"})
    POST /schedule                  {"auto": true, "start": "02:00", "end": "11:00"}: when record.sh records
"""
from __future__ import annotations

import hashlib
import hmac
import json
import os
import re
import secrets
import subprocess
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HOME = Path.home()
ROOT = Path(os.environ.get("OWL_ROOT", HOME / "nights"))
APP = HOME / "nightowl"
TOKEN_FILE = APP / "server.token"
STOPPED = APP / "stopped"
SCHEDULE = APP / "schedule"          # read by record.sh
MANUAL = APP / "manual"              # epoch seconds: record.sh records until then
DEFAULT_SCHEDULE = {"auto": True, "start": "02:00", "end": "11:00"}
PORT = int(os.environ.get("OWL_PORT", "8642"))
os.environ.setdefault("TZ", "America/Toronto")
time.tzset()

HHMM_RE = re.compile(r"^([01][0-9]|2[0-3]):[0-5][0-9]$")
NIGHT_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
FILE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}\.wav$")
CHUNK = 256 * 1024


def token() -> str:
    if not TOKEN_FILE.exists():
        APP.mkdir(parents=True, exist_ok=True)
        fd = os.open(TOKEN_FILE, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as fh:
            fh.write(secrets.token_urlsafe(24) + "\n")
    return TOKEN_FILE.read_text().strip()


def recording() -> bool:
    return subprocess.run(["pgrep", "-x", "arecord"], capture_output=True).returncode == 0


def mic() -> bool:
    """Is record.sh's mic plugged in? ALSA lists each card under /proc/asound by its id."""
    card = re.search(r"CARD=([^,]+)", os.environ.get("OWL_DEVICE", "plughw:CARD=Device,DEV=0"))
    return card is None or Path("/proc/asound", card.group(1)).exists()


def schedule() -> dict:
    out = dict(DEFAULT_SCHEDULE)
    if SCHEDULE.exists():
        for line in SCHEDULE.read_text().splitlines():
            k, _, v = line.partition("=")
            if k == "AUTO" and v in ("0", "1"):
                out["auto"] = v == "1"
            elif k in ("START", "END") and HHMM_RE.match(v):
                out[k.lower()] = v
    return out


def next_time(hhmm: str) -> int:
    """Epoch seconds of the next HH:MM (local), today if still ahead, else tomorrow."""
    h, m = map(int, hhmm.split(":"))
    now = time.localtime()
    t = time.mktime((now.tm_year, now.tm_mon, now.tm_mday, h, m, 0, 0, 0, -1))
    if t <= time.time():
        t = time.mktime((now.tm_year, now.tm_mon, now.tm_mday + 1, h, m, 0, 0, 0, -1))
    return int(t)


def manual_until() -> int | None:
    try:
        u = int(MANUAL.read_text().strip())
    except (OSError, ValueError):
        return None
    return u if u > time.time() else None


def write_atomic(path: Path, text: str):
    tmp = path.with_suffix(".tmp")
    tmp.write_text(text)
    tmp.replace(path)


def nights() -> list[dict]:
    live = recording()
    out = []
    if not ROOT.is_dir():
        return out
    for d in sorted(p for p in ROOT.iterdir() if p.is_dir() and NIGHT_RE.match(p.name)):
        files = sorted(f for f in d.iterdir() if FILE_RE.match(f.name))
        rows = [{"name": f.name, "bytes": f.stat().st_size, "complete": True} for f in files]
        # arecord is writing the newest file of tonight's folder: not done yet
        if live and rows and d.name == time.strftime("%Y-%m-%d"):
            rows[-1]["complete"] = False
        out.append({"night": d.name, "files": rows, "bytes": sum(r["bytes"] for r in rows)})
    return out


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        while block := fh.read(1 << 20):
            h.update(block)
    return h.hexdigest()


class Handler(BaseHTTPRequestHandler):
    server_version = "NightOwl/1"
    TOKEN = ""

    def log_message(self, fmt, *args):   # one short line per request, never the token
        sys.stderr.write(f"{time.strftime('%F %T')} {self.client_address[0]} {fmt % args}\n")

    def send_json(self, body, status=200):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def authorized(self) -> bool:
        got = self.headers.get("Authorization", "")
        if hmac.compare_digest(got.encode(), f"Bearer {self.TOKEN}".encode()):
            return True
        self.send_json({"error": "unauthorized"}, 401)
        return False

    def wav_path(self, night: str, name: str) -> Path | None:
        if not (NIGHT_RE.match(night) and FILE_RE.match(name)):
            return None
        p = ROOT / night / name
        return p if p.is_file() else None

    def do_GET(self):
        parts = [p for p in self.path.split("?")[0].split("/") if p]
        if not parts:
            return self.send_json({"service": "nightowl", "version": 1})
        if not self.authorized():
            return
        if parts == ["status"]:
            return self.send_json(self.status())
        if parts == ["nights"]:
            return self.send_json({"nights": nights()})
        if len(parts) == 3 and parts[0] == "nights":
            night, name = parts[1], parts[2]
            if name.endswith(".sha256"):
                p = self.wav_path(night, name[:-len(".sha256")])
                return self.send_json({"sha256": sha256(p)} if p else {"error": "not found"},
                                      200 if p else 404)
            p = self.wav_path(night, name)
            if p is None:
                return self.send_json({"error": "not found"}, 404)
            return self.send_file(p)
        self.send_json({"error": "not found"}, 404)

    def send_file(self, p: Path):
        size = p.stat().st_size
        start, end = 0, size - 1
        m = re.match(r"^bytes=(\d*)-(\d*)$", self.headers.get("Range", ""))
        if m and (m.group(1) or m.group(2)):
            if m.group(1):
                start = int(m.group(1))
                end = min(int(m.group(2)), size - 1) if m.group(2) else size - 1
            else:   # bytes=-N: the last N bytes
                start = max(0, size - int(m.group(2)))
            if start > end or start >= size:
                self.send_response(416)
                self.send_header("Content-Range", f"bytes */{size}")
                self.end_headers()
                return
            self.send_response(206)
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        else:
            self.send_response(200)
        length = end - start + 1
        self.send_header("Content-Type", "audio/wav")
        self.send_header("Content-Length", str(length))
        self.send_header("Accept-Ranges", "bytes")
        self.end_headers()
        with open(p, "rb") as fh:
            fh.seek(start)
            while length > 0:
                block = fh.read(min(CHUNK, length))
                if not block:
                    break
                self.wfile.write(block)
                length -= len(block)

    def status(self) -> dict:
        until = manual_until()
        return {
            "recording": recording(),
            "mic": mic(),
            "today": time.strftime("%Y-%m-%d"),
            "stoppedToday": STOPPED.exists() and STOPPED.read_text().strip() == time.strftime("%Y-%m-%d"),
            "schedule": schedule(),
            "manualUntil": until * 1000 if until else None,   # ms, like the app's other times
        }

    def body(self) -> dict:
        n = int(self.headers.get("Content-Length") or 0)
        if not n:
            return {}
        try:
            data = json.loads(self.rfile.read(min(n, 4096)))
        except ValueError:
            return {}
        return data if isinstance(data, dict) else {}

    def do_POST(self):
        if not self.authorized():
            return
        path = self.path.split("?")[0].rstrip("/")
        if path == "/stop":
            r = subprocess.run([str(APP / "stop.sh")], capture_output=True, text=True, timeout=30)
            return self.send_json({"stopped": r.returncode == 0,
                                   "output": (r.stdout + r.stderr).strip()},
                                  200 if r.returncode == 0 else 500)
        if path == "/start":
            until = self.body().get("until") or schedule()["end"]
            if not isinstance(until, str) or not HHMM_RE.match(until):
                return self.send_json({"error": "until must be HH:MM"}, 400)
            write_atomic(MANUAL, f"{next_time(until)}\n")
            STOPPED.unlink(missing_ok=True)          # overrides an earlier "I'm up" today
            subprocess.Popen([str(APP / "record.sh")], start_new_session=True,
                             stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            for _ in range(20):                      # record.sh has the lock: say so once arecord is up
                if recording():
                    break
                time.sleep(0.25)
            return self.send_json(self.status())
        if path == "/schedule":
            b, cur = self.body(), schedule()
            new = {"auto": b.get("auto", cur["auto"]), "start": b.get("start", cur["start"]),
                   "end": b.get("end", cur["end"])}
            if not (isinstance(new["auto"], bool) and all(isinstance(new[k], str) and HHMM_RE.match(new[k])
                                                            for k in ("start", "end"))):
                return self.send_json({"error": "want auto: bool, start and end: HH:MM"}, 400)
            if new["start"] >= new["end"]:
                return self.send_json({"error": "the stop time must be after the start time (same day)"}, 400)
            write_atomic(SCHEDULE, f"AUTO={int(new['auto'])}\nSTART={new['start']}\nEND={new['end']}\n")
            return self.send_json(self.status())
        self.send_json({"error": "not found"}, 404)


def main():
    Handler.TOKEN = token()
    server = ThreadingHTTPServer(("", PORT), Handler)
    server.daemon_threads = True
    sys.stderr.write(f"{time.strftime('%F %T')} serving {ROOT} on port {PORT}\n")
    server.serve_forever()


if __name__ == "__main__":
    main()
