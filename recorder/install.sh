#!/usr/bin/env bash
# Install (or update) the recorder on the Pi and schedule it with cron.
# Run from the Mac. Safe to run again after editing record.sh.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
HOST="${OWL_HOST:-nightowl}"

echo "Installing the recorder and file server on $HOST"
ssh "$HOST" 'mkdir -p ~/nightowl ~/nights'
# Copy under temporary names and rename into place: bash reads a script as it
# runs, so overwriting record.sh in place would corrupt a recording in progress;
# a rename leaves the running copy its old file.
scp -q "$HERE/record.sh" "$HOST:nightowl/record.sh.new"
scp -q "$HERE/stop.sh" "$HOST:nightowl/stop.sh.new"
scp -q "$HERE/serve.py" "$HOST:nightowl/serve.py.new"
ssh "$HOST" 'cd ~/nightowl && chmod +x record.sh.new stop.sh.new serve.py.new &&
  mv record.sh.new record.sh && mv stop.sh.new stop.sh && mv serve.py.new serve.py'
# Replace any earlier recorder entries (including the pre-rename dreamcatcher/ one)
# so two recorders never fight over the mic. The file server (serve.py) is
# started the same way; flock keeps it to one copy, so the 5-minute tick only
# restarts it if it died.
ssh "$HOST" 'chmod +x ~/nightowl/record.sh ~/nightowl/stop.sh ~/nightowl/serve.py &&
  serve="flock -n $HOME/nightowl/serve.lock nice -n 10 python3 $HOME/nightowl/serve.py >> $HOME/nightowl/serve.log 2>&1" &&
  { crontab -l 2>/dev/null | grep -v -E "(nightowl|dreamcatcher)/(record\.sh|serve\.py)" || true
    echo "*/5 * * * * $HOME/nightowl/record.sh"
    echo "@reboot $HOME/nightowl/record.sh"
    echo "*/5 * * * * $serve"
    echo "@reboot $serve"; } | crontab - &&
  crontab -l | grep nightowl &&
  pkill -f "^python3 $HOME/nightowl/serve\.py" || true
  sleep 1; nohup sh -c "$serve" </dev/null >/dev/null 2>&1 &'
echo "Done. Logs on the Pi: ~/nightowl/record.log, ~/nightowl/serve.log"
echo "The phone app needs the server token: ssh $HOST cat nightowl/server.token"
