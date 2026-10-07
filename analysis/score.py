"""Snore Score: one number per night, 0 (silent) to 100 (snored all night).

    score = 5 × (minutes of snoring per hour recorded) + 1 per possible gasp

Per hour, so a long night isn't punished for being long. Bands:
0–9 quiet · 10–24 light · 25–49 moderate · 50+ heavy.
"""

BANDS = [(10, "quiet"), (25, "light"), (50, "moderate"), (101, "heavy")]


def snore_score(s: dict) -> int:
    hours = max(s["recordedMs"], 1) / 3_600_000
    per_hour = s["snoreMs"] / 60_000 / hours
    return min(100, round(5 * per_hour + len(s.get("gaspCandidates", []))))


def band(score: int) -> str:
    return next(name for top, name in BANDS if score < top)
