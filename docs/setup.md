# Setup

About 30 minutes, most of it waiting for the SD card to flash.

## 1. Flash the Pi

1. Install [Raspberry Pi Imager](https://www.raspberrypi.com/software/) and pick **Raspberry Pi OS Lite** (no desktop needed).
2. In the Imager's settings:
   - **Hostname:** `nightowl`
   - **Enable SSH** with your public key
   - Your **Wi-Fi** network
   - A username of your choice
3. Flash the card, put it in the Pi, plug in the USB mic, and power it on.

Check you can reach it from the Mac:

```sh
ssh nightowl.local
```

If your username on the Pi differs from your Mac's, add this to `~/.ssh/config` on the Mac so `ssh nightowl` works on its own:

```
Host nightowl
  HostName nightowl.local
  User <your-pi-username>
```

## 2. Find the mic

On the Pi:

```sh
arecord -l
```

Most USB mics show up as `card 1: Device`, which matches the default `OWL_DEVICE=plughw:CARD=Device,DEV=0`. If yours is named differently, use `plughw:CARD=<name>,DEV=0`.

A 5-second test recording:

```sh
arecord -D plughw:CARD=Device,DEV=0 -f S16_LE -c 1 -r 16000 -d 5 test.wav
```

## 3. Install the recorder

From the repo on the Mac:

```sh
recorder/install.sh
```

This copies `record.sh` to `~/nightowl/` on the Pi and adds two cron entries: every 5 minutes, and on boot. Outside the recording window the script exits immediately. Inside it, the script records 10-minute WAVs into `~/nights/<date>/` until the window ends.

To change the window or the mic, edit the defaults at the top of `recorder/record.sh` and run `install.sh` again.

- **Off switch:** unplug the mic. The recorder retries every 30 s and picks up again when the mic is back.
- **Log:** `~/nightowl/record.log` on the Pi.
- **Clock:** a Pi has no battery-backed clock, so the recorder waits for network time before it names any file.

## 4. Set up analysis on the Mac

You need [uv](https://docs.astral.sh/uv/) (`brew install uv`). The first run of `morning.sh` creates `analysis/.venv` and installs `coremltools` and `numpy`.

```sh
analysis/morning.sh             # the most recent night
analysis/morning.sh 2026-10-05  # a specific night
```

Reports land in `~/NightOwl/reports/<night>/`. Useful flags for `analyze.py` (pass them through `morning.sh`):

| Flag | Effect |
|---|---|
| `--strict` | Count with the strict detector, which needs snores 12 dB above the room |
| `--keep-hum` | Skip hum removal |
| `--param KEY=VALUE` | Override a detector parameter, e.g. `--param GATE_CLAMP_LO=-70` |
| `--no-open` | Don't open the report in the browser |
