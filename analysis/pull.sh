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
