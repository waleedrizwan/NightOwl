#!/usr/bin/env bash
# Install (or update) the recorder on the Pi and schedule it with cron.
# Run from the Mac. Safe to run again after editing record.sh.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
HOST="${OWL_HOST:-nightowl}"

echo "Installing the recorder on $HOST"
ssh "$HOST" 'mkdir -p ~/nightowl ~/nights'
scp -q "$HERE/record.sh" "$HOST:nightowl/record.sh"
# Replace any earlier recorder entries (including the pre-rename dreamcatcher/ one)
# so two recorders never fight over the mic.
ssh "$HOST" 'chmod +x ~/nightowl/record.sh &&
  { crontab -l 2>/dev/null | grep -v -E "(nightowl|dreamcatcher)/record\.sh" || true
    echo "*/5 * * * * $HOME/nightowl/record.sh"
    echo "@reboot $HOME/nightowl/record.sh"; } | crontab - &&
  crontab -l | grep nightowl'
echo "Done. Log on the Pi: ~/nightowl/record.log"
