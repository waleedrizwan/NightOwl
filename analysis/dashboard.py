#!/usr/bin/env python3
"""Every night on one page: Snore Score trend, when in the night you snore, and links
to each night's report. Reads <data>/reports/*/summary.json, writes <data>/dashboard.html.
"""
import argparse
import html
import json
import os
import subprocess
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

from score import band, snore_score

TZ = ZoneInfo(os.environ.get("OWL_TZ", "America/Toronto"))
DATA = Path(os.environ.get("OWL_DATA", Path.home() / "NightOwl"))
BAND_COLOR = {"quiet": "var(--quiet)", "light": "var(--light)",
              "moderate": "var(--moderate)", "heavy": "var(--loud)"}
HEAT_FROM, HEAT_TO = 0, 13          # heatmap columns: hours 00:00–12:59 local


def hm(ms: int) -> str:
    m = round(ms / 60_000)
    return f"{m // 60} h {m % 60:02d} m" if m >= 60 else f"{m} m"


def load(data: Path) -> list[dict]:
    nights = []
    for f in sorted((data / "reports").glob("*/summary.json")):
        s = json.loads(f.read_text())
        s["dir"] = f.parent.name
        s["score"] = snore_score(s)
        s["band"] = band(s["score"])
        hours = [0.0] * (HEAT_TO - HEAT_FROM)      # minutes of snoring per clock hour
        for b in s["timeline"]:
            h = datetime.fromtimestamp(b["startMs"] / 1000, TZ).hour
            if HEAT_FROM <= h < HEAT_TO:
                hours[h - HEAT_FROM] += b["snoreSec"] / 60
        s["hours"] = hours
        nights.append(s)
    return nights


def compact(s: dict) -> dict:
    """What the phone app needs for one night (no per-frame data)."""
    return {
        "night": s["night"], "dir": s["dir"], "score": s["score"], "band": s["band"],
        "startMs": s["startMs"], "endMs": s["endMs"], "recordedMs": s["recordedMs"],
        "snoreMs": s["snoreMs"], "percentOfNight": s["percentOfNight"],
        "snoreByHour": [{"hour": HEAT_FROM + i, "minutes": round(m, 2)} for i, m in enumerate(s["hours"])],
        "timeline": [{"startMs": b["startMs"], "snoreSec": b["snoreSec"]} for b in s["timeline"]],
        "bouts": [{"startMs": e["startMs"], "endMs": e["endMs"], "sounds": e["sounds"],
                   "maxScore": e["maxScore"], "clip": e.get("clip")} for e in s["episodes"]],
        "gasps": [{"tMs": g["tMs"], "score": g["score"], "clip": g.get("clip")}
                  for g in s.get("gaspCandidates", [])],
    }


def label(s: dict, fmt="%a %b %-d") -> str:
    return datetime.strptime(s["night"], "%Y-%m-%d").strftime(fmt)


def score_chart(nights: list[dict]) -> str:
    w, h, pad = 720, 220, 28
    n = len(nights)
    bw = min(48, (w - pad) / n * 0.7)
    step = (w - pad) / n
    out = [f'<svg viewBox="0 0 {w} {h + 24}" role="img" aria-label="Snore Score per night">']
    for y in (25, 50, 75, 100):
        yy = h - y / 100 * (h - 10)
        out.append(f'<line x1="{pad}" x2="{w}" y1="{yy:.1f}" y2="{yy:.1f}" class="grid"/>'
                   f'<text x="{pad - 6}" y="{yy + 4:.1f}" class="axis" text-anchor="end">{y}</text>')
    pts = []
    for i, s in enumerate(nights):
        x = pad + step * i + (step - bw) / 2
        bh = max(2, s["score"] / 100 * (h - 10))
        out.append(f'<a href="reports/{s["dir"]}/report.html"><rect x="{x:.1f}" y="{h - bh:.1f}" '
                   f'width="{bw:.1f}" height="{bh:.1f}" rx="3" fill="{BAND_COLOR[s["band"]]}">'
                   f'<title>{label(s)}: {s["score"]} ({s["band"]})</title></rect></a>'
                   f'<text x="{x + bw / 2:.1f}" y="{h - bh - 5:.1f}" class="val" text-anchor="middle">{s["score"]}</text>')
        if n <= 14 or i % max(1, n // 14) == 0:
            out.append(f'<text x="{x + bw / 2:.1f}" y="{h + 16}" class="axis" text-anchor="middle">'
                       f'{label(s, "%b %-d")}</text>')
        recent = [t["score"] for t in nights[max(0, i - 6):i + 1]]
        pts.append(f"{x + bw / 2:.1f},{h - sum(recent) / len(recent) / 100 * (h - 10):.1f}")
    if n >= 3:
        out.append(f'<polyline points="{" ".join(pts)}" class="avg"/>')
    out.append(f'<line x1="{pad}" x2="{w}" y1="{h}" y2="{h}" class="base"/></svg>')
    return "".join(out)


def heatmap(nights: list[dict]) -> str:
    cols = HEAT_TO - HEAT_FROM
    cw, rh, left, top = 44, 24, 92, 20
    w, h = left + cols * cw, top + rh * len(nights)
    out = [f'<svg viewBox="0 0 {w} {h + 4}" role="img" aria-label="Snoring by hour of the night">']
    for c in range(cols):
        out.append(f'<text x="{left + c * cw + cw / 2}" y="13" class="axis" text-anchor="middle">'
                   f'{(HEAT_FROM + c) % 24:02d}</text>')
    for r, s in enumerate(reversed(nights)):
        y = top + r * rh
        out.append(f'<text x="{left - 8}" y="{y + rh / 2 + 4}" class="axis" text-anchor="end">{label(s)}</text>')
        start_h = datetime.fromtimestamp(s["startMs"] / 1000, TZ).hour
        end_h = datetime.fromtimestamp(s["endMs"] / 1000, TZ).hour
        for c, m in enumerate(s["hours"]):
            hour = HEAT_FROM + c
            recorded = start_h <= hour <= end_h
            op = min(1, 0.12 + m / 20) if m >= 0.5 else 0
            fill = "var(--loud)" if m >= 0.5 else ("var(--cell)" if recorded else "transparent")
            out.append(f'<rect x="{left + c * cw + 1}" y="{y + 1}" width="{cw - 2}" height="{rh - 2}" rx="3" '
                       f'fill="{fill}" fill-opacity="{op if m >= 0.5 else 1}">'
                       f'<title>{label(s)} {hour:02d}:00 — {m:.1f} min snoring</title></rect>')
    out.append("</svg>")
    return "".join(out)


def render(nights: list[dict]) -> str:
    last = nights[-1]
    week = nights[-7:]
    avg = round(sum(s["score"] for s in week) / len(week))
    best = min(nights, key=lambda s: s["score"])
    prev = nights[-2]["score"] if len(nights) > 1 else None
    delta = "" if prev is None else (f'{"▲" if last["score"] > prev else "▼"} {abs(last["score"] - prev)} vs the night before'
                                     if last["score"] != prev else "same as the night before")
    rows = "".join(
        f'<tr><td><a href="reports/{s["dir"]}/report.html">{label(s)}</a></td>'
        f'<td class="num"><span class="pill" style="background:{BAND_COLOR[s["band"]]}">{s["score"]}</span></td>'
        f'<td>{s["band"]}</td><td class="num">{hm(s["recordedMs"])}</td>'
        f'<td class="num">{hm(s["snoreMs"]) if s["snoreMs"] else "—"}</td>'
        f'<td class="num">{s["percentOfNight"]}%</td><td class="num">{len(s["episodes"])}</td>'
        f'<td class="num">{len(s.get("gaspCandidates", []))}</td></tr>'
        for s in reversed(nights))
    tiles = [
        ("Last night", f'{last["score"]}', f'{last["band"]} · {delta}'),
        ("7-night average", f"{avg}", f"{band(avg)} · over {len(week)} night{'s' * (len(week) > 1)}"),
        ("Snoring last night", hm(last["snoreMs"]) if last["snoreMs"] else "none",
         f'{last["percentOfNight"]}% of {hm(last["recordedMs"])}'),
        ("Quietest night", f'{best["score"]}', label(best)),
    ]
    tile_html = "".join(f'<div class="tile"><div class="k">{html.escape(k)}</div><div class="v">{html.escape(v)}</div>'
                        f'<div class="s">{html.escape(sub)}</div></div>' for k, v, sub in tiles)
    return f"""<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Night Owl</title>
<style>
:root {{ --bg:#fbfaf8; --card:#fff; --ink:#1d1d1f; --muted:#6e6e73; --line:#e6e4df; --cell:#efede8;
  --quiet:#8cc7a1; --light:#f3cd8f; --moderate:#e5812e; --loud:#9e2a14; --avg:#3a6fd8; }}
@media (prefers-color-scheme: dark) {{ :root {{ --bg:#141416; --card:#1d1d20; --ink:#f2f2f4; --muted:#9a9aa0;
  --line:#2e2e33; --cell:#26262a; --quiet:#3f8f5f; --light:#a8834f; --moderate:#d9782a; --loud:#ff4d3d; --avg:#7aa2ff; }} }}
* {{ box-sizing:border-box }}
body {{ margin:0; background:var(--bg); color:var(--ink); font:15px/1.45 -apple-system,system-ui,sans-serif }}
main {{ max-width:920px; margin:0 auto; padding:28px 16px 48px }}
h1 {{ font-size:26px; margin:0 0 2px }} h2 {{ font-size:16px; margin:0 0 12px }}
.sub, .s, .k, .axis, .note {{ color:var(--muted) }}
.tiles {{ display:grid; grid-template-columns:repeat(auto-fit,minmax(190px,1fr)); gap:12px; margin:20px 0 }}
.tile, .card {{ background:var(--card); border:1px solid var(--line); border-radius:12px; padding:14px 16px }}
.card {{ margin-bottom:16px; overflow-x:auto }}
.k {{ font-size:13px }} .v {{ font-size:30px; font-weight:650; font-variant-numeric:tabular-nums }} .s {{ font-size:13px }}
svg {{ width:100%; height:auto; display:block; min-width:520px }}
svg text {{ font-size:11px; fill:var(--muted) }} svg .val {{ fill:var(--ink); font-weight:600 }}
.grid {{ stroke:var(--line) }} .base {{ stroke:var(--muted) }}
.avg {{ fill:none; stroke:var(--avg); stroke-width:2; stroke-dasharray:4 3 }}
table {{ width:100%; border-collapse:collapse; font-size:14px; min-width:560px }}
th, td {{ text-align:left; padding:7px 8px; border-bottom:1px solid var(--line) }}
th {{ color:var(--muted); font-weight:500 }} .num {{ text-align:right; font-variant-numeric:tabular-nums }}
.pill {{ display:inline-block; min-width:32px; text-align:center; border-radius:10px; padding:1px 8px; color:#fff; font-weight:600 }}
a {{ color:inherit }} .legend span {{ display:inline-block; width:10px; height:10px; border-radius:2px; margin:0 4px 0 12px }}
.note {{ font-size:13px; margin-top:8px }}
</style></head><body><main>
<h1>Night Owl</h1>
<div class="sub">{len(nights)} night{'s' * (len(nights) > 1)} tracked · {label(nights[0], "%b %-d")} – {label(last, "%b %-d")}</div>
<div class="tiles">{tile_html}</div>
<div class="card"><h2>Snore Score by night</h2>{score_chart(nights)}
<div class="note legend">Lower is quieter.<span style="background:var(--quiet)"></span>quiet 0–9
<span style="background:var(--light)"></span>light 10–24<span style="background:var(--moderate)"></span>moderate 25–49
<span style="background:var(--loud)"></span>heavy 50+{' · dashed line: 7-night average' if len(nights) >= 3 else ''}</div></div>
<div class="card"><h2>When you snore</h2>{heatmap(nights)}
<div class="note">Minutes of snoring in each clock hour. Darker = more. Grey = recorded, nothing heard.</div></div>
<div class="card"><h2>Every night</h2><table>
<tr><th>Night of</th><th class="num">Score</th><th>Band</th><th class="num">Recorded</th><th class="num">Snoring</th>
<th class="num">%</th><th class="num">Bouts</th><th class="num">Gasps</th></tr>{rows}</table>
<div class="note">Snore Score = 5 × minutes of snoring per hour recorded + 1 per possible gasp, capped at 100.</div></div>
</main></body></html>"""


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--data", type=Path, default=DATA)
    ap.add_argument("--no-open", action="store_true")
    a = ap.parse_args()
    nights = load(a.data)
    if not nights:
        raise SystemExit(f"no analyzed nights in {a.data / 'reports'}")
    out = a.data / "dashboard.html"
    out.write_text(render(nights))
    print(f"  dashboard: {out} ({len(nights)} nights, last score {nights[-1]['score']})")
    if not a.no_open:
        subprocess.run(["open", str(out)], check=False)


if __name__ == "__main__":
    main()
