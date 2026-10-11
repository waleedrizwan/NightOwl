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
# delete it there. Always keep the two newest nights so the iPhone can still
# download them ("I'm up" or a re-run), and never delete in the middle of one of
# its downloads: the 12:15 run once pulled the files out from under the phone.
recent="$(ssh "$HOST" 'ls -1 nights | tail -n 2')"
for night in $(ssh "$HOST" 'ls -1 nights'); do
  grep -qx "$night" <<<"$recent" && { echo "Keeping $night on the Pi (one of the two newest)"; continue; }
  if [ -d "$DATA/nights/$night" ] && \
     [ -z "$(rsync -anc --itemize-changes "$HOST:nights/$night/" "$DATA/nights/$night/")" ]; then
    ssh "$HOST" "rm -rf 'nights/$night'"
    echo "Removed $night from the Pi (verified copy on this Mac)"
  else
    echo "Keeping $night on the Pi (copy on this Mac doesn't match)"
  fi
done
