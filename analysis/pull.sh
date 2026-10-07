#!/usr/bin/env bash
# Copy recorded nights from the bedside Pi to this Mac over the home network.
# Recordings land in $OWL_DATA/nights (default ~/NightOwl), outside the repo:
# they are audio of you sleeping and never belong in git.
set -euo pipefail

DATA="${OWL_DATA:-$HOME/NightOwl}"
HOST="${OWL_HOST:-nightowl}"
mkdir -p "$DATA/nights"

echo "Pulling nights from $HOST → $DATA/nights"
rsync -a --partial --progress "$HOST:nights/" "$DATA/nights/"
echo "Done. Nights on this Mac:"
ls -1 "$DATA/nights"

# Free the Pi's card: once a night is byte-for-byte on this Mac (checksummed),
# delete it there. Skip the night still being recorded.
recording="$(ssh "$HOST" 'pgrep -x arecord >/dev/null && date +%F || true')"
for night in $(ssh "$HOST" 'ls -1 nights'); do
  [ "$night" = "$recording" ] && { echo "Keeping $night on the Pi (still recording)"; continue; }
  if [ -d "$DATA/nights/$night" ] && \
     [ -z "$(rsync -anc --itemize-changes "$HOST:nights/$night/" "$DATA/nights/$night/")" ]; then
    ssh "$HOST" "rm -rf 'nights/$night'"
    echo "Removed $night from the Pi (verified copy on this Mac)"
  else
    echo "Keeping $night on the Pi (copy on this Mac doesn't match)"
  fi
done
