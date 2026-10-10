#!/usr/bin/env bash
# The app's "I'm up" button: it drops wake.json into the iCloud NightOwl folder,
# launchd (com.nightowl.wake) runs this when that folder changes, and we stop the
# Pi and build the report right away instead of waiting for noon.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CLOUD="${OWL_CLOUD:-$HOME/Library/Mobile Documents/com~apple~CloudDocs/NightOwl}"
HOST="${OWL_HOST:-nightowl}"
WAKE="$CLOUD/wake.json"

# Python, not bash: macOS lets the venv's python touch iCloud Drive from launchd,
# but bash gets "Operation not permitted".
# iCloud often syncs only the name of a file the phone just wrote ("dataless"),
# and reading one from launchd fails with EDEADLK. The file's existence is the
# request, so ask for the contents, wait a little, and remove it either way:
# leaving it behind makes launchd run this again every few seconds (2026-10-10:
# 418 failed runs, the Pi never stopped).
request="$("$HERE/.venv/bin/python" -c '
import os, subprocess, sys, time
p = sys.argv[1]
if not os.path.exists(p):
    sys.exit(1)
subprocess.run(["brctl", "download", p], capture_output=True)
for _ in range(15):
    try:
        print(open(p).read().strip()); break
    except OSError:
        time.sleep(1)
else:
    print("(contents still in iCloud)")
os.remove(p)' "$WAKE")" || exit 0

echo "$(date '+%F %T') wake: $request"
ssh "$HOST" nightowl/stop.sh || echo "couldn't stop the Pi; analyzing what's there"
"$HERE/morning.sh"
