# FractalScope

Real-time fractal rendering on a PYNQ-Z1, using a Zynq-7020 Processing System / Programmable Logic split.

FractalScope is an interactive HDMI demo that renders Mandelbrot-family fractals using a custom fixed-point hardware pipeline in the FPGA fabric, with a Python/PYNQ application managing the walkthrough, controls, framebuffers, overlays, and CPU comparison path.

The project is not just a fractal drawing program. It is a small hardware/software system: the PS configures the view and owns the user experience, while the PL schedules pixels, runs many iteration cores in parallel, colours the results, and writes completed pixels into DDR for display.

## What is implemented

- Fixed-point SystemVerilog fractal accelerator for:
  - Mandelbrot
  - Julia
  - Burning Ship
  - Tricorn
- 26-bit signed Q4.22 arithmetic in the PL iteration pipeline
- Multi-core iteration array, scaled to 23 cores in the final release build
- Tile-based scheduler using 32 x 16 tiles
- Mariani-Silver-style tile evaluation to skip uniform regions
- Progressive rendering passes for faster first response and later refinement
- Palette ROM with multiple selectable colour maps
- Direct framebuffer write path:
  - unordered completed pixels carry a framebuffer index
  - the PL writes pixels into DDR through an AXI4 master
  - VDMA reads the framebuffer for HDMI output
- PYNQ/Python runtime for:
  - bitstream loading
  - MMIO register programming
  - framebuffer allocation and swapping
  - controller input
  - guided educational scenes
  - menu-launched free-roam fractal exploration
- C++ CPU baseline renderer, callable from the Python demo for CPU vs PL comparisons
- Vivado release directories with rebuild scripts and packaged IP

## System architecture

```text
Physical controller / keyboard
            │
            ▼
PYNQ Processing System
  ├── run_demo.py scene manager
  ├── educational PS-rendered scenes
  ├── free-roam state and UI overlays
  ├── PYNQ MMIO control of PL IP
  ├── double framebuffer management
  └── optional C++ CPU baseline
            │
            │ AXI-Lite control
            ▼
Programmable Logic
  ├── tile_scheduler_top
  │     ├── 32 x 16 tile traversal
  │     ├── progressive scale support
  │     └── Mariani-Silver tile evaluation
  ├── iter_core_array
  │     └── parallel Q4.22 fractal iteration cores
  ├── colour_palette
  │     └── iteration count to RGB mapping
  └── pixel_write_engine
        └── AXI4 writes into DDR framebuffer
            │
            ▼
DDR framebuffer
            │
            ▼
AXI VDMA MM2S -> AXI video -> HDMI
```

The key design decision in the later versions is to make DDR the ordering boundary. Earlier ordered-stream designs required a reorder buffer before the display path. The current architecture lets cores finish pixels out of order, because each result carries its framebuffer index and can be written directly to the correct address.

## Hardware target

| Item | Value |
|---|---|
| Board | PYNQ-Z1 |
| FPGA | Zynq-7020 |
| Toolchain | Vivado 2023.2 |
| Output | HDMI |
| Frame size | 1280 x 720 |
| Framebuffer format | 32-bit RGB-packed words |
| PL number format | signed Q4.22 |
| Iteration width | 16 bits |
| Palette entries | 1024 per palette |
| Final release core count | 23 iteration cores |

## Repository layout

```text
fpga/
  rtl/                  Active SystemVerilog RTL blocks
  tb/                   Directed RTL testbenches

ps/
  run_demo.py           Main PYNQ demo entry point
  scenes/               Guided educational scenes, summary, loading screen, menu
  backend/              PL backend, free-roam state, CPU baseline integration
  cpu_baseline/         C++ CPU fractal renderer used for comparison
  tests/                Python smoke tests

releases/
  v1_release/           Earlier ordered-stream release
  v1.1_release/
  v2_release/
  v2.1_release/         Tile scheduler / double buffering release
  v3_release/           Final release flow with Mariani-Silver and burst writer

notebooks/
  Earlier exploration and bring-up notebooks

docs/
  Project planning and design notes
```

The top-level `fpga/rtl` and `ps` directories are the easiest places to read the current source. The `releases/` directories preserve buildable snapshots of the hardware design as it evolved.

## PL pipeline

### `tile_scheduler`

The scheduler converts the current view window into fixed-point complex-plane coordinates. It traverses the image in 32 x 16 tiles, emits jobs to available iteration cores, and carries a pixel index alongside each job.

For Julia mode, the pixel coordinate becomes the initial `z0`, while the selected Julia constant is passed as `c`. For Mandelbrot, Burning Ship, and Tricorn, the pixel coordinate is passed as `c` and `z0` starts at zero.

The scheduler also supports progressive scales. A coarse pass can render fewer sample points first, then later passes refine the image.

### `iter_core`

Each iteration core is a pipelined fixed-point datapath for:

```text
z(n + 1) = f(z(n))^2 + c
```

The transform `f` depends on the selected fractal:

```text
Mandelbrot / Julia:  f(z) = z
Burning Ship:        f(z) = abs(real(z)) + i abs(imag(z))
Tricorn:             f(z) = conjugate(z)
```

The core stops when the magnitude exceeds the escape radius or when `max_iter` is reached. The result is an iteration count plus escape/overflow flags.

### `iter_core_array`

The core array dispatches work across multiple `iter_core` instances and arbitrates their results back into a single stream. Results are allowed to return out of order.

### `colour_palette`

The palette maps iteration counts into RGB values. Palette selection and scaling are controlled from the PS so the same rendered scene can be displayed with different colour maps.

### `pixel_write_engine`

The writer receives coloured pixels and writes them into the DDR framebuffer using the pixel index carried through the pipeline.

```text
framebuffer_address = framebuffer_base + pixel_index * 4
```

This removes the need for the PL to emit pixels in display order. The VDMA reads from DDR independently and drives the HDMI output path.

## PS runtime

The Python side is responsible for the application shell rather than the fractal inner loop.

`ps/run_demo.py` builds a sequence of scenes:

```text
loading screen
  -> guided educational scenes
  -> PL Mandelbrot exploration
  -> PL Julia-link scene
  -> summary
  -> menu
  -> free-roam Mandelbrot / Julia / Burning Ship / Tricorn
  -> CPU vs Hardware comparison
```

The runtime manages:

- PYNQ overlay loading
- AXI-Lite register writes for scheduler, palette, writer, and VDMA
- framebuffer allocation, flushing, invalidation, and swapping
- controller packets from the external controller
- a keyboard fallback for development
- PS-rendered text/diagram scenes
- PL-rendered fractal scenes
- CPU baseline compilation and execution when comparison mode is used

## Running the Python smoke test

The scene manager has an off-board self-test path that checks the scene construction and placeholder render paths without requiring the FPGA overlay:

```bash
cd ps
python3 run_demo.py --self-test
```

## Running on PYNQ-Z1

On the board, the demo expects a matching `.bit`/`.hwh` overlay and the PYNQ Python environment.

Typical entry point:

```bash
cd ps
python3 run_demo.py --bit /path/to/fractalscope.bit
```

or, if the bitstream and `.hwh` are in the standard project directory:

```bash
cd ps
python3 run_demo.py --bit /home/xilinx/jupyter_notebooks/fractalscope
```

Useful options:

```bash
python3 run_demo.py --help
```

The runtime currently assumes the PL backend is configured for 1280 x 720 output.

## Rebuilding the Vivado project

The final hardware release is under:

```text
releases/v3_release/
```

From Vivado 2023.2, run:

```tcl
cd <repo>/releases/v3_release
source build_project.tcl
```

The build script creates the Vivado project, loads the local IP repository, sources the block-design script, generates the wrapper, and sets the block-design wrapper as the top module.

## CPU baseline

The CPU baseline is a separate C++ renderer used by the PS runtime for comparison scenes. It supports the same four fractal families and writes raw RGB output plus timing metadata.

The Python wrapper can compile it when needed, run it with the same view parameters, resize/pack the RGB frame for HDMI, and compare the result with the PL-rendered path.

## Design evolution

The release directories show the main architectural progression:

```text
v1 / v1.1:
    ordered streaming path with reorder buffer before display

v2 / v2.1:
    direct framebuffer writes, tile scheduling, double buffering,
    progressive rendering, and selectable palettes

v3:
    Mariani-Silver tile skipping, periodicity checking, 23-core build,
    and a redesigned pixel write engine for burst-oriented output
```

## Known limitations

- The hardware release is targeted specifically at PYNQ-Z1 / Zynq-7020.
- The display path is fixed around 1280 x 720 in the current PS backend.
- The project is a hardware accelerator demo, not a general-purpose graphics engine.
- Some older release directories are kept for history and are not the preferred starting point.
- The PS still owns UI drawing and orchestration; the PL owns the fractal render path.
- The exact run command on the board depends on where the `.bit` and `.hwh` files are installed.

## Why this project is interesting

Fractals are visually simple to explain but awkward enough to make the hardware design non-trivial. The renderer needs fixed-point arithmetic, control/status registers, AXI handshakes, framebuffer addressing, display timing, PS/PL synchronisation, and enough software around it to make the hardware usable.

That makes FractalScope a compact end-to-end FPGA project: not just an RTL block in isolation, and not just a Python visualisation, but a complete interactive system running on real hardware.
