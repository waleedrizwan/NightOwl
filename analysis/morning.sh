#!/usr/bin/env bash
# One command after you wake up: pull last night from the Pi, analyze it, open the report.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

# The 12:15 run and the app's "I'm up" (wake.sh) can overlap: take turns.
if [ -z "${OWL_MORNING_LOCKED:-}" ]; then
  mkdir -p "${OWL_DATA:-$HOME/NightOwl}"
  OWL_MORNING_LOCKED=1 exec lockf -t 3600 "${OWL_DATA:-$HOME/NightOwl}/.morning.lock" "$0" "$@"
fi

if [ ! -x "$HERE/.venv/bin/python" ]; then
  echo "Setting up the analysis environment (one time)…"
  uv venv --python 3.11 "$HERE/.venv" -q
  uv pip install --python "$HERE/.venv/bin/python" -q -r "$HERE/requirements.txt"
fi

"$HERE/pull.sh"
"$HERE/.venv/bin/python" "$HERE/analyze.py" --no-open "$@"
"$HERE/.venv/bin/python" "$HERE/dashboard.py"
"$HERE/.venv/bin/python" "$HERE/publish.py"
"$HERE/.venv/bin/python" "$HERE/notify.py"
