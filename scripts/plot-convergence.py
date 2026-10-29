"""Render the CSV output from TuningChecks; requires matplotlib and numpy."""
import argparse
import csv
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.ticker import FuncFormatter
import numpy as np

parser = argparse.ArgumentParser()
parser.add_argument("results", type=Path)
args = parser.parse_args()
with (args.results / "convergence.csv").open() as source:
    rows = list(csv.DictReader(source))
fig, axes = plt.subplots(1, 3, figsize=(15, 4.6))
for ax, scenario, title in zip(axes, ["ordinary", "unreliable", "long"],
                               ["Ordinary uncertainty", "High uncertainty", "Extended refinement"]):
    selected = [r for r in rows if r["scenario"] == scenario]
    steps = sorted({int(r["iteration"]) for r in selected})
    grouped = {step: [] for step in steps}
    for row in selected:
        grouped[int(row["iteration"])].append(float(row["error_db"]))
    median = [np.median(grouped[s]) for s in steps]
    lower = [np.percentile(grouped[s], 10) for s in steps]
    upper = [np.percentile(grouped[s], 90) for s in steps]
    ax.fill_between(steps, lower, upper, alpha=.2, color="#287a59", label="10th–90th percentile")
    ax.plot(steps, median, color="#287a59", label="Median across runs")
    ax.set(title=title, xlabel="A/B comparisons", ylabel="RMS curve error (dB)")
    ax.set_yscale("log")
    ax.yaxis.set_major_formatter(FuncFormatter(lambda value, _: f"{value:g}"))
    ax.yaxis.set_minor_formatter(FuncFormatter(lambda value, _: f"{value:g}"))
    ax.grid(alpha=.2)
axes[0].legend(fontsize=8)
fig.suptitle("LowShelf: learning a target EQ from noisy preferences", fontsize=15)
fig.tight_layout()
fig.savefig(args.results / "convergence.png", dpi=180)
plt.close(fig)
with (args.results / "curves.csv").open() as source:
    curves = list(csv.DictReader(source))
names = list(dict.fromkeys(r["target"] for r in curves))
fig, axes = plt.subplots(2, 4, figsize=(15, 7))
for ax, name in zip(axes.flat, names):
    selected = [r for r in curves if r["scenario"] == "ordinary" and r["target"] == name]
    for seed in sorted({r["seed"] for r in selected}, key=int):
        run = [r for r in selected if r["seed"] == seed]
        ax.plot([float(r["hz"]) for r in run], [float(r["matched_db"]) for r in run],
                color="#287a59", alpha=.3, linewidth=1)
    target = [r for r in selected if r["seed"] == "1"]
    ax.plot([float(r["hz"]) for r in target], [float(r["target_db"]) for r in target],
            color="#202936", linestyle="--", linewidth=1.8, label="Target")
    ax.plot([], [], color="#287a59", label="12 learned curves")
    ax.set_xscale("log")
    ax.set(title=name, xlabel="Frequency (Hz)", ylabel="Relative response (dB)")
    ax.grid(alpha=.2)
axes.flat[0].legend(fontsize=8)
fig.suptitle("Targets vs. learned EQ after 240 noisy comparisons", fontsize=15)
fig.tight_layout()
fig.savefig(args.results / "matched-curves.png", dpi=180)
