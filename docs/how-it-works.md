# How it works

The Pi only records. Everything else happens on the Mac.

```
Pi (nightowl.local)                         Mac
record.sh  ── 02:00–12:00, 10-min WAVs ──►  pull.sh     rsync ~/nights → ~/NightOwl/nights
           (cron every 5 min + @reboot)     analyze.py  hum removal → YAMNet (Core ML) → bouts → report
```

Output lands in `~/NightOwl/reports/<night>/`: `report.html`, `summary.json`,
`frames.csv` (every 500 ms: levels plus scores for snoring, speech, gasp, snort,
cough, breathing, throat clearing, chewing, biting), and `clips/`.

## What it shares with the Dream Catcher iPhone app

- Same model file: `model/YAMNet.mlmodelc`, run CPU-only.
- Same framing as the app's `YAMNetClassifier.swift`: a frame every 500 ms, levels over the raw
  trailing 1 s, YAMNet over the trailing 0.975 s peak-normalized to 0.5 (≤ +30 dB).
- Counting: by default the AI decides (`detect_bouts` in `analyze.py`): frames with a
  snoring score at or above the shared threshold, speech filtered out, merged into bouts
  with the shared 30 s gap, and a bout needs at least four snores. The phone app's
  rules (`analysis/detector.py`) also require each snore to be 12 dB above the
  room, which this USB mic's electrical hum makes impossible; run `--strict` to use it
  anyway. Its result is always recorded in `summary.json` as `strictDetector`.
- Timestamps come from sample counts anchored at each capture start; a gap between
  files (recorder restarted) flushes the detector and re-anchors (Dream Catcher spec §0.2).

Deliberate differences from the phone:

- **Hum removal** (`denoise.remove_hum`, on by default, `--keep-hum` to skip) runs
  before levels, YAMNet and clips. A bedroom has several hums at once (60 Hz mains,
  a fan or motor, the USB chip's own lines at multiples of 62.5 Hz, small whines), so
  `find_tones` finds every line that holds its pitch for a whole file (machines do,
  snoring never does), pools the ones that recur across the night, and notches them.
  It took YAMNet from 200 to 446 recognised snore frames on night 1, with no false
  snoring on awake daytime audio.
- **Report**: a line graph of snores per minute with each bout shaded; click anywhere
  to hear that moment. Each bout gets one clip covering the whole bout (hiss and hum
  removed, turned up; `_original.wav` alongside), about 80 MB a night.
- Gasp candidates are listed for listening, not counted.

Setup and day-to-day running of the Pi are in [setup.md](setup.md).
