#!/usr/bin/env bash
# End tonight's recording early ("I'm up"). Run by the Pi's file server (serve.py,
# POST /stop) for the phone, or over ssh by the Mac's wake.sh.
# Marks today as done so cron doesn't restart the recorder before END, then
# interrupts arecord, which closes the current file cleanly.
set -u
export TZ="${OWL_TZ:-America/Toronto}"
date +%F > "$HOME/nightowl/stopped"
rm -f "$HOME/nightowl/manual"          # and end a "Start recording" too
pkill -INT -x arecord || echo "not recording"
# Wait for the file to close so a pull right after gets a complete WAV.
for _ in $(seq 1 20); do pgrep -x arecord >/dev/null || exit 0; sleep 0.5; done
echo "arecord still running" >&2
exit 1
