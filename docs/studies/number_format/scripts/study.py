#!/usr/bin/env python3
"""
Render Mandelbrot iteration-count images at multiple (view, precision)
combinations and save them as a single .npz 
"""

from __future__ import annotations

import argparse
import csv
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
BIN = ROOT / "build" / "fixed_mandelbrot"
DATA_DIR = ROOT / "data"
PLOTS_DIR = ROOT / "plots"

# Configuration 

# Resolution. Bump to 768x768 for final report figures.
WIDTH, HEIGHT = 384, 384
MAX_ITER = 512

# (label, centre_r, centre_i, zoom). Picked to exercise both shallow and
# deep zooms on the boundary, since that's where precision matters.
VIEWS = [
    ("overview",       -0.5,             0.0,             1.0),
    ("seahorse_100x",  -0.743643887037,  0.131825904205,  100.0),
    ("seahorse_1000x", -0.743643887037,  0.131825904205,  1000.0),
    ("seahorse_1e4x",  -0.743643887037,  0.131825904205,  10000.0),
    ("seahorse_1e5x",  -0.743643887037,  0.131825904205,  100000.0),
]

# Fractional-bit widths to compare. Q4.22 is the proposed datapath.
FRAC_BITS = [12, 16, 18, 22, 26, 32]

@dataclass(frozen=True)
class View:
    name: str
    center_r: float
    center_i: float
    zoom: float


def render(view: View, frac: int, width: int, height: int, max_iter: int,
           out_path: Path) -> np.ndarray:
    # Invoke the C renderer and return the image as int32 ndarray
    if not BIN.exists():
        sys.exit(f"error: {BIN} not built. Run `make build` first.")
    subprocess.run(
        [str(BIN), repr(view.center_r), repr(view.center_i), repr(view.zoom),
         str(width), str(height), str(max_iter), str(frac), str(out_path)],
        check=True,
    )
    return np.fromfile(out_path, dtype=np.int32).reshape(height, width)


def run_study(views, frac_bits, width, height, max_iter):
    # Run every (view, frac) combination plus the double reference per view
    n_views = len(views)
    n_fracs = len(frac_bits)
    refs   = np.zeros((n_views, height, width), dtype=np.int32)
    images = np.zeros((n_views, n_fracs, height, width), dtype=np.int32)

    with tempfile.TemporaryDirectory() as td:
        td = Path(td)
        for vi, v in enumerate(views):
            print(f"[{v.name}]  reference (double) ...", flush=True)
            refs[vi] = render(v, 0, width, height, max_iter, td / "ref.bin")
            for fi, f in enumerate(frac_bits):
                print(f"           frac={f:>3} ...", flush=True)
                images[vi, fi] = render(v, f, width, height, max_iter, td / "img.bin")

    return refs, images


def summary_table(views, frac_bits, refs, images, max_iter):
    # Compute per-(view, frac) summary statistics.
    rows = []
    for vi, v in enumerate(views):
        ref = refs[vi]
        ref_inside = (ref == max_iter)
        for fi, f in enumerate(frac_bits):
            img = images[vi, fi]
            diff = np.abs(img.astype(np.int64) - ref.astype(np.int64))
            err_gt1 = float(np.mean(diff > 1))
            img_inside = (img == max_iter)
            class_diff = float(np.mean(img_inside != ref_inside))
            rows.append({
                "view": v.name,
                "zoom": v.zoom,
                "frac_bits": f,
                "err_gt1_frac": err_gt1,
                "class_diff_frac": class_diff,
                "max_diff": int(diff.max()),
            })
    return rows


def write_csv(rows, path):
    fieldnames = ["view", "zoom", "frac_bits", "err_gt1_frac",
                  "class_diff_frac", "max_diff"]
    with open(path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fieldnames)
        w.writeheader()
        for r in rows:
            w.writerow(r)


def print_table(rows, frac_bits):
    # Pretty-print the summary, mirroring the original study output
    views = []
    for r in rows:
        if r["view"] not in views:
            views.append(r["view"])

    header = "view".ljust(20) + "".join(f"{f:>10}" for f in frac_bits)
    print("\nfraction-of-pixels-with-|Δiter|>1:")
    print(header)
    print("-" * len(header))
    for v in views:
        line = v.ljust(20)
        for f in frac_bits:
            val = next(r["err_gt1_frac"] for r in rows
                       if r["view"] == v and r["frac_bits"] == f)
            line += f"{val:>10.4f}"
        print(line)

    print("\nfraction-of-pixels-with-different-classification:")
    print(header)
    print("-" * len(header))
    for v in views:
        line = v.ljust(20)
        for f in frac_bits:
            val = next(r["class_diff_frac"] for r in rows
                       if r["view"] == v and r["frac_bits"] == f)
            line += f"{val:>10.4f}"
        print(line)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--smoke", action="store_true",
                    help="Run a fast subset for CI / smoke-testing.")
    args = ap.parse_args()

    if args.smoke:
        views = [View(*v) for v in VIEWS[:2]]
        frac_bits = [12, 22, 32]
        width = height = 96
        max_iter = 128
    else:
        views = [View(*v) for v in VIEWS]
        frac_bits = list(FRAC_BITS)
        width, height = WIDTH, HEIGHT
        max_iter = MAX_ITER

    DATA_DIR.mkdir(exist_ok=True)
    PLOTS_DIR.mkdir(exist_ok=True)

    refs, images = run_study(views, frac_bits, width, height, max_iter)
    rows = summary_table(views, frac_bits, refs, images, max_iter)

    # Save everything plot.py needs.
    np.savez_compressed(
        DATA_DIR / "study.npz",
        refs=refs,
        images=images,
        view_names=np.array([v.name for v in views]),
        view_centers_r=np.array([v.center_r for v in views]),
        view_centers_i=np.array([v.center_i for v in views]),
        view_zooms=np.array([v.zoom for v in views]),
        frac_bits=np.array(frac_bits, dtype=np.int32),
        width=width, height=height, max_iter=max_iter,
    )
    print(f"\nwrote {DATA_DIR/'study.npz'}")

    write_csv(rows, PLOTS_DIR / "error_table.csv")
    print(f"wrote {PLOTS_DIR/'error_table.csv'}")

    print_table(rows, frac_bits)


if __name__ == "__main__":
    main()