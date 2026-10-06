# Night Owl
Raspberry Pi with a USB mic next to my bed. It records the whole night, and in the morning my Mac runs it through Google's YAMNet. Out comes a report showing when I snored, for how long, and any moments that sounded like gasping.

Here's a real night of mine:
[![My night, October 5](docs/example/night.png)](https://waleedrizwan.github.io/NightOwl/docs/example/)

**[Open the full report →](https://waleedrizwan.github.io/NightOwl/docs/example/)** (the real one lets me click anywhere on the graph and hear that moment; I left the audio out of this copy)

## How it works

1. The Pi records from 2 am to noon in 10-minute chunks.
2.  run `analysis/morning.sh`. It copies the night over, cleans up the background hum, finds the snoring and opens the report.

Nothing goes to the cloud. It's just my Pi and my laptop.

Want to build one? Everything is in **[docs/setup.md](docs/setup.md)**. All you need is a Pi, any USB mic and a Mac.

## What's next
- [ ] Blood oxygen, from a pulse oximeter on my finger or wrist
- [ ] An infrared camera, to watch my breathing and sleeping position in the dark
- [ ] Run everything on the Pi, so there's no Mac step
- [ ] A dashboard I can check on my phone in the morning
- [ ] A 3D-printed case
- [ ] Trends over weeks: does sleeping on my side actually help?

---
