# FractalScope - Project Plan

**Platform:** PYNQ-Z1 (Zynq XC7Z020)

**Course:** ELEC50015 — Electronics Design Project 2 (Mathematics Accelerator)

**Team:** Anthony Bartlett (EIE), Denzil Erza-Essien (EIE), Lukas Mykhnenko (EEE), Junjiang Wu (EEE), Sam Wash (EEE), Aadi Sharma (EEE)

**Headline target:** 1280×720 @ ~60 FPS on typical Mandelbrot/Julia exploration, graceful degradation to ~20 FPS on inside-heavy / Multibrot views, FPGA-accelerated Mandelbrot family + logistic map, custom USB controller on a fabbed PCB, full educational walkthrough, CPU baseline at 7 optimisation levels.

---

## 0. Important Deadlines

```
Wed 20 May       ORDER COMPONENTS 
Fri 29 May       ORDER PCB
Mon  1 Jun 2026  INTERIM PRESENTATION
Mon 15 Jun       REPORT DUE 16:00 + individual reflection
Wed 17 Jun       Last day of lab access
Thu 18 Jun       DEMO + INTERVIEWS
```

Lab hours: ~09:00–17:00 weekdays. Closed evenings and weekends. £60 group budget. One PYNQ-Z1 board, shared.

---

## 1. Headline architectural decisions

These are load-bearing. Everything else follows.

1. **Use the starter project's streaming video path unchanged.** The accelerator is a pixel generator with an AXI-Stream master output and an AXI-Lite slave for control. The existing VDMA writes the stream into DDR; the existing HDMI subsystem reads DDR at constant rate.

2. **Pipelined iteration cores with replacement, replicated in parallel.** Target 16–32 cores at 100 MHz fabric clock. Each core holds a 5-stage pipeline performing `z = z² + c` one iteration per cycle. Pixels enter as scalar (x,y), iterate inside the pipeline, exit with an iteration count on escape or max_iter.

3. **Q4.22 fixed-point as the primary datapath (26-bit signed).** 4 integer bits (range ±8 with sign), 22 fractional bits. Comfortable zoom to ~3,000–10,000×. Three multiplies per iteration step at 2 DSPs each = 6 DSPs per core × N cores. Overflow detection is a sticky flag exposed via AXI-Lite.

4. **PS owns intent; PL owns throughput.** The custom controller produces input events. The PS interprets them into mode/parameter changes. The PS writes AXI-Lite registers. The PL renders. The controller never talks to the FPGA directly.

5. **Start-of-frame parameter latching.** Shadow registers receive AXI-Lite writes asynchronously; working registers copy from shadow at SOF. Eliminates mid-frame tearing without needing a render-job commit protocol.

6. **Adaptive max_iter (variable FPS), not strict 60 FPS worst-case.** The FPGA reports actual completion time; if a frame takes too long, max_iter is clamped on the next frame. UI shows "rendering depth: N" so this is visible and educational rather than hidden.

7. **Skeleton-first build order.** Get a thin end-to-end slice working in Week 1 (one button on a breadboard → one register write → visible HDMI change). Add depth in Weeks 2–3. Polish in Week 4. The interim presentation on 1 June *must* show a working skeleton, not three disconnected subsystems.

---

## 2. System block diagram

![Mandelbrot on PYNQ](../assets/system_diagram.png)


---

## 3. Throughput budget and parallelism

### 3.1 Targets

- Resolution: 1280×720 internal render and output.
- Output pixel rate: 55.3 Mpix/s at 60 FPS.
- Accelerator clock: 100 MHz target, 150 MHz stretch if timing closes.
- Primary algorithm worst case: 256-iteration Mandelbrot, mostly inside the set.

### 3.2 Required iterations/second

- Typical view, avg ~60 iter/pixel: 3.3 G iter/s for 60 FPS.
- Worst case (every pixel hits max_iter = 256): 14.2 G iter/s for 60 FPS.

---

## 4. Fixed-point format and number analysis

### 4.1 Primary format: Q4.22 signed

- Total width: 26 bits. Sign bit: 1. Integer bits: 3. Fractional: 22.
- Smallest step: 2⁻²² ≈ 2.4×10⁻⁷.
- Pixel-step margin: usable zoom up to ~3,000× cleanly, tolerable quantisation visible to ~30,000×.


### 4.2 Overflow detection

Sticky `overflow_seen` bit in AXI-Lite STATUS register. Set when any iteration's `z_r²` or `z_i²` saturates the integer range. Cleared on register write. UI displays "precision limit reached" badge when set.

---

## 5. FPGA subsystem

### 5.1 Top-level structure

...

## 6. Software architecture (PS side)

### 6.1 State machine

```
BOOT → INIT_HARDWARE → MAIN_MENU
                          │
       ┌──────────────────┼──────────────────┐
       ▼                  ▼                  ▼
   WALKTHROUGH         EXPLORER          BENCHMARK
       │                  │                  │
       ▼                  ▼                  ▼
   scene 1..7      library + free      CPU vs FPGA
                   navigation          comparison
```

Single authoritative `app_state` object. All transitions explicit. No "current mode" lookup outside the state machine module.

### 6.2 Boot

systemd unit starts the app at boot:
1. Load the FPGA overlay via PYNQ.
2. Initialise HDMI (720p, with 600p/480p fallback if EDID fails).
3. Write palette banks into BRAM.
4. Open `/dev/ttyACM0` for the controller (retry loop, keyboard fallback on `/dev/input/event*`).
5. Enter MAIN_MENU.

User never sees a Linux prompt. Demo-ready boot in under 60 seconds.

---

## 7. Custom controller

### 7.1 Hardware 

- RP2040 module (Pico or RP2040 chip + crystal + decoupling on the PCB): ~£4
- 2× quadrature encoders with detents (zoom, max_iter): ~£12
- 2× 10K linear pots (Julia c_real, c_imag): ~£2
- 1× 2-axis analog thumbstick (pan): ~£3
- 6× momentary tactile buttons (NEXT, BACK, SELECT, MODE, PALETTE, RESET): ~£3
- USB-B mini/micro connector + cable: ~£3
- Headers, resistors, caps, LEDs: ~£5
- 5× 2-layer PCBs from JLCPCB or similar: ~£10–15 incl. shipping

Total ~£42–48, well within the £60 budget.

Bus-powered from PYNQ USB host (~60 mA active).

### 7.2 MCU firmware responsibilities

- Encoder quadrature decoding (interrupt-driven, both edges).
- Button debouncing (5 ms hold-time filter).
- ADC sampling for joystick + pots at ~200 Hz.
- USB CDC packet emission at 100 Hz fixed cadence (deterministic, not on-change).
- CRC8 for packet integrity.

The MCU sends *events*, not commands. The PS decides what each one means.

### 7.3 Packet format

ASCII line-based:
```
FSCP,<seq>,<btn_hex>,<zoom_d>,<iter_d>,<jx>,<jy>,<knob0>,<knob1>,<crc>\n
```
Example: `FSCP,4521,01A0,+2,-1,128,-64,2048,3072,7F`

---

## 8. Educational content (walkthrough)

### Scene 1: Recurrence on the real line
PS-drawn number line, animated dot bouncing through `x → x² + c` with real `c`. Inputs: knob 0 sets c, NEXT advances.

### Scene 2: Recurrence on the complex plane
PS-drawn complex plane, point c, animated orbit trail. Inputs: joystick moves c, NEXT advances.

### Scene 3: Escape radius
PS-drawn plane with the |z|=2 circle highlighted. Orbit stays in forever or breaks out. Brief on-screen note: |z|>2 ⟹ escape. Inputs: joystick moves c, NEXT.

### Scene 4: Pixel = c
Coarse grid of c values (32×18). FPGA renders at this resolution. Each cell shows escape count as a number, then as a colour. The bridging scene from "iterate" to "image".

### Scene 5: Full Mandelbrot, free exploration
Full 720p FPGA render. Overlay shows centre, zoom, max_iter, FPS. Inputs: pan/zoom/iter knobs/palette.

### Scene 6: Mandelbrot ↔ Julia split-screen
Left half: Mandelbrot with cursor at current c. Right half: Julia for that c. **Strongest single educational moment.** Inputs: joystick moves the cursor (and thus Julia c), NEXT.

### Scene 7: Precision limits
Continue zooming. Show actual quantisation. Trip the overflow flag, display "precision limit reached". Honest engineering trade-off.

### Library mode (post-walkthrough)
Selectable grid: Mandelbrot, Julia, Burning Ship, Tricorn, Multibrot3, Logistic. Thumbnail (pre-rendered PNG), one-paragraph description, "explore" button. Each reuses the explorer UI; only FRACTAL_TYPE differs.

### Benchmark mode
Split-screen FPGA vs CPU on the same view. Live FPS counters for both. Live iterations/second. The "why FPGA" moment.

---

## 9. Simulation and verification

...

---

## 10. HDMI and resolution

- Default: 1280×720 @ 60 Hz.
- Boot-time fallback: hold MODE button on boot to cycle resolutions

PYNQ-Z1 HDMI documented to work reliably up to 720p; 1080p marginal. We target 720p and don't promise more.

---

## 11. Team allocation (two-team structure)

The project runs as two parallel teams. After Week 2 the EEE team pivots from controller work onto software and testing while the EIE team continues FPGA work end-to-end. Daily 10-minute standup in the lab keeps both teams aware of where interfaces are moving.

### EEE team (4 people)

Phase 1 (Weeks 1 to 2): the controller is the priority. All four work on it together. A natural split is two on hardware (KiCad schematic, layout, PCB ordering, assembly, casing) and two on firmware and PS-side driver (RP2040 quadrature decoding, ADC sampling, USB CDC packet generation, the `controller_driver.py` packet parser). The four can re-pair as needed; the team is small enough that mob debugging is reasonable for tricky integration moments.

The Phase 1 sequence is deliberate: validate the breadboard before committing to the PCB. Breadboard MVP by end of Week 1 (one button, one encoder, end-to-end). Full breadboard with all inputs by mid Week 2. PCB ordered Fri 29 May once the breadboard is genuinely working, not before.

Phase 2 (Weeks 3 to 4): once the PCB is ordered, two of the EEE team move onto educational scenes 4 onwards plus the library mode and benchmark UI. Two move onto integration testing, the hardware test ladder, demo rehearsal, and report drafting. When the PCB arrives (somewhere between Mon 8 and Wed 10 June, given JLCPCB lead times), whoever's nearest in the hardware queue does the bring-up; it should be a few hours since the firmware is identical to the breadboard build.

Throughout: the keyboard fallback (`evdev` on `/dev/input/event*`) is maintained as a tested alternative to the controller. This is the demo-day insurance policy.

### EIE team (2 people)

Full 4 weeks on FPGA system, CPU baseline, early PS scaffolding, and educational scenes 1 to 3 (the NumPy PS-drawn ones).

Phase 1 split suggestion: one person leads the iteration core (pipelined Mandelbrot first, then mode bits for Julia, Burning Ship, Tricorn, then the cubic core for Multibrot3, then the logistic engine). The other leads system integration (AXI-Lite slave with shadow and working register split, pixel scheduler, reorder buffer, palette LUT, SOF latch, HDMI bring-up, IP packaging, timing closure). Both contribute to scenes 1 to 3 in Week 2 evenings or any slack windows.

Phase 2: continue FPGA work, finish algorithm variants, run the CPU baseline (all 7 levels), polish performance counters, integrate with the EEE software side.

### Shared responsibilities

- Register map drafted Week 1 by EIE, reviewed by the EEE firmware author before Friday freeze.
- Controller protocol drafted Week 1 by EEE, reviewed by EIE before Friday freeze.
- Verilator testbench infrastructure: EIE owns the harness, EIE writes the C golden model (reused as Level 4 of the CPU baseline).
- Demo script and report outline: jointly owned, drafted Week 3.

---

## 13. Weekly schedule

Working days available between today and the report deadline: roughly 20, after subtracting the two professional engineering half-days, the bank holiday, and accounting for weekends.

### Week 1: Mon 18 to Sun 24 May

**Mon 18 May (today).** Whole team: 1-hour kickoff. GitHub set up. Register map and controller protocol drafts started. BOM finalised by end of day. EIE: clone the starter project, get Vivado building, read the existing `pixel_generator.v`. EEE: KiCad project skeleton, BOM cross-checked against Onecall and RS.

**Tue 19 May.** Morning: Presentation Skills professional content (mandatory, ~half-day). Afternoon: EIE starts a single iteration-core skeleton in Verilator. EEE schematic capture in progress; RP2040 hello-world over USB CDC on a Pico module if one is to hand.

**Wed 20 May.** Morning: Career Development professional content (mandatory, ~half-day). **Components ordered from Onecall or RS in the AM by EEE, before the professional content session.** Afternoon: EIE has the iteration core pipelined; DSP inference verified by checking the Vivado synth report. EEE works on firmware (quadrature decode, button debouncing) while waiting for parts.

**Thu 21 May.** Components likely arriving (Onecall/RS UK next-day or 2-day standard). EIE: single-pixel test passes vs golden C reference in sim. AXI-Lite regfile extended to support the new register map. EEE: breadboard assembly begins. Firmware continues.

**Fri 22 May.** EIE: timing report at 100 MHz on single core. First low-resolution test image rendering on the HDMI output from the actual PYNQ. EEE: breadboard MVP target. One encoder, one button, end-to-end through `controller_driver.py` to an AXI-Lite register write to a visible HDMI change. Register map and controller protocol frozen and committed to the repo, both teams sign off.

Weekend: buffer. No hardware tasks scheduled. Optional firmware polish or sim work for anyone keen.

### Week 2: Mon 25 to Sun 31 May

**Mon 25 May.** UK Spring Bank Holiday. Lab closed. Buffer for any Week 1 slippage. Anyone working remotely can do firmware, simulation, or NumPy scene work; no PYNQ-board tasks.

**Tue 26 May.** EIE: replicate iteration cores in sim (target 8, working toward 16 by end of week). EEE: full breadboard assembly with all encoders, buttons, joystick, pots. Goal is to have the complete input set wired and exercisable.

**Wed 27 May.** EIE: multi-core full image in sim, iteration counts match golden model on a full frame. SOF latch implementation. EEE: firmware polish, 100 Hz packet rate stable with CRC. `controller_driver.py` integrated with the state machine framework EIE has stubbed.

**Thu 28 May.** EIE: Mandelbrot working on hardware at 720p (low max_iter for now, just to prove the path). Palette LUT and smooth colouring. EEE: practice the interim demo with the breadboard controller. End-to-end thread fully exercised. Catch any latent integration bugs now while there's time.

**Fri 29 May.** EIE: scenes 1, 2, and 3 in NumPy (PS-drawn). Smooth colouring refined. EEE: gerbers off to JLCPCB before lunch (the breadboard is validated; PCB order is now low-risk). PCB order confirmation forwarded to the group. Afternoon: whole team interim presentation rehearsal.

Weekend: interim slide deck. Each member has a 1 to 2 minute slot mapped to their work.

### Week 3: Mon 1 to Sun 7 June

**Mon 1 June. INTERIM PRESENTATION.** 15 minutes. All 6 contribute. Structure: motivation and spec (1 min), system block diagram and interfaces (2 min), FPGA architecture and iteration core (2 min), controller hardware and PCB design (2 min), controller firmware and protocol (2 min), CPU baseline strategy (1 min), live skeleton demo with breadboard controller and FPGA Mandelbrot (3 min), risks and next two weeks (2 min). PCB layout shown on a slide with "ordered, in production".

**Tue 2 June.** EIE: Julia, Burning Ship, and Tricorn mode bits added to `iter_core_quad`. **EEE pivot:** 2 on scenes 4 onwards and library/benchmark UI. 2 on the integration test ladder and demo polish. PCB still in transit.

**Wed 3 June.** EIE: Multibrot3 core (`iter_core_cubic`) in sim. Performance counters wired up to AXI-Lite RO registers. EEE scenes pair: scene 4 (32x18 escape grid) working. Scene 5 (free Mandelbrot exploration) starts. EEE testing pair: hardware test ladder items 1 to 5 done.

**Thu 4 June.** EIE: logistic map engine. Adaptive max_iter feedback loop. EEE scenes pair: scene 5 polished, scene 6 (split-screen) starts. EEE testing pair: continue ladder, begin 1-hour stress test.

**Fri 5 June.** All algorithms working end-to-end on the breadboard rig. Demo dry-run 1. Report writing kicks off; section ownership locked in. Weekend: report drafting.

### Week 4: Mon 8 to Sun 14 June

**Mon 8 June.** PCB plausibly arrives today (JLCPCB DHL Express lead from Fri 29 May order is 5 to 7 working days, so Mon 8 to Wed 10 June is the realistic window). If it arrives, the EEE testing pair brings it up in a couple of hours. Otherwise, breadboard rig continues. Report drafts in, cross-review. Demo dry-run 2.

**Tue 9 June.** Bug fixing. Report editing. Outstanding issues triaged by demo impact.

**Wed 10 June.** PCB definitely should be integrated by now. Demo dry-run 3 with final hardware.

**Thu 11 June.** Final polish. Demo dry-run 4. Report editing for the 10,000-word limit.

**Fri 12 June.** Buffer day. Final report edits. Individual reflections drafted.

Weekend: final touches. Pack the demo kit (power supply, HDMI cable, monitor if uncertain about the lab one, USB cable, spare SD card with the working image).

**Mon 15 June 16:00. REPORT SUBMITTED. Individual reflections submitted.**

**Tue 16 / Wed 17 June.** Final demo rehearsals. Lab access ends Wed 17.

**Thu 18 June. DEMO + INTERVIEWS.**

---

## 14. Risk register

| Risk | Probability | Impact | Mitigation |
|---|---|---|---|
| Components delivered late by Onecall/RS | Low | High | Order Wed 20 May AM, not Wed PM. UK domestic carriers are reliable but not magic; ordering before the half-day starts is the safety margin. |
| Controller PCB doesn't arrive in time | Medium | Medium | Breadboard rig is fully demo-capable. PCB is a presentation upgrade, not a functional one. Keep breadboard wiring tidy and labelled in case it has to run the demo. |
| Timing closure fails at 100 MHz with 32 cores | Medium | Medium | Drop to 24 cores first, then 16. 480p fallback covers worst case. |
| Multibrot3 core busts DSP budget | Medium | Medium | Fewer z^3 cores (down to 4). Accept lower FPS for that mode and document it. |
| Logistic map mode doesn't fit on the FPGA in time | Medium | Low | Fallback: compute logistic on the Cortex-A9 PS, write into a DDR framebuffer through the VDMA path. Lose the all-FPGA claim for that mode but ship the visualisation. |
| HDMI 720p fails on demo monitor | Low | High | Boot-time fallback to 600p or 480p via held button. Test on at least two different monitors before demo week. |
| Fixed-point too restrictive at demo zoom | Low | Medium | Limit zoom in the UI to a documented safe range. The overflow indicator is a feature, not a bug; scene 7 specifically exploits it. |
| Single PYNQ board contention | High | Medium | Sim-first discipline: every hardware-touch task is preceded by a successful simulation. Two-hour booking blocks on a whiteboard during lab hours. |
| Per-pixel Python in overlay drawing | Medium | High | Code review rule: any per-pixel Python loop fails review. NumPy or pre-rendered only. |
| IP packaging churn breaks the build | Medium | Medium | EIE documents the exact rebuild flow in the repo; any team member can rebuild from scratch on a fresh checkout. |
| SD card corruption | Low | High | Two SD cards. Image regularly. All source in git. |
| Member illness or absence in Week 4 | Low | High | Each subsystem has at least one document and one backup person who has run it. |
| Interim presentation fails to show end-to-end skeleton | Medium | Medium | Friday 29 May integration rehearsal is non-negotiable. Slip date: anything not working that day gets cut from the interim and presented on slides only. |

---

## 15. Demo plan (Thu 18 June, ~10 min)

Order is chosen so each segment stands alone. If one fails, the next still works.

1. **(0:00) Cold boot.** Power-on to main menu in under 60 seconds. Tests deployment and demonstrates "demo-ready" engineering.
2. **(1:00) Walkthrough scenes 1 to 4.** Real-line recurrence, complex-plane recurrence, escape radius, pixel-equals-c grid. Tells the educational story.
3. **(4:00) Scene 5: full Mandelbrot exploration.** Custom controller drives pan, zoom, max_iter, palette. The headline 60 FPS in the typical case. Tests user-input system, custom hardware, and the main throughput claim.
4. **(5:30) Scene 6: split-screen Mandelbrot and Julia.** Joystick moves a cursor on the Mandelbrot side; the Julia parameter c follows. The strongest single educational moment.
5. **(7:00) Library mode.** Cycle through Burning Ship, Tricorn, Multibrot3, logistic map. Demonstrates the multi-algorithm framework.
6. **(8:30) Benchmark mode.** Split-screen FPGA vs CPU on the same view, live FPS counters visible. The "why FPGA" justification, with numbers.
7. **(9:30) Scene 7: precision limits.** Continue zooming until the overflow flag trips and "precision limit reached" appears. Honest engineering trade-off discussion.

Question and answer: each member is ready to talk to their subsystem. The marker rubric expects this explicitly.

---

## 16. Proposed extensions

If the team is ahead of schedule by end of Week 3, here are extensions ordered roughly by value to effort ratio. Tier 1 are realistic add-ons even with only a few spare days. Tier 2 needs about a week of focused effort. Tier 3 is genuinely ambitious and only worth starting if everything else is locked down.

### Tier 1: high value, low to medium effort

**Periodicity checking optimisation.** Inside-set pixels typically enter a periodic orbit within a handful of iterations. Detecting that they are cycling lets the core short-circuit to `iter = max_iter` immediately, freeing the pipeline for new pixels. Two implementation routes: a stationary-point detector (compare `z` to `z` from N iterations ago; if the difference is below epsilon for several iterations in a row, assume periodicity), or Brent's cycle detection with a small comparison window. Either route adds roughly 30 percent to the iteration core complexity. Expected speedup on inside-heavy views is 2x to 5x. This is a real engineering contribution worth a paragraph in the report, with measured before/after FPS numbers on three reference views.

**Distance estimation rendering.** Track the derivative `dz/dc` alongside `z` in the iteration core: `dz/dc` updates as `dz_new = 2 * z * dz + 1`. After escape, the estimated distance from the pixel to the set boundary is approximately `|z| * log|z| / |dz|`. Rendering this distance as brightness produces a striking pseudo-3D illuminated look around the boundary. Costs 1 extra DSP per core for the derivative multiply, plus a divide at output time (can be a small reciprocal LUT). Visually transformative; very photogenic for the demo.

**Real-time orbit overlay in scene 5.** For the single pixel under the cursor, compute its iteration orbit on the PS side (no FPGA work needed since it's one pixel) and draw it as a connected polyline overlay on top of the FPGA rendering. This is the visual link from the recurrence scenes 1 to 3 to the full Mandelbrot in scene 5: the user sees the orbit they've been learning about, alive on the actual set. Pure NumPy and bitmap overlay. Probably one day of work.

**Power monitoring.** The PYNQ-Z1 carries onboard current and voltage sensors on the Zynq power rails, accessible via the `pmbus` interface or the sensor sysfs nodes. Read them, multiply, integrate, and display "Joules per gigapixel" alongside the FPS counter in benchmark mode. Compelling engineering metric because the FPGA story is fundamentally about throughput per watt, and showing the watts makes the argument quantitative rather than rhetorical. Light PS-side work, fits comfortably in a day.

### Tier 2: higher effort, high reward

**Mariani-Silver boundary tracing.** Classic Mandelbrot rendering optimisation. For any rectangular region, if the entire perimeter renders to the same iteration count, the interior must too (a consequence of the Mandelbrot set being connected). Algorithm: render perimeters first, recurse only into regions whose perimeters are non-uniform. On inside-heavy zoomed views, this can deliver 5x or more speedup, since vast solid-colour interior regions render with only their perimeter pixels. Implementation is PS-side: PS commands the FPGA to render specific row ranges or column ranges. Requires some FPGA cooperation (probably an X_START, X_END, Y_START, Y_END register addition for sub-frame rendering), but mostly software. Mid-week 4 work.

**Auto-tour mode.** Predefined list of named locations on the Mandelbrot set (Seahorse Valley, Elephant Valley, Mini Mandelbrot at -1.75, the Spiral, Mariana Trench, and so on). Smooth Catmull-Rom interpolation between them, with constant-speed parameterisation so the camera moves at a consistent visual rate regardless of segment length. PS-side only; no FPGA changes. About two days for a polished implementation including a curated tour list and on-screen captions explaining each location. Excellent demo material.

**Buddhabrot rendering.** Alternative visualisation: instead of colouring pixels by their own iteration count, you colour each pixel by how many other pixels' orbits passed through it. Procedure: launch a swarm of random `c` values, iterate them, and for those that escape, walk their orbit again and accumulate a "1" in a histogram at every pixel the orbit visited. Brightness reveals the unconscious paths through which the set funnels its escapees. Reuses the histogram BRAM and accumulation infrastructure that the logistic map mode already requires. Three to four days. Different aesthetic that distinguishes the report visually.

**Newton fractal.** Was cut from the original scope; can come back as an extension. Iteration is `z_{n+1} = z_n - p(z_n)/p'(z_n)` for a polynomial `p`. The complex plane is coloured by which root the iteration converges to. The hard part on FPGA is the division. Two options: implement a fixed-point divider (about 20 cycles latency using a non-restoring algorithm), or use a few Newton-Raphson iterations for the reciprocal in fixed-point. Mathematical interest is high. Roughly a week.

**Stripe colouring and orbit traps.** Conventional colouring uses iteration count. Stripe colouring uses the angle of `z` at escape: `colour = average over iterations of (1 + sin(s * arg(z_i))) / 2`. Orbit traps use the closest approach of the orbit to a geometric shape (a line, a circle, a star). Both produce wildly different aesthetic results from the same underlying compute. Adds maybe one comparison and one accumulator per iteration core. Cheap to add, gives the library mode much more variety, very photogenic.

### Tier 3: very ambitious, only if comfortably ahead

**Perturbation theory for deep zoom.** The killer extension if you can pull it off. Standard fixed-point Mandelbrot caps out around 10^4 zoom; perturbation lets you zoom to 10^15 or beyond with the same hardware precision. Method: choose one "reference" pixel near the centre of the view. Compute its full orbit `Z_n` in high precision on the PS side using `mpmath` or `gmpy2`. For every other pixel, compute its deviation `δ_n = z_n - Z_n` in low-precision fixed point on the FPGA, using the recurrence `δ_{n+1} = 2 * Z_n * δ_n + δ_n² + δ_c`. The FPGA needs to read the high-precision reference orbit one step at a time (PS streams it in via AXI-Lite or a dedicated AXI-Stream input). When `|z_n|` gets large enough that perturbation breaks down (a "glitch"), pick a new reference and re-run those pixels. Implementation effort is high; the mathematical and engineering payoff is enormous. Two weeks of focused work for a polished version; possible to do a basic version in a week if perturbation glitches are not handled.

**Lyapunov fractals.** Mathematical relative of the logistic map. Pick a sequence of As and Bs (e.g. "AABAB"). At each pixel `(a, b)`, iterate `x_{n+1} = r_n * x_n * (1 - x_n)` where `r_n` is `a` if the n-th letter is A and `b` if it's B. Compute the Lyapunov exponent `λ = (1/N) * Σ log|f'(x_n)|`. Colour by sign and magnitude of `λ`: negative means stable, positive means chaotic. Visually striking, mathematically deep, and mathematically connected to the logistic map already in the project. Reuses the logistic engine with a different driving sequence. Around four days.

**Mandelbulb (3D fractal).** True 3D generalisation of the Mandelbrot set via spherical-coordinate exponentiation. Rendered via ray marching with distance estimation. Extremely impressive visually. Distance estimation is a hard real-time problem at 720p; even with the FPGA accelerating the per-iteration step, ray marching needs perhaps 50 to 200 iterations per pixel just for the marching, on top of the fractal evaluation. Probably runs at 5 to 15 FPS at best on this hardware. Three weeks of work, only really feasible if the project hit major milestones a week early.

**Recording mode.** Save each rendered frame to disk during a session. Post-process with ffmpeg into MP4 videos. Pure PS-side work; about a day. Mostly useful for producing materials to embed in the report.

**Network streaming / web interface.** Stream the rendered frames over the PYNQ Ethernet port as MJPEG or as raw frames over WebSocket. A browser-based viewer with on-screen pan and zoom. Allows multiple spectators during the demo to watch on phones. Couple of days for a basic version. Interesting but probably not worth the time given the demo is in-person.

**Audio sonification.** Convert orbit data (e.g. the angular position of `z` at each iteration step) into audio tones for the current cursor pixel. Synaesthetic exploration mode. A day of work for a basic implementation; the artistic question of what makes a "good" sonification is harder than the engineering. Fun if there's time; not a strong rubric contribution.