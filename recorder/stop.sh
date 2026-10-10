#!/usr/bin/env bash
# End tonight's recording early ("I'm up"). The Mac's wake.sh runs this over ssh.
# Marks today as done so cron doesn't restart the recorder before END, then
# interrupts arecord, which closes the current file cleanly.
set -u
export TZ="${OWL_TZ:-America/Toronto}"
date +%F > "$HOME/nightowl/stopped"
pkill -INT -x arecord || echo "not recording"
# Wait for the file to close so a pull right after gets a complete WAV.
for _ in $(seq 1 20); do pgrep -x arecord >/dev/null || exit 0; sleep 0.5; done
echo "arecord still running" >&2
exit 1
