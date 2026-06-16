#!/usr/bin/env python3
"""
shared hardware/display owner for the integrated walkthrough.
"""

from __future__ import annotations

import argparse
import time
from pathlib import Path
from typing import Callable, Iterable, Optional

import numpy as np


# Hardware/display constants from the working FractalScope v2 path

DEFAULT_BIT_PATH = "/home/xilinx/jupyter_notebooks/fractalscope"

WIDTH = 1280
HEIGHT = 720
BPP = 4
STRIDE = WIDTH * BPP
FRAME_PIXELS = WIDTH * HEIGHT
PANEL_WIDTH = 352
PANEL_HEIGHT = 160
ACTIVE_PIXELS = FRAME_PIXELS - 2 * (PANEL_WIDTH * PANEL_HEIGHT)
EDGE_GUARD_PX = 32

PALETTE_BITS = 10
PALETTE_SIZE = 1 << PALETTE_BITS
PALETTE_SCALE_FRAC = 16
PALETTE_COUNT = 8
PALETTE_NAMES = (
    "Classic rainbow",
    "Fire / magma",
    "Ice / cyan-blue",
    "Electric purple-blue",
    "Viridis-style",
    "Grayscale",
    "Sunset",
    "Deep ocean",
)

FIXED_FRAC_BITS = 22
FIXED_SCALE = 1 << FIXED_FRAC_BITS
FIXED_W = 26

MODE_MANDEL = 0
MODE_JULIA = 1
MODE_BURNING = 2
MODE_TRICORN = 3

MODE_NAMES = {
    MODE_MANDEL: "mandelbrot",
    MODE_JULIA: "julia",
    MODE_BURNING: "burning_ship",
    MODE_TRICORN: "tricorn",
}

BACKEND_VERSION = "2026-06-15-shared-pl-backend-v5-edge-guard-loading"


# pixel_write_engine_top AXI-Lite register offsets
WR_CONTROL = 0x00
WR_STATUS = 0x04
WR_FRAMEBUFFER_BASE = 0x08
WR_PIXELS_ACCEPTED = 0x0C
WR_PIXELS_WRITTEN = 0x10
WR_WRITE_ERRORS = 0x14
WR_FRAME_PIXELS = 0x18
WR_GEOMETRY = 0x1C

WR_START = 1 << 0
WR_ENABLE = 1 << 1
WR_SOFT_RESET = 1 << 2

# tile_scheduler_top AXI-Lite register offsets
SCH_X_JUMP = 0x00
SCH_Y_JUMP = 0x04
SCH_X_MIN = 0x08
SCH_Y_MIN = 0x0C
SCH_JUL_C_R = 0x10
SCH_JUL_C_I = 0x14
SCH_MODE_ITER = 0x18
SCH_CONTROL = 0x1C
SCH_RUN = 1 << 0

# AXI VDMA MM2S register offsets
MM2S_DMACR = 0x00
MM2S_DMASR = 0x04
PARK_PTR_REG = 0x28
MM2S_VSIZE = 0x50
MM2S_HSIZE = 0x54
MM2S_FRMDLY_STRIDE = 0x58
MM2S_START_ADDR1 = 0x5C
MM2S_START_ADDR2 = 0x60
MM2S_START_ADDR3 = 0x64

VDMA_DMACR_RUNSTOP = 1 << 0
VDMA_DMACR_RESET = 1 << 2

GPIO_CH1_DATA = 0x00
GPIO_CH1_TRI = 0x04
GPIO_CH2_DATA = 0x08
GPIO_CH2_TRI = 0x0C

HudCallback = Callable[[object, object, dict[str, int | float], int, bool], None]


# Small helpers
def resolve_bit_path(path_or_dir: str) -> Path:
    p = Path(path_or_dir).expanduser()
    if p.is_dir():
        candidates = sorted(p.glob("*.bit"), key=lambda x: x.stat().st_mtime, reverse=True)
        if not candidates:
            raise FileNotFoundError(f"No .bit file found in {p}")
        return candidates[0]
    if not p.exists():
        raise FileNotFoundError(str(p))
    if p.suffix != ".bit":
        raise ValueError(f"Expected a .bit file or directory, got {p}")
    return p


def find_ip_by_name_contains(ip_dict: dict, substr: str) -> str:
    matches = [name for name in ip_dict if substr.lower() in name.lower()]
    if not matches:
        raise RuntimeError(f"No IP name contains {substr!r}. Available: {list(ip_dict)}")
    return matches[0]


def find_optional_ip_by_name_contains(ip_dict: dict, *substrings: str) -> Optional[str]:
    for substr in substrings:
        matches = [name for name in ip_dict if substr.lower() in name.lower()]
        if matches:
            return matches[0]
    return None


def to_fixed_q4_22(value: float) -> int:
    raw = int(round(float(value) * FIXED_SCALE))
    min_val = -(1 << (FIXED_W - 1))
    max_val = (1 << (FIXED_W - 1)) - 1
    if raw < min_val or raw > max_val:
        raise ValueError(f"{value} converts to {raw}, outside signed {FIXED_W}-bit range")
    return raw & ((1 << FIXED_W) - 1)


def from_fixed_q4_22(raw: int) -> float:
    raw = int(raw) & ((1 << FIXED_W) - 1)
    if raw & (1 << (FIXED_W - 1)):
        raw -= 1 << FIXED_W
    return raw / FIXED_SCALE


def pack_mode_iter(mode: int, max_iter: int) -> int:
    return ((int(mode) & 0x7) << 16) | (int(max_iter) & 0xFFFF)


def compute_palette_scale(max_iter: int) -> int:
    max_iter = int(max_iter)
    if max_iter <= 1:
        return 0
    numerator = (PALETTE_SIZE - 1) << PALETTE_SCALE_FRAC
    denominator = max_iter - 1
    return int((numerator + denominator - 1) // denominator) & 0xFFFFFFFF


def parse_scales(text: str) -> tuple[int, ...]:
    vals: list[int] = []
    for part in str(text).split(","):
        part = part.strip()
        if not part:
            continue
        scale = int(part)
        if scale <= 0:
            raise ValueError("Render scales must be positive integers")
        if 32 % scale != 0 or 16 % scale != 0:
            raise ValueError("Render scales must divide both 32 and 16 for the current tile scheduler")
        vals.append(scale)
    if not vals:
        raise ValueError("At least one render scale is required")
    return tuple(vals)


def expected_active_writes_for_scale(scale: int) -> int:
    """Number of writer completions produced by one sparse progressive pass."""
    scale = int(scale)
    if scale <= 0 or 32 % scale != 0 or 16 % scale != 0:
        raise ValueError("Render scale must divide both 32 and 16")
    return ACTIVE_PIXELS // (scale * scale)


def decode_vdma_status(status: int) -> list[str]:
    flags = []
    if status & (1 << 0):
        flags.append("HALTED")
    if status & (1 << 1):
        flags.append("VDMA_INTERNAL_ERR")
    if status & (1 << 4):
        flags.append("SLAVE_ERR")
    if status & (1 << 5):
        flags.append("DECODE_ERR")
    if status & (1 << 8):
        flags.append("SOF_EARLY_ERR")
    if status & (1 << 12):
        flags.append("FRAME_COUNT_IRQ")
    if status & (1 << 13):
        flags.append("DELAY_COUNT_IRQ")
    if status & (1 << 14):
        flags.append("ERROR_IRQ")
    if status & (1 << 16):
        flags.append("PARKED_OR_FRAME_SYNC")
    return flags


def clear_hud_panels(fb) -> None:
    raw = np.asarray(fb)
    raw[0:PANEL_HEIGHT, 0:PANEL_WIDTH] = 0x00000000
    raw[0:PANEL_HEIGHT, WIDTH - PANEL_WIDTH:WIDTH] = 0x00000000


def copy_hud_panels(src_fb, dst_fb) -> None:
    src = np.asarray(src_fb)
    dst = np.asarray(dst_fb)
    dst[0:PANEL_HEIGHT, 0:PANEL_WIDTH] = src[0:PANEL_HEIGHT, 0:PANEL_WIDTH]
    dst[0:PANEL_HEIGHT, WIDTH - PANEL_WIDTH:WIDTH] = src[0:PANEL_HEIGHT, WIDTH - PANEL_WIDTH:WIDTH]


def expand_sparse_progressive_pass(fb, scale: int) -> None:
    """Turn one sparse hardware sample per scale block into a readable preview."""
    scale = int(scale)
    if scale <= 1:
        return

    raw = np.asarray(fb)
    samples = raw[0:HEIGHT:scale, 0:WIDTH:scale].copy()
    expanded = np.repeat(np.repeat(samples, scale, axis=0), scale, axis=1)
    raw[:, :] = expanded[0:HEIGHT, 0:WIDTH]


def repair_edge_wrap_guard(fb) -> None:
    """Mask occasional one-tile edge wrap artefacts before the frame is shown."""
    raw = np.asarray(fb)
    if raw.shape[1] < (2 * EDGE_GUARD_PX + 2):
        return
    raw[:, :EDGE_GUARD_PX] = raw[:, EDGE_GUARD_PX:EDGE_GUARD_PX + 1]
    raw[:, WIDTH - EDGE_GUARD_PX:WIDTH] = raw[:, WIDTH - EDGE_GUARD_PX - 1:WIDTH - EDGE_GUARD_PX]


# Shared PL/HDMI backend

class PlWalkthroughBackend:
    def __init__(self, args: argparse.Namespace) -> None:
        from pynq import MMIO, Overlay, allocate  # imported here so self-tests work off-board

        self.args = args
        self.bit_path = resolve_bit_path(args.bit)
        self.wait_pixels = FRAME_PIXELS if args.wait_frame_pixels else ACTIVE_PIXELS
        self.scales = parse_scales(args.scales)
        self.interaction_scales = parse_scales(args.interaction_scales)
        self.refine_scales = parse_scales(args.refine_scales)
        self.palette_scale_mmio = None
        self.palette_select_mmio = None
        self.current_front_idx = 0
        self.last_park_time = 0.0
        self.swap_framebuffers = bool(args.swap_framebuffers)
        self.buffer_count = 2

        print(f"Shared PL backend version: {BACKEND_VERSION}")
        print("Configured for:")
        print(f"  bitstream:  {self.bit_path}")
        print(f"  resolution: {WIDTH}x{HEIGHT}")
        print(f"  bpp:        {BPP}")
        print(f"  stride:     {STRIDE}")
        print(f"  pixels:     {FRAME_PIXELS}")
        print(f"  active:     {ACTIVE_PIXELS}")
        print(f"  frame size: {FRAME_PIXELS * BPP} bytes")
        print(f"  fixed:      Q4.{FIXED_FRAC_BITS} in {FIXED_W} bits")
        print(f"  palette:    {PALETTE_SIZE} entries, scale frac={PALETTE_SCALE_FRAC}")
        print(f"  scales:     {self.scales}")
        print(f"  interaction:{self.interaction_scales}")
        print(f"  refine:     {self.refine_scales} after {args.refine_idle_s:.2f}s idle")
        print(f"  display:    {'VDMA framebuffer swaps' if self.swap_framebuffers else 'fixed VDMA buffer with PS commit copy'}")

        self.overlay = Overlay(str(self.bit_path), download=not args.no_download)
        if args.no_download:
            print("Overlay metadata loaded without downloading bitstream")
        else:
            print("Loaded overlay:", self.bit_path)

        print("\nDetected IP blocks:")
        for name, info in self.overlay.ip_dict.items():
            base = info.get("phys_addr", 0)
            rng = info.get("addr_range", 0)
            print(f"  {name:45s} @ 0x{base:08X}, range=0x{rng:X}")

        vdma_ip = find_ip_by_name_contains(self.overlay.ip_dict, "axi_vdma")
        writer_ip = find_ip_by_name_contains(self.overlay.ip_dict, "pixel_write_engine")
        scheduler_ip = find_ip_by_name_contains(self.overlay.ip_dict, "tile_scheduler")

        if args.palette_scale_ip:
            palette_scale_ip = args.palette_scale_ip
        elif "axi_gpio_4" in self.overlay.ip_dict:
            palette_scale_ip = "axi_gpio_4"
        else:
            palette_scale_ip = find_optional_ip_by_name_contains(
                self.overlay.ip_dict,
                "palette_scale",
                "palette_gpio",
                "axi_gpio_palette",
            )

        if args.palette_select_ip:
            palette_select_ip = args.palette_select_ip
        elif palette_scale_ip:
            palette_select_ip = palette_scale_ip
        else:
            palette_select_ip = find_optional_ip_by_name_contains(
                self.overlay.ip_dict,
                "palette_select",
                "palette_mode",
                "palette_index",
            )

        print("\nUsing:")
        print("  VDMA IP:      ", vdma_ip, hex(self.overlay.ip_dict[vdma_ip]["phys_addr"]))
        print("  Writer IP:    ", writer_ip, hex(self.overlay.ip_dict[writer_ip]["phys_addr"]))
        print("  Scheduler IP: ", scheduler_ip, hex(self.overlay.ip_dict[scheduler_ip]["phys_addr"]))

        self.vdma = MMIO(self.overlay.ip_dict[vdma_ip]["phys_addr"], self.overlay.ip_dict[vdma_ip]["addr_range"])
        self.writer = MMIO(self.overlay.ip_dict[writer_ip]["phys_addr"], self.overlay.ip_dict[writer_ip]["addr_range"])
        self.sched = MMIO(self.overlay.ip_dict[scheduler_ip]["phys_addr"], self.overlay.ip_dict[scheduler_ip]["addr_range"])

        if palette_scale_ip and palette_scale_ip in self.overlay.ip_dict:
            self.palette_scale_mmio = MMIO(
                self.overlay.ip_dict[palette_scale_ip]["phys_addr"],
                self.overlay.ip_dict[palette_scale_ip]["addr_range"],
            )
            print("  Palette scale:", palette_scale_ip, hex(self.overlay.ip_dict[palette_scale_ip]["phys_addr"]), "channel 1")
        else:
            print("  Palette scale: no dedicated AXI GPIO/register block detected")

        if palette_select_ip and palette_select_ip in self.overlay.ip_dict:
            self.palette_select_mmio = MMIO(
                self.overlay.ip_dict[palette_select_ip]["phys_addr"],
                self.overlay.ip_dict[palette_select_ip]["addr_range"],
            )
            print("  Palette select:", palette_select_ip, hex(self.overlay.ip_dict[palette_select_ip]["phys_addr"]), "channel 2")
        else:
            print("  Palette select: no hardware select block detected")

        self.fb = [allocate(shape=(HEIGHT, WIDTH), dtype=np.uint32) for _ in range(self.buffer_count)]
        for idx, fb in enumerate(self.fb):
            print(f"Framebuffer {idx}:")
            print("  physical address:", hex(fb.physical_address))
            print("  nbytes:          ", fb.nbytes)
            if fb.nbytes != FRAME_PIXELS * BPP:
                raise RuntimeError(f"Framebuffer {idx} has unexpected size {fb.nbytes}")
            fb[:] = 0x00000000
            clear_hud_panels(fb)
            fb.flush()

        self._sanity_check_writer_geometry()
        self.start_mm2s()

    def close(self) -> None:
        try:
            self.hold_scheduler_reset()
            self.stop_writer()
        except Exception:
            pass

    def _sanity_check_writer_geometry(self) -> None:
        # WR_FRAME_PIXELS is a writable runtime target in the current writer RTL.
        self.writer.write(WR_FRAME_PIXELS, FRAME_PIXELS)
        geom = self.writer.read(WR_GEOMETRY)
        frame_pixels = self.writer.read(WR_FRAME_PIXELS)
        expected_geom = (HEIGHT << 16) | WIDTH
        print("\nWriter geometry:")
        print(f"  FRAME_PIXELS = {frame_pixels} expected {FRAME_PIXELS}")
        print(f"  GEOMETRY     = 0x{geom:08X} expected 0x{expected_geom:08X}")
        if frame_pixels != FRAME_PIXELS:
            raise RuntimeError("WR_FRAME_PIXELS does not match the script resolution")
        if geom != expected_geom:
            raise RuntimeError("WR_GEOMETRY does not match the script resolution")

    def reset_mm2s(self, timeout_s: float = 1.0) -> bool:
        self.vdma.write(MM2S_DMACR, VDMA_DMACR_RESET)
        t0 = time.time()
        while time.time() - t0 < timeout_s:
            if (self.vdma.read(MM2S_DMACR) & VDMA_DMACR_RESET) == 0:
                return True
            time.sleep(0.001)
        return False

    def show_mm2s(self) -> None:
        cr = self.vdma.read(MM2S_DMACR)
        sr = self.vdma.read(MM2S_DMASR)
        print(f"MM2S_DMACR       = 0x{cr:08X}")
        print(f"MM2S_DMASR       = 0x{sr:08X} {decode_vdma_status(sr)}")
        print(f"MM2S_START_ADDR1 = 0x{self.vdma.read(MM2S_START_ADDR1):08X}")
        print(f"MM2S_START_ADDR2 = 0x{self.vdma.read(MM2S_START_ADDR2):08X}")
        print(f"MM2S_START_ADDR3 = 0x{self.vdma.read(MM2S_START_ADDR3):08X}")
        print(f"MM2S_HSIZE       = {self.vdma.read(MM2S_HSIZE)}")
        print(f"MM2S_STRIDE      = {self.vdma.read(MM2S_FRMDLY_STRIDE) & 0xFFFF}")
        print(f"MM2S_VSIZE       = {self.vdma.read(MM2S_VSIZE)}")

    def repin_fixed_display_buffer(self) -> None:
        """
        Force VDMA MM2S to read only the fixed front framebuffer.

        The free-roam scenes do several PL renders per interaction because of
        progressive refinement.  If the VDMA ever keeps a stale frame-store
        address or park pointer from an earlier scene/pass, it can briefly read
        the render/back buffer and the HDMI output looks like the right edge has
        wrapped onto the left.  In fixed-display mode, framebuffer 0 is the only
        legal display buffer; PL renders go to framebuffer 1 and are copied here
        only after the frame is complete.
        """
        if self.swap_framebuffers:
            return

        self.current_front_idx = 0
        front_addr = self.fb[0].physical_address
        self.vdma.write(MM2S_START_ADDR1, front_addr)
        self.vdma.write(MM2S_START_ADDR2, front_addr)
        self.vdma.write(MM2S_START_ADDR3, front_addr)
        self.vdma.write(PARK_PTR_REG, 0)
        self.last_park_time = time.time()

    def start_mm2s(self) -> None:
        print("\nResetting MM2S...")
        ok = self.reset_mm2s()
        print("MM2S reset ok:", ok)
        self.show_mm2s()

        self.vdma.write(MM2S_DMASR, 0x0000FFFF)

        if self.swap_framebuffers:
            self.vdma.write(MM2S_START_ADDR1, self.fb[0].physical_address)
            self.vdma.write(MM2S_START_ADDR2, self.fb[1].physical_address)
            self.vdma.write(MM2S_START_ADDR3, self.fb[0].physical_address)
        else:
            self.repin_fixed_display_buffer()

        self.vdma.write(MM2S_DMACR, VDMA_DMACR_RUNSTOP)
        if self.swap_framebuffers:
            self.vdma.write(PARK_PTR_REG, int(self.current_front_idx))
            self.last_park_time = time.time()
        else:
            self.repin_fixed_display_buffer()
        self.vdma.write(MM2S_FRMDLY_STRIDE, STRIDE)
        self.vdma.write(MM2S_HSIZE, STRIDE)
        self.vdma.write(MM2S_VSIZE, HEIGHT)
        time.sleep(0.1)
        if not self.swap_framebuffers:
            self.repin_fixed_display_buffer()
        print("\nAfter MM2S start:")
        self.show_mm2s()

    def show_ps_frame(self, packed_rgb: np.ndarray) -> None:
        if packed_rgb.shape != (HEIGHT, WIDTH):
            raise ValueError(f"Expected frame shape {(HEIGHT, WIDTH)}, got {packed_rgb.shape}")
        if packed_rgb.dtype != np.uint32:
            packed_rgb = packed_rgb.astype(np.uint32)

        if self.swap_framebuffers:
            back_idx = 1 - self.current_front_idx
            back_fb = self.fb[back_idx]
            back_fb[:] = packed_rgb
            back_fb.flush()
            self.park_framebuffer(back_idx)
            return

        self.repin_fixed_display_buffer()
        front_fb = self.fb[0]
        front_fb[:] = packed_rgb
        front_fb.flush()
        self.repin_fixed_display_buffer()

    # Alias used by the scene manager.
    show_packed_frame = show_ps_frame

    def commit_rendered_framebuffer(self, source_idx: int) -> None:
        if self.swap_framebuffers:
            self.park_framebuffer(source_idx)
            return

        # Fixed-display mode: only fb0 is ever displayed.  The PL render is
        # complete in source_idx, then the PS copies that completed image into
        # fb0.  Re-pin around the copy to guard against stale VDMA state left by
        # earlier scene transitions or progressive refinement passes.
        self.repin_fixed_display_buffer()
        if source_idx == 0:
            self.fb[0].flush()
            self.repin_fixed_display_buffer()
            return

        src_fb = self.fb[source_idx]
        front_fb = self.fb[0]
        front_fb[:] = np.asarray(src_fb)
        front_fb.flush()
        self.repin_fixed_display_buffer()

    def reset_writer(self) -> None:
        self.writer.write(WR_CONTROL, WR_SOFT_RESET)
        time.sleep(0.001)
        self.writer.write(WR_CONTROL, 0x0)
        time.sleep(0.001)

    def start_writer(self, scale: int = 1) -> None:
        self.writer.write(WR_CONTROL, WR_ENABLE | WR_START)
        time.sleep(0.001)
        self.writer.write(WR_CONTROL, WR_ENABLE)

    def stop_writer(self) -> None:
        self.writer.write(WR_CONTROL, 0x0)

    def hold_scheduler_reset(self) -> None:
        self.sched.write(SCH_CONTROL, 0x0)
        time.sleep(0.001)

    def start_scheduler(self, scale: int = 1) -> None:
        self.sched.write(SCH_CONTROL, SCH_RUN | (int(scale) << 4))

    def program_palette_scale(self, max_iter: int, verbose: bool = False) -> int:
        scale = compute_palette_scale(max_iter)
        if self.palette_scale_mmio is not None:
            try:
                self.palette_scale_mmio.write(GPIO_CH1_TRI, 0x00000000)
            except Exception as exc:
                print(f"WARNING: could not write palette-scale GPIO TRI register: {exc}")
            self.palette_scale_mmio.write(GPIO_CH1_DATA, scale)
            readback = self.palette_scale_mmio.read(GPIO_CH1_DATA)
            if verbose:
                print(f"  palette_scale = 0x{scale:08X}, readback = 0x{int(readback):08X}")
        elif verbose:
            print(f"  palette_scale = 0x{scale:08X}, not hardware-programmed")
        return scale

    def program_palette_select(self, palette_index: int) -> bool:
        if self.palette_select_mmio is None:
            return False
        palette_id = int(palette_index) % PALETTE_COUNT
        try:
            self.palette_select_mmio.write(GPIO_CH2_TRI, 0x00000000)
        except Exception:
            pass
        self.palette_select_mmio.write(GPIO_CH2_DATA, palette_id)
        return True

    def program_scheduler_view(self, *, state: object, mode: int) -> None:
        center_r = float(getattr(state, "center_r", -0.75))
        center_i = float(getattr(state, "center_i", 0.0))
        x_width = float(getattr(state, "x_width", 3.5))
        max_iter = int(getattr(state, "max_iter", 128))

        y_width = x_width * HEIGHT / WIDTH
        x_min = center_r - x_width / 2.0
        y_min = center_i - y_width / 2.0
        x_jump = x_width / WIDTH
        y_jump = y_width / HEIGHT

        julia_c_r = float(getattr(state, "julia_c_r", -0.8))
        julia_c_i = float(getattr(state, "julia_c_i", 0.156))

        self.sched.write(SCH_X_JUMP, to_fixed_q4_22(x_jump))
        self.sched.write(SCH_Y_JUMP, to_fixed_q4_22(y_jump))
        self.sched.write(SCH_X_MIN, to_fixed_q4_22(x_min))
        self.sched.write(SCH_Y_MIN, to_fixed_q4_22(y_min))
        self.sched.write(SCH_JUL_C_R, to_fixed_q4_22(julia_c_r))
        self.sched.write(SCH_JUL_C_I, to_fixed_q4_22(julia_c_i))
        self.sched.write(SCH_MODE_ITER, pack_mode_iter(mode, max_iter))
        self.program_palette_scale(max_iter, verbose=False)
        self.program_palette_select(int(getattr(state, "palette_index", 0)))

    def poll_writer(self, target_writes: int, timeout_s: float, print_every: float = 0.4) -> dict[str, int | float]:
        target_writes = max(1, int(target_writes))
        t0 = time.time()
        next_print = t0 if self.args.verbose_render else t0 + 10**9
        while True:
            now = time.time()
            status = self.writer.read(WR_STATUS)
            accepted = self.writer.read(WR_PIXELS_ACCEPTED)
            written = self.writer.read(WR_PIXELS_WRITTEN)
            errors = self.writer.read(WR_WRITE_ERRORS)

            if now >= next_print:
                print(
                    f"t={now-t0:7.3f}s status=0x{status:08X} "
                    f"accepted={accepted:7d} written={written:7d}/{target_writes:7d} errors={errors}"
                )
                next_print = now + print_every

            if written >= target_writes:
                break
            if errors != 0:
                break
            if now - t0 > self.args.timeout_s:
                print("Render timeout.")
                break
            time.sleep(0.005)

        elapsed = time.time() - t0
        return {
            "elapsed": elapsed,
            "accepted": int(self.writer.read(WR_PIXELS_ACCEPTED)),
            "written": int(self.writer.read(WR_PIXELS_WRITTEN)),
            "errors": int(self.writer.read(WR_WRITE_ERRORS)),
            "status": int(self.writer.read(WR_STATUS)),
            "target_writes": target_writes,
        }

    def park_framebuffer(self, frame_idx: int) -> None:
        self.vdma.write(PARK_PTR_REG, int(frame_idx))
        self.last_park_time = time.time()
        if self.args.swap_guard_s > 0.0:
            time.sleep(self.args.swap_guard_s)
        self.current_front_idx = int(frame_idx)

    def render_fractal(
        self,
        *,
        state: object,
        mode: int,
        scales: Optional[Iterable[int]] = None,
        draw_overlay: Optional[bool] = None,
        hud_callback: Optional[HudCallback] = None,
        label: str = "render",
    ) -> dict[str, int | float]:
        active_scales = tuple(scales) if scales is not None else self.scales
        if not active_scales:
            raise ValueError("render_fractal needs at least one scale")

        if draw_overlay is None:
            draw_overlay = bool(getattr(state, "hud_visible", True))

        if hasattr(state, "render_count"):
            state.render_count += 1
        render_count = int(getattr(state, "render_count", 0))
        start = time.time()
        final_result: dict[str, int | float] = {
            "elapsed": 0.0,
            "accepted": 0,
            "written": 0,
            "errors": 0,
            "status": 0,
        }

        mode_name = MODE_NAMES.get(int(mode), f"mode_{mode}")
        center_r = float(getattr(state, "center_r", 0.0))
        center_i = float(getattr(state, "center_i", 0.0))
        x_width = float(getattr(state, "x_width", 0.0))
        max_iter = int(getattr(state, "max_iter", 0))
        extra = ""
        if mode == MODE_JULIA:
            extra = f" c=({float(getattr(state, 'julia_c_r', -0.8)):+.6f}, {float(getattr(state, 'julia_c_i', 0.156)):+.6f})"
        print(
            f"\n{label.capitalize()} {render_count}: {mode_name}{extra} "
            f"center=({center_r:+.9f}, {center_i:+.9f}) width={x_width:.9g} "
            f"max_iter={max_iter} scales={active_scales}"
        )

        for scale in active_scales:
            target_writes = expected_active_writes_for_scale(scale)
            if self.swap_framebuffers:
                back_idx = 1 - self.current_front_idx
            else:
                self.repin_fixed_display_buffer()
                back_idx = 1
            back_fb = self.fb[back_idx]

            self.hold_scheduler_reset()
            self.reset_writer()
            self.writer.write(WR_FRAME_PIXELS, target_writes)
            self.writer.write(WR_FRAMEBUFFER_BASE, back_fb.physical_address)
            self.start_writer(scale=scale)
            self.program_scheduler_view(state=state, mode=mode)
            self.start_scheduler(scale=scale)

            result = self.poll_writer(target_writes=target_writes, timeout_s=self.args.timeout_s)
            self.hold_scheduler_reset()
            final_result = result

            if hasattr(state, "last_render_s"):
                state.last_render_s = time.time() - start
            if hasattr(state, "last_written"):
                state.last_written = int(result.get("written", 0))
            if hasattr(state, "last_errors"):
                state.last_errors = int(result.get("errors", 0))

            try:
                back_fb.invalidate()
            except Exception:
                pass
            expand_sparse_progressive_pass(back_fb, scale)
            repair_edge_wrap_guard(back_fb)

            if draw_overlay and hud_callback is not None:
                hud_callback(back_fb, state, result, scale, self.palette_select_mmio is not None)
            elif bool(getattr(state, "hud_visible", True)):
                copy_hud_panels(self.fb[self.current_front_idx], back_fb)
            else:
                clear_hud_panels(back_fb)

            back_fb.flush()
            self.commit_rendered_framebuffer(back_idx)

            if result["errors"] or int(result["written"]) < target_writes:
                break

        elapsed = time.time() - start
        if hasattr(state, "last_render_s"):
            state.last_render_s = elapsed
        if hasattr(state, "last_written"):
            state.last_written = int(final_result.get("written", 0))
        if hasattr(state, "last_errors"):
            state.last_errors = int(final_result.get("errors", 0))
        if hasattr(state, "dirty"):
            state.dirty = False

        print(
            f"Done: {elapsed:.3f}s, written={int(final_result.get('written', 0))}, "
            f"errors={int(final_result.get('errors', 0))}, front=fb{self.current_front_idx}"
        )
        return final_result

    def render_mandelbrot(self, state: object, **kwargs) -> dict[str, int | float]:
        return self.render_fractal(state=state, mode=MODE_MANDEL, **kwargs)

    def render_julia_link(self, state: object, **kwargs) -> dict[str, int | float]:
        return self.render_fractal(state=state, mode=MODE_JULIA, **kwargs)


def add_backend_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--scales", default="8,4,2,1", help="initial/full progressive PL render scales")
    parser.add_argument("--interaction-scales", default="8", help="PL scales rendered immediately after input")
    parser.add_argument("--refine-scales", default="4,2,1", help="PL scales rendered after input has been idle")
    parser.add_argument("--refine-idle-s", type=float, default=0.35, help="seconds of no input before refinement")
    parser.add_argument("--hud-during-interaction", dest="hud_during_interaction", action="store_true", default=True)
    parser.add_argument("--no-hud-during-interaction", dest="hud_during_interaction", action="store_false")
    parser.add_argument(
        "--swap-framebuffers",
        action="store_true",
        help="debug only: use old VDMA park-pointer swaps instead of the fixed-display commit path",
    )
    parser.add_argument(
        "--swap-guard-s",
        type=float,
        default=0.070,
        help="delay after parking VDMA on a new buffer; only used with --swap-framebuffers",
    )
    parser.add_argument("--timeout-s", type=float, default=30.0)
    parser.add_argument("--wait-frame-pixels", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--palette-scale-ip", default="", help="override palette-scale AXI GPIO/IP name")
    parser.add_argument("--palette-select-ip", default="", help="optional palette-select AXI GPIO/IP name")
    parser.add_argument("--verbose-render", action="store_true")
    parser.add_argument("--no-initial-render", action="store_true")


def self_test() -> None:
    assert FIXED_FRAC_BITS == 22
    assert abs(from_fixed_q4_22(to_fixed_q4_22(-0.8)) + 0.8) < 1e-5
    assert abs(from_fixed_q4_22(to_fixed_q4_22(0.156)) - 0.156) < 1e-5
    expected = ((PALETTE_SIZE - 1) << PALETTE_SCALE_FRAC)
    expected = (expected + 126) // 127
    assert compute_palette_scale(128) == expected
    assert parse_scales("8,4,2,1") == (8, 4, 2, 1)
    assert expected_active_writes_for_scale(8) == 12640
    assert expected_active_writes_for_scale(4) == 50560
    assert expected_active_writes_for_scale(2) == 202240
    assert expected_active_writes_for_scale(1) == ACTIVE_PIXELS
    print("PL backend self-test passed.")


if __name__ == "__main__":
    self_test()
