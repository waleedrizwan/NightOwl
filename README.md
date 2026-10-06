# Night Owl 🦉

**A Raspberry Pi that sits on your nightstand, listens all night, and tells you in the morning exactly what happened while you slept.**

Snoring, gasps, snorts, coughs, talking, teeth grinding: Night Owl records the whole night and runs Google's YAMNet sound model over every half-second. In the morning you get an interactive report. It's a graph of your night, and you can click any moment to hear it.

No app store, no account, no cloud. The audio goes from the Pi to your own computer and nowhere else.

> Want something that just runs on your phone? Use the sister project **[Dream Catcher](https://github.com/waleedrizwan/DreamCatcher)**, a free snore tracker for iPhone. Night Owl is the hackable version: dedicated hardware, every sound class, every knob exposed.

## What you get every morning

- **Snores per minute** across the whole night, with each snoring bout shaded
- **Click to listen** anywhere on the graph. Each bout comes with a clip (hiss and hum removed, turned up, original alongside)
- **Gasp candidates** listed separately so you can listen to them yourself
- **`frames.csv`**: every 500 ms of the night, with loudness plus scores for snoring, speech, gasp, snort, cough, breathing, throat clearing, chewing and biting. Bring your own analysis.
- **`summary.json`**: the night's numbers in machine-readable form

## How it works

```
 Raspberry Pi (bedside)                          Your Mac
 ┌──────────────────────────┐   home Wi-Fi   ┌──────────────────────────────────┐
 │ USB mic → record.sh      │ ─────────────► │ pull.sh     rsync the night      │
 │ 16 kHz mono, 10-min WAVs │     rsync      │ analyze.py  hum removal → YAMNet │
 │ cron: every 5 min+reboot │                │             → snore bouts        │
 └──────────────────────────┘                │             → report.html        │
                                             └──────────────────────────────────┘
```

The Pi only records, so it can't crash halfway through a night doing ML. Everything clever happens on the Mac. One command in the morning (`analysis/morning.sh`) pulls the night, analyzes it and opens the report.

The detail behind it, like hum removal, framing and how bouts are counted, is in **[docs/how-it-works.md](docs/how-it-works.md)**.

## What you need

| | |
|---|---|
| Raspberry Pi | A Pi 3 or newer, running Raspberry Pi OS Lite |
| Microphone | Any USB microphone (16 kHz mono is all it records) |
| microSD | 32 GB holds about 30 nights (~800 MB a night) |
| Computer | A Mac on the same network. Analysis uses Core ML. |

## Quick start

Full walkthrough: **[docs/setup.md](docs/setup.md)**. The short version:

```sh
git clone https://github.com/waleedrizwan/NightOwl && cd NightOwl
recorder/install.sh        # copies the recorder to the Pi (host "nightowl") and schedules it
# …sleep…
analysis/morning.sh        # pull last night, analyze it, open the report
```

Settings are environment variables:

| Variable | Default | Where |
|---|---|---|
| `OWL_HOST` | `nightowl` | Mac: SSH host of the Pi |
| `OWL_DATA` | `~/NightOwl` | Mac: where nights and reports are stored |
| `OWL_TZ` | `America/Toronto` | Both: your timezone |
| `OWL_START` / `OWL_END` | `02:00` / `12:00` | Pi: recording window |
| `OWL_DEVICE` | `plughw:CARD=Device,DEV=0` | Pi: ALSA mic device (`arecord -l`) |

## Repository layout

| Path | What it is |
|---|---|
| `recorder/` | `record.sh` runs on the Pi; `install.sh` puts it there |
| `analysis/` | `morning.sh`, `pull.sh`, `analyze.py` (report), `denoise.py` (hum and hiss removal), `detector.py` (strict snore rules) |
| `model/` | YAMNet compiled for Core ML, plus `build/` to rebuild it from Google's weights yourself |
| `hardware/` | Hardware notes. `esp32-concept/` is the first, unbuilt design. |
| `docs/` | Setup and how it works |

## Roadmap

- [ ] Analysis **on the Pi itself** (TFLite YAMNet), so no Mac is needed
- [ ] **Live dashboard** served from the Pi at `nightowl.local`, so you can read last night on your phone
- [ ] **3D-printable case** (`hardware/case/`)
- [ ] **Trends** across nights: did the mouthguard or sleeping on your side help?
- [ ] Dedicated **teeth-grinding** and **gasp** detection on top of YAMNet's embeddings
- [ ] Linux and Windows analysis (ONNX or TFLite instead of Core ML)

## Privacy

Recordings are audio of you sleeping. They live on the Pi's SD card and in `~/NightOwl` on your Mac, outside the repo, and the `.gitignore` blocks `*.wav` and `nights/` just in case. Nothing is uploaded anywhere.

Night Owl is a personal sound log, not a medical device.

## Credits

- **YAMNet** by Google ([tensorflow/models](https://github.com/tensorflow/models/tree/master/research/audioset/yamnet), Apache 2.0), converted to Core ML in `model/build/`. See [NOTICE](NOTICE).
- Detection rules forked from **[Dream Catcher](https://github.com/waleedrizwan/DreamCatcher)**.

## License

[MIT](LICENSE) © 2026 Waleed Rizwan. The bundled YAMNet model stays under Apache 2.0.
