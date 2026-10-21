"""Event-study chart for displays, from outputs/e02_event_study.csv."""
import pathlib, pandas as pd, matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

ROOT = pathlib.Path(__file__).resolve().parents[1]
NAVY, GREY, ORANGE, INK, MUTED, BAND = "#1f2a44", "#a6a9b0", "#d9622b", "#1f2a44", "#4a4f5c", "#fcefe8"
plt.rcParams.update({"font.family": "Inter", "font.size": 13})

e = pd.read_csv(ROOT / "outputs/e02_event_study.csv").sort_values("sort_key")
v = e["uplift_vs_controls_pct"].tolist()                      # -4..-1, run 1, 2, 3+, +1..+4
x = [0, 1, 2, 3, 4.6, 5.6, 6.6, 8.2, 9.2, 10.2, 11.2]
lab = ["−4", "−3", "−2", "−1", "Week 1", "Week 2", "Week 3+", "+1", "+2", "+3", "+4"]
col = [GREY, GREY, GREY, NAVY, ORANGE, ORANGE, ORANGE, GREY, GREY, GREY, GREY]

fig, ax = plt.subplots(figsize=(11, 5.2), dpi=200)
ax.axvspan(3.95, 7.25, ymin=0, ymax=1, color=BAND, zorder=0)
ax.bar(x, v, width=0.62, color=col, zorder=2)
ax.axhline(0, color=GREY, lw=1, zorder=3)
for xi, vi, c in zip(x, v, col):
    run = c == ORANGE
    ax.text(xi, vi + (2 if vi >= 0 else -3), f"{vi:+.0f}%", ha="center", va="bottom" if vi >= 0 else "top",
            color="#b4501f" if run else MUTED, fontsize=14 if run else 13, fontweight="bold" if run else "normal")
ax.text(-0.3, 46, f"Already {v[3]:+.0f}% the week before:\ndisplays set up early and/or\nplaced where demand is rising",
        color=INK, fontsize=13, va="top")
ax.text(7.9, 36, "No evidence of a dip afterwards:\nclose to controls within 4 weeks", color=MUTED, fontsize=13, va="top")
for xc, t, c, w in [(1.5, "Weeks before the display starts", MUTED, "normal"), (5.6, "Display running", "#b4501f", "bold"),
                    (9.7, "Weeks after it ends", MUTED, "normal")]:
    ax.text(xc, -15, t, ha="center", color=c, fontweight=w, fontsize=13)
ax.set_xticks(x, lab, color=MUTED); ax.tick_params(length=0, pad=10)
ax.set_yticks([]); ax.set_ylim(-21, 75); ax.set_xlim(-0.6, 11.8)
for s in ax.spines.values(): s.set_visible(False)
ax.set_title("Sales against control stores, isolated display runs (method B)", loc="left", color=INK, fontsize=15, pad=14)
fig.tight_layout()
(ROOT / "charts").mkdir(exist_ok=True)
fig.savefig(ROOT / "charts/event_study_display.png", bbox_inches="tight", facecolor="white")
