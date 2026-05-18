# Number-format study

Empirical investigation of fixed-point precision for the hardware side
iteration core. Justifies the **Q4.22** datapath choice 
---
## 1. Verdict

**Q4.22 is the right choice for the FractalScope datapath.**

Q4.22 keeps disagreement at **0.02% – 3.3% of pixels** across the full 1× → 100,000× zoom range tested. The strict iter-count metric makes the error look much worse (up to 60% at 100,000×) but that metric counts boundary speckle that is invisible to a human looking at the resulting image.

Practical consequences:
- The "precision-limit" demo (Scene 7 of the plan) reliably starts showing visible quantisation around **10,000× zoom** and is unmistakable by **100,000×**. 
- Visible block-quantisation in the iteration-count image first appears at Q4.18 / 10,000× zoom

---

## 2. Why was this study needed

The Mandelbrot iteration `z ← z² + c` is mathematically defined on the
real numbers. Hardware has no real numbers, every datapath represents
numbers with finitely many bits. Picking that bit-budget is a four-way
trade-off:

| Pull | Effect |
|---|---|
| **Wider numbers** | Better visual fidelity, deeper zoom before quantisation. |
| **Narrower numbers** | More iteration cores fit in the same DSP budget → higher frame rate. |
| **More integer bits** | More headroom against overflow. |
| **More fractional bits** | Finer pixel-step at high zoom. |

This study exists to **empirically choose** a precision, before any HDL is written. We want to know: at the precisions we're choosing between, how much does the rendered image actually disagree with infinite precision (well, double, which is close enough i guess)? And does the disagreement matter visually?

---

## 3. How we derived "Q4.22" specifically

Two separate analyses, one for each side of the dot.

### 3a. Integer bits: why 3 + 1 sign = "4"

The Mandelbrot iteration is `z ← z² + c`. The escape test is `|z|² > 4`, i.e. `|z| > 2`. So as long as a point hasn't yet escaped, `|z|` stays within ±2 and the squares stay within ±4. The first iteration *after* escape can briefly produce larger values — a just-escaped point with `|z| ~ 2.5` gives `z² + c` near 6 before the next escape check catches it.

To leave headroom we want the integer range to comfortably exceed 6. **±8** is the smallest power-of-two range that fits, requiring 3 magnitude bits plus 1 sign bit. Going wider wastes precision; going narrower causes the squared value to wrap around silently and produce garbage iteration counts.

(Other fractal variants have the same magnitude analysis. While I have just done Mandelbrot now, this idea will have to be revisited later in the project when we add to the library.)

### 3b. Fractional bits: why 22

The image is rendered by scanning `c` across a rectangular region of the complex plane. At zoom factor `Z` and width 1280 pixels, the spacing between adjacent pixels' `c` values is roughly

```
dx = 4 / (1280 × Z)
```

If `dx` is smaller than your fractional resolution `2⁻ᶠ`, then two adjacent pixels round to the *same* representable `c` value and the image shows "blocks" instead of detail. The break-even is

```
2⁻ᶠ ≈ dx          ⇒          F ≈ log₂(640 × Z)
```

| Zoom Z   | Required F |  
|----------|-----------:|
| 1×       | 10         | 
| 100×     | 17         | 
| 1,000×   | 20         | 
| 10,000×  | 24         | 
| 100,000× | 27         | 

Q4.22 sits in the sweet spot: comfortably above the requirement up to ~1,000×, marginal but usable at 10,000×, broken at 100,000×. The educationally interesting range (everything the user will explore in the demo) is covered. 


---

## 4. Why fixed-point instead of float

A 32-bit IEEE float has 1 sign + 8 exponent + 23 mantissa bits. The exponent is variable, which is great for representing wildly different magnitudes but expensive. A floating-point multiplier has to align exponents, multiply mantissas, then renormalise and round, and costs roughly **5× the area** of an integer multiplier of equivalent width.

The Zynq-7020 has 220 DSP48E1 hard blocks. Each does one 25×18 signed multiply per cycle. A Q4.22 multiply (26×26 signed) fits in **2 DSPs**. Each iteration step needs three multiplies (`zr²`, `zi²`, `zr·zi`), so:

| Datapath                | DSPs per multiply | DSPs per core | Cores in 220 DSPs |
|-------------------------|-------------------|---------------|-------------------|
| Q4.22 fixed-point       | 2                 | 6             | **~36** |
| Single-precision float  | ~10               | 30            | ~7                |

That 5× ratio just means that we can't afford float.

The cost of fixed-point is that precision can just fall off a cliff: when zoom exceeds what the fractional bits can resolve, you fall off and the image block-quantises. Float would degrade much better.

There is also an option for using a Q4.48 through a slower second datapath, but that is out of scope right now, and we can visit that idea should we finish

---

## 5. Methodology

For each `(view, frac_bits)` pair, the C renderer iterates `z = z² + c` to `max_iter = 512`, on two independent paths:

1. **Reference:** IEEE double precision (`iter_double` in `src/fixed_mandelbrot.c`).
2. **Test:** Q(`4`).`frac_bits` signed fixed-point in a `__int128` accumulator, arithmetic-right-shift truncation after each multiply (`iter_fx`).

Both paths see identical view geometry (same `center_r`, `center_i`, `zoom`, pixel grid). Per-pixel iteration counts are written to `.bin` files (raw `int32` row-major), loaded by the Python harness, and diffed against the reference.

We use two metrics because they tell different stories:

| Metric | Definition | What it captures | When to lead with it |
|---|---|---|---|
| `err_gt1_frac` | fraction of pixels with `\|Δiter\| > 1` | exact arithmetic agreement | showing the precision cliff |
| `class_diff_frac` | fraction of pixels with different `iter == max_iter` classification | whether the user sees a different image | making the visual-quality case |

The strict metric is pessimistic because the Mandelbrot boundary is chaotic — even **Q4.32 vs double** disagrees on ~14% of pixels at 100,000× zoom, and that's the *fractal* misbehaving, not a precision failure. The classification metric removes that noise: it only counts the qualitative "is this pixel black (inside) or coloured (outside)" decision, which is what the user actually perceives.

### Test views

Five views, spanning the range from "obviously fine" to "obviously
broken":

| Name              | Centre                   | Zoom     | Why this view |
|-------------------|--------------------------|---------:|----------------|
| `overview`        | (−0.5, 0)                | 1×       | The whole set. Sanity check: any reasonable precision works here. |
| `seahorse_100x`   | (−0.7436, 0.1318)        | 100×     | First view where precision starts to matter. |
| `seahorse_1000x`  | same                     | 1,000×   | "very good" threshold. |
| `seahorse_1e4x`   | same                     | 10,000×  | "visible quantisation" threshold. |
| `seahorse_1e5x`   | same                     | 100,000× | Past the cliff.|

The seahorse valley `(−0.7436, 0.1318)` is a deliberately hard test
region: dense fractal structure on the cardioid boundary, with
period-doubling spirals that demand precision to resolve. If a format
survives the seahorse, it survives anywhere educationally useful.

### Precisions tested

Q4.{12, 16, 18, 22, 26, 32}. 12 is so coarse it should obviously fail.
32 is the rough upper bound for two 25×18 DSPs without spilling into a
third. **22** is the proposed choice. 18 and 26 bracket it tightly so
the bar chart shows a clear cost/benefit gradient rather than a single
data point.

---

## 6. Results

The main figure: [`plots/summary.png`](plots/summary.png).

**Strict metric, fraction of pixels with `|Δiter| > 1`:**

| view              | Q4.12 | Q4.16 | Q4.18 | Q4.22 | Q4.26 | Q4.32 |
|-------------------|------:|------:|------:|------:|------:|------:|
| overview          | 0.7%  | 0.4%  | 0.3%  | 0.1%  | 0.08% | 0.03% |
| seahorse_100x     | 18.4% | 11.2% | 8.5%  | 4.7%  | 2.5%  | 0.9%  |
| seahorse_1000x    | 59.2% | 30.8% | 23.4% | 13.5% | 7.7%  | 3.1%  |
| seahorse_1e4x     | 97.4% | 81.7% | 63.1% | 35.9% | 19.7% | 7.8%  |
| seahorse_1e5x     | 100%  | 97.6% | 96.9% | 60.6% | 33.9% | 13.7% |

**Classification metric, fraction of pixels with a different inside/outside verdict:**

| view              | Q4.12 | Q4.16 | Q4.18 | Q4.22 | Q4.26 | Q4.32 |
|-------------------|------:|------:|------:|------:|------:|------:|
| overview          | 0.08% | 0.05% | 0.04% | 0.02% | 0.02% | 0.01% |
| seahorse_100x     | 3.8%  | 2.6%  | 2.1%  | 1.3%  | 0.8%  | 0.3%  |
| seahorse_1000x    | 3.3%  | 1.4%  | 1.3%  | 1.1%  | 1.0%  | 0.6%  |
| seahorse_1e4x     | 1.3%  | 2.3%  | 2.4%  | 2.3%  | 1.9%  | 1.3%  |
| seahorse_1e5x     | 2.3%  | 2.3%  | 5.5%  | 3.3%  | 2.8%  | 2.1%  |


### Reading the plots

The most informative figure is
[`plots/heatmap_seahorse_1e4x.png`](plots/heatmap_seahorse_1e4x.png):

- Q4.12 collapses to four flat blocks: the pixel grid is finer than
  the representable step at this zoom, so neighbouring pixels round to
  the same `c` and the image quantises catastrophically.
- Q4.16 still shows blockiness but recovers some structure.
- Q4.18 shows mostly-correct structure but with visible chunky
  artefacts.
- **Q4.22 looks essentially identical to Q4.32**.

At 100,000× ([`heatmap_seahorse_1e5x.png`](plots/heatmap_seahorse_1e5x.png))
Q4.22 has clear quantisation and Q4.32 is starting to degrade too


---

## 7. To run

```bash
pip install -r requirements.txt
make                                                 # build
```

`make ci` runs a smaller subset (96×96, 2 views, 3 precisions) in
seconds, and is used by CI.

---

## 8. Continuous integration

[`.github/workflows/number-format-study.yml`](../../../.github/workflows/number-format-study.yml)
runs `make ci` on every push or PR that touches files under
`docs/studies/number_format/`. Other directories don't trigger it, so
unrelated commits don't burn CI minutes.

The CI job:

1. Spins up a clean Ubuntu VM on GitHub's infrastructure.
2. Installs Python 3.11 with `pip` caching keyed on `requirements.txt`.
3. Installs numpy and matplotlib.
4. Runs `make ci`: compile, run unit tests, run the smoke study,
   generate plots.
5. Uploads the plots as a downloadable artifact attached to the run.

---
