#!/usr/bin/env bash
# Night Owl bedside recorder (Raspberry Pi).
#
# Records the USB mic to WAV in 10-minute files, either on the schedule
# (by default 02:00-11:00) or because the app said "Start recording", which
# records until the next scheduled stop time whatever the hour. Cron runs this
# every 5 minutes and on boot; when there's nothing to record it exits
# silently, so a power blip or a missed start costs at most 5 minutes.
# Unplugging the mic is the off switch: arecord fails, we retry every 30 s
# until the mic comes back or the recording should end. stop.sh ends the night
# early (the app's "I'm up"): it marks today as done, so the cron ticks until
# the stop time don't start it again.
#
#   ~/nightowl/schedule  AUTO=1|0, START=HH:MM, END=HH:MM (serve.py writes it from the app)
#   ~/nightowl/manual    epoch seconds: record until then ("Start recording")
#   ~/nightowl/stopped   the date of a night ended early by stop.sh
#
# Processing happens on the phone or the Mac; this script only records.
set -u

# Times and file names are in this zone regardless of the Pi's system
# timezone (changing that needs sudo; this does not).
export TZ="${OWL_TZ:-America/Toronto}"

DEVICE="${OWL_DEVICE:-plughw:CARD=Device,DEV=0}"
CHUNK_SECS="${OWL_CHUNK_SECS:-600}"
ROOT="${OWL_ROOT:-$HOME/nights}"
LOG="${OWL_LOG:-$HOME/nightowl/record.log}"
SCHEDULE="$HOME/nightowl/schedule"
MANUAL="$HOME/nightowl/manual"
STOPPED="$HOME/nightowl/stopped"

mkdir -p "$(dirname "$LOG")" "$ROOT"
log() { echo "$(date '+%F %T %Z') $*" >> "$LOG"; }

# One recorder at a time (cron, @reboot and "Start recording" can overlap).
exec 9>"$HOME/nightowl/record.lock"
flock -n 9 || exit 0

# Read, never source: the file comes from the network (validated there too).
load_schedule() {
  AUTO=1 START="${OWL_START:-02:00}" END="${OWL_END:-11:00}"
  [ -f "$SCHEDULE" ] || return 0
  local v
  v=$(sed -n 's/^AUTO=\([01]\)$/\1/p' "$SCHEDULE"); [ -n "$v" ] && AUTO=$v
  v=$(sed -n 's/^START=\([0-2][0-9]:[0-5][0-9]\)$/\1/p' "$SCHEDULE"); [ -n "$v" ] && START=$v
  v=$(sed -n 's/^END=\([0-2][0-9]:[0-5][0-9]\)$/\1/p' "$SCHEDULE"); [ -n "$v" ] && END=$v
  return 0
}

to_secs() { date -d "$1" +%s; }
in_window() {
  local now; now=$(date +%s)
  [ "$now" -ge "$(to_secs "today $START")" ] && [ "$now" -lt "$(to_secs "today $END")" ]
}
stopped_today() { [ "$(cat "$STOPPED" 2>/dev/null)" = "$(date +%F)" ]; }

# When the recording happening now should end (epoch seconds), or nothing.
target_end() {
  load_schedule
  local m; m=$(cat "$MANUAL" 2>/dev/null)
  if [[ "$m" =~ ^[0-9]+$ ]]; then
    if [ "$m" -gt "$(date +%s)" ]; then echo "$m"; return; fi
    rm -f "$MANUAL"                         # a finished manual recording
  fi
  if [ "$AUTO" = 1 ] && in_window && ! stopped_today; then to_secs "today $END"; fi
}

[ -n "$(target_end)" ] || exit 0   # the common case: a cron tick with nothing to record, stay quiet

# No RTC on a Pi 3: after a power cut the clock is wrong until network time
# syncs. Never decide when to record or name files on a wrong clock.
for _ in $(seq 1 60); do
  [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = "yes" ] && break
  sleep 15
done
if [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" != "yes" ]; then
  log "clock never synced after 15 min; not recording (wrong timestamps are worse than no night)"
  exit 1
fi

load_schedule
log "started ($( [ -f "$MANUAL" ] && echo "manual start" || echo "schedule $START-$END" ) $TZ, device $DEVICE)"
while :; do
  end=$(target_end)
  if [ -z "$end" ]; then
    stopped_today && log "stopped early (woke up)" || log "nothing to record now; exiting"
    exit 0
  fi
  remaining=$(( end - $(date +%s) ))
  night_dir="$ROOT/$(date +%F)"
  mkdir -p "$night_dir"
  log "recording ${remaining}s into $night_dir (until $(date -d "@$end" '+%F %H:%M'))"
  arecord -q -D "$DEVICE" -f S16_LE -c 1 -r 16000 \
    -d "$remaining" --max-file-time "$CHUNK_SECS" --use-strftime \
    "$night_dir/%Y-%m-%d_%H-%M-%S.wav" 2>> "$LOG"
  rc=$?

  [ "$(date +%s)" -ge "$end" ] && { log "recording ended"; exit 0; }
  [ -z "$(target_end)" ] && continue     # stopped: the loop top logs and exits
  log "arecord exited early (rc=$rc), mic unplugged? retrying in 30s"
  sleep 30
done
