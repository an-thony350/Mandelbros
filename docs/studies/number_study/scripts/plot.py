#!/usr/bin/env python3

# make figs from the .npz file made by study.py

from __future__ import annotations

from pathlib import Path

import matplotlib as mpl
import matplotlib.pyplot as plt
import numpy as np
from matplotlib.colors import LogNorm, ListedColormap

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "data" / "study.npz"
PLOTS_DIR = ROOT / "plots"

# Consistent styling across all figures.
mpl.rcParams.update({
    "font.size": 10,
    "axes.titlesize": 11,
    "axes.labelsize": 10,
    "figure.dpi": 130,
    "savefig.dpi": 150,
    "savefig.bbox": "tight",
    "axes.grid": False,
})

HIGHLIGHT_FRAC = 22

def load():
    if not DATA.exists():
        raise SystemExit(f"error: {DATA} not found. Run scripts/study.py first.")
    return np.load(DATA, allow_pickle=False)


def iter_colormap():
    # Twilight-shifted with the inside (max_iter) value forced to black.
    base = plt.get_cmap("twilight_shifted", 256)
    colors = base(np.linspace(0, 1, 256))
    colors[-1] = [0, 0, 0, 1]
    return ListedColormap(colors)


def plot_heatmaps(npz):
    refs       = npz["refs"]
    images     = npz["images"]
    view_names = [str(n) for n in npz["view_names"]]
    zooms      = npz["view_zooms"]
    frac_bits  = npz["frac_bits"]
    max_iter   = int(npz["max_iter"])

    PLOTS_DIR.mkdir(exist_ok=True)
    iter_cmap = iter_colormap()

    for vi, name in enumerate(view_names):
        ref = refs[vi]
        n = len(frac_bits)

        fig, axes = plt.subplots(
            2, n,
            figsize=(2.0 * n + 1.2, 5.2),
            gridspec_kw={"hspace": 0.42, "wspace": 0.08,
                         "left": 0.04, "right": 0.92,
                         "top": 0.86, "bottom": 0.06},
        )

        im_top = None
        im_bot = None

        for i, f in enumerate(frac_bits):
            img = images[vi, i]
            diff = np.abs(img.astype(np.int64) - ref.astype(np.int64))

            ax = axes[0, i]
            im_top = ax.imshow(img, cmap=iter_cmap, vmin=0, vmax=max_iter,
                               interpolation="nearest")
            title = f"Q4.{f}"
            if int(f) == HIGHLIGHT_FRAC:
                title += "  ★"
                for spine in ax.spines.values():
                    spine.set_edgecolor("#2a9d8f")
                    spine.set_linewidth(2.0)
            ax.set_title(title, pad=4)
            ax.set_xticks([]); ax.set_yticks([])

            ax = axes[1, i]
            # Diff in log scale to handle the huge dynamic range. +1 so exact matches don't disappear
            im_bot = ax.imshow(diff + 1, cmap="inferno",
                               norm=LogNorm(vmin=1, vmax=max(2, max_iter)),
                               interpolation="nearest")
            err_frac = float(np.mean(diff > 1))
            ax.set_title(f"|Δiter|   ({err_frac*100:.2f}% > 1)", pad=4)
            ax.set_xticks([]); ax.set_yticks([])
            if int(f) == HIGHLIGHT_FRAC:
                for spine in ax.spines.values():
                    spine.set_edgecolor("#2a9d8f")
                    spine.set_linewidth(2.0)

        cax_top = fig.add_axes([0.935, 0.49, 0.012, 0.34])
        fig.colorbar(im_top, cax=cax_top, label="iter count")
        cax_bot = fig.add_axes([0.935, 0.08, 0.012, 0.34])
        fig.colorbar(im_bot, cax=cax_bot, label="|Δiter| + 1")

        fig.suptitle(f"{name} (zoom {zooms[vi]:g}×)   —   "
                     "fixed-point vs IEEE double",
                     fontsize=13, y=0.97)

        out = PLOTS_DIR / f"heatmap_{name}.png"
        fig.savefig(out)
        plt.close(fig)
        print(f"  wrote {out}")


def _bar_chart(metric_key, metric_label, title, filename, npz):
    # Shared layout for the two grouped bar charts
    refs       = npz["refs"]
    images     = npz["images"]
    view_names = [str(n) for n in npz["view_names"]]
    zooms      = npz["view_zooms"]
    frac_bits  = list(npz["frac_bits"])
    max_iter   = int(npz["max_iter"])

    # Compute the metric
    data = {}
    for vi, name in enumerate(view_names):
        ref = refs[vi]
        row = []
        for fi, f in enumerate(frac_bits):
            img = images[vi, fi]
            diff = np.abs(img.astype(np.int64) - ref.astype(np.int64))
            if metric_key == "err_gt1":
                row.append(float(np.mean(diff > 1)))
            elif metric_key == "class_diff":
                row.append(float(np.mean((img == max_iter) != (ref == max_iter))))
            else:
                raise ValueError(metric_key)
        data[name] = row

    fig, ax = plt.subplots(figsize=(10.5, 5.5))

    # Highlight the Q4.22 column.
    if HIGHLIGHT_FRAC in frac_bits:
        idx = frac_bits.index(HIGHLIGHT_FRAC)
        ax.axvspan(idx - 0.45, idx + 0.45, color="#2a9d8f", alpha=0.10,
                   zorder=0, label=f"Q4.{HIGHLIGHT_FRAC} (chosen)")

    x = np.arange(len(frac_bits))
    n_views = len(view_names)
    bar_w = 0.78 / n_views
    palette = plt.get_cmap("viridis")(np.linspace(0.15, 0.85, n_views))

    for i, name in enumerate(view_names):
        offset = (i - (n_views - 1) / 2) * bar_w
        # Floor very small values so they're still visible on log axis.
        vals = np.array(data[name])
        plotvals = np.where(vals < 1e-5, 1e-5, vals)
        ax.bar(x + offset, plotvals, bar_w,
               label=f"{name} ({zooms[i]:g}×)" if i < len(zooms) else name,
               color=palette[i], edgecolor="white", linewidth=0.4)

    ax.axhline(0.01, color="crimson", linestyle="--", linewidth=1.2,
               alpha=0.7, label="1% threshold")

    ax.set_xticks(x)
    ax.set_xticklabels([f"Q4.{f}" for f in frac_bits])
    ax.set_xlabel("Fractional bits")
    ax.set_ylabel(metric_label)
    ax.set_yscale("log")
    ax.set_ylim(1e-5, 1.2)
    ax.set_title(title)
    ax.legend(loc="lower left", fontsize=8.5, framealpha=0.95, ncol=2)
    ax.grid(True, which="major", axis="y", alpha=0.3)
    ax.set_axisbelow(True)

    out = PLOTS_DIR / filename
    fig.tight_layout()
    fig.savefig(out)
    plt.close(fig)
    print(f"wrote {out}")


def plot_error_vs_precision(npz):
    _bar_chart(
        "err_gt1",
        "Fraction of pixels with |Δiter| > 1",
        "Strict iteration-count error vs precision",
        "error_vs_precision.png",
        npz,
    )


def plot_classification_error(npz):
    _bar_chart(
        "class_diff",
        "Fraction of pixels with different inside/outside classification",
        "Classification error vs precision",
        "classification_error.png",
        npz,
    )


def plot_summary_heatmap(npz):
    refs      = npz["refs"]
    images    = npz["images"]
    view_names = [str(n) for n in npz["view_names"]]
    zooms     = npz["view_zooms"]
    frac_bits = list(npz["frac_bits"])
    max_iter  = int(npz["max_iter"])

    n_views = len(view_names)
    n_fracs = len(frac_bits)
    err = np.zeros((n_views, n_fracs))
    cls = np.zeros((n_views, n_fracs))
    for vi in range(n_views):
        ref = refs[vi]
        for fi in range(n_fracs):
            img = images[vi, fi]
            diff = np.abs(img.astype(np.int64) - ref.astype(np.int64))
            err[vi, fi] = float(np.mean(diff > 1))
            cls[vi, fi] = float(np.mean((img == max_iter) != (ref == max_iter)))

    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(12, 4.8))

    for ax, data, title in [(ax1, err, "|Δiter| > 1"),
                            (ax2, cls, "Classification differs")]:
        # Floor for log scale.
        data_floored = np.where(data < 1e-5, 1e-5, data)
        im = ax.imshow(data_floored, cmap="inferno",
                       norm=LogNorm(vmin=1e-5, vmax=1),
                       aspect="auto", interpolation="nearest")
        ax.set_xticks(range(n_fracs))
        ax.set_xticklabels([f"Q4.{f}" for f in frac_bits])
        ax.set_yticks(range(n_views))
        ax.set_yticklabels([f"{name}\n({zooms[i]:g}×)"
                            for i, name in enumerate(view_names)])
        ax.set_xlabel("Fractional bits")
        ax.set_title(f"Fraction of pixels where {title}")
        for i in range(n_views):
            for j in range(n_fracs):
                v = data[i, j]
                if v < 0.001:
                    txt = f"{v*100:.2f}%" if v > 0 else "0%"
                else:
                    txt = f"{v*100:.1f}%"
                color = "white" if v > 0.05 else "lightgray"
                ax.text(j, i, txt, ha="center", va="center",
                        color=color, fontsize=8.5)

    fig.suptitle("Fixed-point precision vs zoom — error summary",
                 fontsize=13)
    fig.tight_layout(rect=[0, 0, 1, 0.96])
    out = PLOTS_DIR / "summary.png"
    fig.savefig(out)
    plt.close(fig)
    print(f"wrote {out}")


def main():
    PLOTS_DIR.mkdir(exist_ok=True)
    npz = load()
    plot_heatmaps(npz)
    plot_error_vs_precision(npz)
    plot_classification_error(npz)
    plot_summary_heatmap(npz)


if __name__ == "__main__":
    main()