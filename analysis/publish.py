#!/usr/bin/env python3
"""Put the nights where the Night Owl iPhone app can read them: a folder in iCloud Drive.

    <iCloud Drive>/NightOwl/nights.json              every night, oldest first
    <iCloud Drive>/NightOwl/clips/<night>/<name>.m4a snore and gasp clips (AAC, ~7x smaller)

Only summaries and short clips go to iCloud; full-night audio stays on this Mac.
The app writes devices.json into the same folder so notify.py knows where to push.
"""
import json
import os
import subprocess
from pathlib import Path

from dashboard import compact, load

DATA = Path(os.environ.get("OWL_DATA", Path.home() / "NightOwl"))
CLOUD = Path(os.environ.get("OWL_CLOUD", Path.home() / "Library/Mobile Documents/com~apple~CloudDocs/NightOwl"))


def m4a(clip: str | None) -> str | None:
    return clip and clip.removeprefix("clips/").removesuffix(".wav") + ".m4a"


def main():
    nights = [compact(s) for s in load(DATA)]
    converted = 0
    for n in nights:
        for item in n["bouts"] + n["gasps"]:
            src = item["clip"]
            item["clip"] = m4a(src) and f'clips/{n["dir"]}/{m4a(src)}'
            if not src:
                continue
            out = CLOUD / item["clip"]
            if not out.exists():
                out.parent.mkdir(parents=True, exist_ok=True)
                subprocess.run(["afconvert", "-f", "m4af", "-d", "aac", "-b", "32000",
                                str(DATA / "reports" / n["dir"] / src), str(out)], check=True)
                converted += 1
    CLOUD.mkdir(parents=True, exist_ok=True)
    tmp = CLOUD / ".nights.json.tmp"
    tmp.write_text(json.dumps({"nights": nights}))
    tmp.replace(CLOUD / "nights.json")
    print(f"  published {len(nights)} nights to {CLOUD} ({converted} new clips)")


if __name__ == "__main__":
    main()
