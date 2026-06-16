#!/usr/bin/env python3
"""
Mandelbrot Visualisation
"""

from __future__ import annotations

import argparse
import math
import os
import select
import sys
import termios
import time
import tty
from dataclasses import dataclass, field
from enum import Enum, auto
from pathlib import Path
from typing import Iterable, Optional

import numpy as np


# Hardware/display constants from the working v2.1 notebook

DEFAULT_BIT_PATH = "/home/xilinx/jupyter_notebooks/fractalscope"

WIDTH = 1280
HEIGHT = 720
BPP = 4
STRIDE = WIDTH * BPP
FRAME_PIXELS = WIDTH * HEIGHT
PANEL_WIDTH = 352
PANEL_HEIGHT = 160
ACTIVE_PIXELS = FRAME_PIXELS - 2 * (PANEL_WIDTH * PANEL_HEIGHT)

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

SCENE5_HDMI_VERSION = "2026-06-11-v7-repin-fixed-display"

MODE_NAMES = {
    MODE_MANDEL: "mandelbrot",
    MODE_JULIA: "julia",
    MODE_BURNING: "burning_ship",
    MODE_TRICORN: "tricorn",
}

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


# Logical event layer
class EventKind(Enum):
    NEXT = auto()
    BACK = auto()
    PAN = auto()
    ZOOM = auto()
    ITER = auto()
    RESET = auto()
    CYCLE_PALETTE = auto()
    TOGGLE_HUD = auto()
    TOGGLE_FINE = auto()
    MENU = auto()
    RENDER = auto()
    QUIT = auto()


@dataclass(frozen=True)
class Event:
    kind: EventKind
    value: object = None


class AppPhase(Enum):
    INTRO = auto()
    INTERACTIVE = auto()


@dataclass(frozen=True)
class IntroSlide:
    title: str
    groups: tuple[str, ...]
    formula: Optional[str] = None


INTRO_SLIDES = (
    IntroSlide(
        title="The full Mandelbrot image",
        groups=(
            "Every pixel is a different value of c.",
            "For each c, start at z = 0 and repeat the same rule.",
            "The PL checks many orbits so the whole image can appear quickly.",
        ),
        formula="z → z² + c",
    ),
    IntroSlide(
        title="Bounded or escaped",
        groups=(
            "If the orbit stays inside the escape circle, keep that pixel dark.",
            "If it escapes, colour the pixel by how long it survived.",
            "The boundary between those behaviours is where the detail lives.",
        ),
        formula="escape time → colour",
    ),
    IntroSlide(
        title="Now explore the hardware render",
        groups=(
            "Use the joystick to pan around the set.",
            "Use the encoder to zoom and change max iterations.",
            "The FPGA writes the rendered image into DDR for HDMI display.",
        ),
        formula=None,
    ),
)


def current_intro_slide(state: "Scene5State") -> IntroSlide:
    return INTRO_SLIDES[state.intro_index]


def intro_item_count(slide: IntroSlide) -> int:
    return len(slide.groups) + (1 if slide.formula else 0)


def fade_complete(state: "Scene5State", now: float, fade_s: float) -> bool:
    return now - state.intro_fade_start >= fade_s


@dataclass
class Scene5State:
    phase: AppPhase = AppPhase.INTRO
    intro_index: int = 0
    intro_progress: int = 1
    intro_fade_start: float = 0.0

    center_r: float = -0.75
    center_i: float = 0.0
    x_width: float = 3.5
    max_iter: int = 128
    palette_index: int = 0
    hud_visible: bool = True
    fine_control: bool = False
    dirty: bool = True
    quit_requested: bool = False
    transition_request: Optional[str] = None
    last_message: str = "Mandelbrot exploration ready"
    last_render_s: float = 0.0
    last_written: int = 0
    last_errors: int = 0
    render_count: int = 0
    palette_names: tuple[str, ...] = PALETTE_NAMES

    def enter_interactive(self) -> None:
        self.phase = AppPhase.INTERACTIVE
        self.dirty = True
        self.last_message = "Mandelbrot exploration ready"

    def reset_view(self) -> None:
        self.center_r = -0.75
        self.center_i = 0.0
        self.x_width = 3.5
        self.max_iter = 128
        self.dirty = True
        self.last_message = "View reset"

    def clamp_view(self) -> None:
        self.x_width = min(max(self.x_width, 1.0e-9), 5.0)
        self.max_iter = min(max(int(self.max_iter), 16), 4096)
        self.center_r = min(max(self.center_r, -4.0), 4.0)
        self.center_i = min(max(self.center_i, -4.0), 4.0)


class Scene5Mandelbrot:
    def __init__(self, state: Optional[Scene5State] = None, fade_s: float = 0.55) -> None:
        self.state = state or Scene5State()
        self.fade_s = fade_s
        self.state.intro_fade_start = time.time()

    def handle_event(self, event: Event) -> None:
        s = self.state

        if event.kind is EventKind.QUIT:
            s.quit_requested = True
            return

        if s.phase is AppPhase.INTRO:
            self._handle_intro_event(event)
            return

        self._handle_interactive_event(event)

    def _handle_intro_event(self, event: Event) -> None:
        s = self.state
        now = time.time()
        slide = current_intro_slide(s)

        if event.kind is EventKind.NEXT:
            if not fade_complete(s, now, self.fade_s):
                s.intro_fade_start = now - self.fade_s
            elif s.intro_progress < intro_item_count(slide):
                s.intro_progress += 1
                s.intro_fade_start = now
            elif s.intro_index < len(INTRO_SLIDES) - 1:
                s.intro_index += 1
                s.intro_progress = 1
                s.intro_fade_start = now
            else:
                s.enter_interactive()
            s.dirty = True
            return

        if event.kind is EventKind.BACK:
            if s.intro_progress > 1:
                s.intro_progress -= 1
                s.intro_fade_start = now - self.fade_s
            elif s.intro_index > 0:
                s.intro_index -= 1
                s.intro_progress = intro_item_count(current_intro_slide(s))
                s.intro_fade_start = now - self.fade_s
            else:
                s.transition_request = "back"
                s.last_message = "Back scene requested"
            s.dirty = True
            return

        if event.kind is EventKind.TOGGLE_HUD:
            # During the intro, Space/Button 3 means reveal, matching Scene 6.
            s.intro_progress = intro_item_count(slide)
            s.intro_fade_start = now - self.fade_s
            s.dirty = True
            return

        if event.kind is EventKind.CYCLE_PALETTE:
            s.palette_index = (s.palette_index + 1) % len(s.palette_names)
            s.dirty = True
            return

        if event.kind is EventKind.MENU:
            s.last_message = "Menu comes after the guided walkthrough endpoint."
            return

    def _handle_interactive_event(self, event: Event) -> None:
        s = self.state

        if event.kind is EventKind.NEXT:
            s.transition_request = "next"
            s.last_message = "Next scene requested"
            return

        if event.kind is EventKind.BACK:
            s.phase = AppPhase.INTRO
            s.intro_index = len(INTRO_SLIDES) - 1
            s.intro_progress = intro_item_count(current_intro_slide(s))
            s.intro_fade_start = time.time() - self.fade_s
            s.last_message = "Back to Mandelbrot explanation"
            s.dirty = True
            return

        if event.kind is EventKind.MENU:
            s.last_message = "Menu requested; global menu is not wired in this standalone script"
            return

        if event.kind is EventKind.RESET:
            s.reset_view()
            return

        if event.kind is EventKind.PAN:
            dx, dy = event.value or (0.0, 0.0)
            speed = 0.025 if s.fine_control else 0.075
            step = s.x_width * speed
            s.center_r += float(dx) * step
            # Positive dy means "up" in the logical event layer, but the
            # current framebuffer/complex-plane mapping makes increasing
            # center_i feel visually reversed on HDMI.
            s.center_i -= float(dy) * step
            s.clamp_view()
            s.dirty = True
            s.last_message = f"Pan to ({s.center_r:.6f}, {s.center_i:.6f})"
            return

        if event.kind is EventKind.ZOOM:
            delta = float(event.value or 0.0)
            if delta == 0.0:
                return
            key_factor = 0.88 if s.fine_control else 0.78
            if delta > 0:
                s.x_width *= key_factor ** abs(delta)
            else:
                s.x_width /= key_factor ** abs(delta)
            s.clamp_view()
            s.dirty = True
            s.last_message = f"Zoom width {s.x_width:.6g}"
            return

        if event.kind is EventKind.ITER:
            delta = int(event.value or 0)
            if delta == 0:
                return
            step = 8 if s.fine_control else 16
            s.max_iter += delta * step
            s.clamp_view()
            s.dirty = True
            s.last_message = f"max_iter {s.max_iter}"
            return

        if event.kind is EventKind.CYCLE_PALETTE:
            s.palette_index = (s.palette_index + 1) % len(s.palette_names)
            s.dirty = True
            s.last_message = f"Palette control: {s.palette_names[s.palette_index]}"
            return

        if event.kind is EventKind.TOGGLE_HUD:
            s.hud_visible = not s.hud_visible
            s.dirty = True
            s.last_message = "HUD on" if s.hud_visible else "HUD off"
            return

        if event.kind is EventKind.TOGGLE_FINE:
            s.fine_control = not s.fine_control
            s.last_message = "Fine controls on" if s.fine_control else "Coarse controls on"
            return

        if event.kind is EventKind.RENDER:
            s.dirty = True
            s.last_message = "Manual render requested"
            return


class Scene5IntroRenderer:
    def __init__(self, fade_s: float = 0.55) -> None:
        self.fade_s = fade_s
        self.bg = (7, 9, 13)
        self.white = (242, 244, 247)
        self.dim = (166, 174, 184)
        self.accent = (80, 230, 230)
        self.panel = (13, 18, 26)
        self.font_small = self._load_font(15)
        self.font_large = self._load_font(42)
        self.font_xlarge = self._load_font(54)
        self.font_formula = self._load_font(64)

    @staticmethod
    def _load_font(size: int):
        for path in (
            "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
            "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
        ):
            try:
                from PIL import ImageFont
                return ImageFont.truetype(path, size)
            except Exception:
                continue
        from PIL import ImageFont
        return ImageFont.load_default()

    @staticmethod
    def _mix(a, b, t: float) -> tuple[int, int, int]:
        t = min(max(t, 0.0), 1.0)
        return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))

    @staticmethod
    def _pack_rgb(rgb: np.ndarray) -> np.ndarray:
        return (
            (rgb[..., 0].astype(np.uint32) << 16)
            | (rgb[..., 1].astype(np.uint32) << 8)
            | rgb[..., 2].astype(np.uint32)
        )

    def animating(self, state: Scene5State, now: float) -> bool:
        # Match Scene 6 v3: no animated fades on HDMI.
        return False

    def draw(self, state: Scene5State, now: float) -> np.ndarray:
        from PIL import Image, ImageDraw

        img = Image.new("RGB", (WIDTH, HEIGHT), self.bg)
        draw = ImageDraw.Draw(img)
        slide = current_intro_slide(state)
        accent = self.accent

        for x in range(80, WIDTH, 160):
            draw.line((x, 0, x - 140, HEIGHT), fill=(10, 14, 21), width=1)

        self._text_center(draw, 78, slide.title, self.font_xlarge, accent)

        y = 188
        max_text_width = WIDTH - 190
        line_gap = 44
        group_gap = 14
        for i, group in enumerate(slide.groups):
            if i >= state.intro_progress:
                break
            for line in self._wrap_text(draw, group, self.font_large, max_text_width):
                self._text_center(draw, y, line, self.font_large, self.white)
                y += line_gap
            y += group_gap

        if slide.formula and state.intro_progress >= intro_item_count(slide):
            box_w = 680 if len(slide.formula) > 18 else 550
            box_x0 = (WIDTH - box_w) // 2
            box = (box_x0, 505, box_x0 + box_w, 610)
            draw.rounded_rectangle(
                box,
                radius=26,
                fill=self.panel,
                outline=self._mix((15, 20, 28), accent, 0.55),
                width=2,
            )
            formula_font = self.font_formula if len(slide.formula) <= 18 else self.font_large
            formula_y = 527 if formula_font is self.font_formula else 532
            self._text_center(draw, formula_y, slide.formula, formula_font, self.white)

        total = len(INTRO_SLIDES)
        dot_y = 646
        start_x = WIDTH // 2 - (total - 1) * 18
        for i in range(total):
            r = 7 if i == state.intro_index else 5
            colour = accent if i == state.intro_index else (70, 78, 88)
            cx = start_x + i * 36
            draw.ellipse((cx - r, dot_y - r, cx + r, dot_y + r), fill=colour)

        hint = "Button 2: continue    Button 3: reveal    Button 1: back"
        self._text_center(draw, 675, hint, self.font_small, self.dim)
        return self._pack_rgb(np.asarray(img, dtype=np.uint8))

    @staticmethod
    def _text(draw, xy, text: str, font, fill) -> None:
        x, y = xy
        draw.text((x + 1, y + 1), text, font=font, fill=(0, 0, 0))
        draw.text((x, y), text, font=font, fill=fill)

    def _text_center(self, draw, y: int, text: str, font, fill) -> None:
        bbox = draw.textbbox((0, 0), text, font=font)
        w = bbox[2] - bbox[0]
        self._text(draw, ((WIDTH - w) // 2, y), text, font, fill)

    @staticmethod
    def _wrap_text(draw, text: str, font, max_width: int) -> list[str]:
        words = text.split()
        lines: list[str] = []
        current = ""
        for word in words:
            candidate = word if not current else f"{current} {word}"
            bbox = draw.textbbox((0, 0), candidate, font=font)
            if bbox[2] - bbox[0] <= max_width or not current:
                current = candidate
            else:
                lines.append(current)
                current = word
        if current:
            lines.append(current)
        return lines


# Keyboard and controller input backends

class RawTerminal:
    def __enter__(self) -> "RawTerminal":
        self.enabled = sys.stdin.isatty()
        self.old_settings = None
        if self.enabled:
            self.old_settings = termios.tcgetattr(sys.stdin)
            tty.setcbreak(sys.stdin.fileno())
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        if self.enabled and self.old_settings is not None:
            termios.tcsetattr(sys.stdin, termios.TCSADRAIN, self.old_settings)


class KeyboardInput:
    def poll(self) -> list[Event]:
        events: list[Event] = []
        while sys.stdin in select.select([sys.stdin], [], [], 0)[0]:
            ch = sys.stdin.read(1)
            if not ch:
                break
            events.extend(self._map_char(ch))
        return events

    def _map_char(self, ch: str) -> list[Event]:
        if ch == "\x1b":
            seq = ch
            deadline = time.time() + 0.01
            while time.time() < deadline and sys.stdin in select.select([sys.stdin], [], [], 0)[0]:
                seq += sys.stdin.read(1)
            arrows = {
                "\x1b[A": Event(EventKind.PAN, (0, 1)),
                "\x1b[B": Event(EventKind.PAN, (0, -1)),
                "\x1b[C": Event(EventKind.PAN, (1, 0)),
                "\x1b[D": Event(EventKind.PAN, (-1, 0)),
            }
            return [arrows[seq]] if seq in arrows else []

        key = ch.lower()
        mapping = {
            "q": Event(EventKind.QUIT),
            "b": Event(EventKind.BACK),
            "n": Event(EventKind.NEXT),
            "\r": Event(EventKind.NEXT),
            "\n": Event(EventKind.NEXT),
            "w": Event(EventKind.PAN, (0, 1)),
            "s": Event(EventKind.PAN, (0, -1)),
            "a": Event(EventKind.PAN, (-1, 0)),
            "d": Event(EventKind.PAN, (1, 0)),
            "[": Event(EventKind.ZOOM, -1),
            "]": Event(EventKind.ZOOM, 1),
            "-": Event(EventKind.ITER, -1),
            "=": Event(EventKind.ITER, 1),
            "_": Event(EventKind.ITER, -1),
            "+": Event(EventKind.ITER, 1),
            "r": Event(EventKind.RESET),
            "p": Event(EventKind.CYCLE_PALETTE),
            " ": Event(EventKind.TOGGLE_HUD),
            "h": Event(EventKind.TOGGLE_HUD),
            "f": Event(EventKind.TOGGLE_FINE),
            "5": Event(EventKind.TOGGLE_FINE),
            "m": Event(EventKind.MENU),
        }
        return [mapping[key]] if key in mapping else []


class SerialControllerInput:
    def __init__(self, port: str, baudrate: int = 115200) -> None:
        self.port = port
        self.baudrate = baudrate
        self.serial = None
        self.prev_buttons = 0

    def open(self) -> bool:
        try:
            import serial  # type: ignore
        except Exception as exc:
            print(f"Serial controller disabled: pyserial import failed: {exc}")
            return False

        try:
            self.serial = serial.Serial(self.port, baudrate=self.baudrate, timeout=0.0)
            self.serial.reset_input_buffer()
            print(f"Serial controller connected on {self.port}")
            return True
        except Exception as exc:
            print(f"Serial controller disabled on {self.port}: {exc}")
            self.serial = None
            return False

    def close(self) -> None:
        if self.serial is not None:
            self.serial.close()
            self.serial = None

    def poll(self) -> list[Event]:
        if self.serial is None:
            return []

        events: list[Event] = []
        for _ in range(8):
            raw = self.serial.readline()
            if not raw:
                break
            line = raw.decode("ascii", errors="ignore").strip()
            events.extend(self._parse_line(line))
        return events

    def _parse_line(self, line: str) -> list[Event]:
        if not line.startswith("TDT,") or "," not in line:
            return []

        last_comma = line.rfind(",")
        payload = line[:last_comma]
        received_crc = line[last_comma + 1 :].upper()
        expected_crc = f"{calc_crc8(payload.encode('ascii')):02X}"
        if expected_crc != received_crc:
            return []

        parts = payload.split(",")
        if len(parts) < 7:
            return []

        try:
            buttons = int(parts[2], 16)
            zoom_delta = int(parts[3])
            iter_delta = int(parts[4])
            joy_x = int(parts[5])
            joy_y = int(parts[6])
        except ValueError:
            return []

        events: list[Event] = []
        rising = buttons & ~self.prev_buttons
        self.prev_buttons = buttons

        button_map = {
            0: Event(EventKind.BACK),
            1: Event(EventKind.NEXT),
            2: Event(EventKind.TOGGLE_HUD),
            3: Event(EventKind.CYCLE_PALETTE),
            4: Event(EventKind.TOGGLE_FINE),
            5: Event(EventKind.MENU),
        }
        for bit, event in button_map.items():
            if rising & (1 << bit):
                events.append(event)

        if zoom_delta:
            events.append(Event(EventKind.ZOOM, zoom_delta))
        if iter_delta:
            events.append(Event(EventKind.ITER, iter_delta))
        if joy_x or joy_y:
            # The controller reports analogue-ish deltas. Keep this small because
            # one serial packet can contain a larger value than one keyboard step.
            dx = max(-1.0, min(1.0, joy_x / 100.0))
            dy = max(-1.0, min(1.0, -joy_y / 100.0))
            events.append(Event(EventKind.PAN, (dx, dy)))

        return events


# hardware backend

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


def decode_writer_status(status: int) -> dict[str, object]:
    return {
        "busy": bool(status & 0x1),
        "done": bool(status & 0x2),
        "error": bool(status & 0x4),
        "idle": bool(status & 0x8),
        "raw": status,
    }


class FractalHardware:
    def __init__(self, args: argparse.Namespace) -> None:
        from pynq import MMIO, Overlay, allocate  # imported here so --self-test works off-board

        self.args = args
        self.bit_path = resolve_bit_path(args.bit)
        self.wait_pixels = FRAME_PIXELS if args.wait_frame_pixels else ACTIVE_PIXELS
        self.scales = parse_scales(args.scales)
        self.interaction_scales = parse_scales(args.interaction_scales)
        self.refine_scales = parse_scales(args.refine_scales)
        self.hud_available = False
        self.palette_scale_mmio = None
        self.palette_select_mmio = None
        self.current_front_idx = 0
        self.previous_front_idx: Optional[int] = None
        self.next_fb_search_start = 0
        self.last_park_time = 0.0
        self.hud_panel_cache: Optional[tuple[np.ndarray, np.ndarray]] = None
        # keep VDMA parked on one fixed display framebuffer, render into the other buffer, then copy/commit the completed frame. 
        self.swap_framebuffers = bool(args.swap_framebuffers)

        print(f"Scene 5 HDMI version: {SCENE5_HDMI_VERSION}")
        print("Configured for:")
        print(f"  bitstream:  {self.bit_path}")
        print(f"  resolution: {WIDTH}x{HEIGHT}")
        print(f"  bpp:        {BPP}")
        print(f"  stride:     {STRIDE}")
        print(f"  pixels:     {FRAME_PIXELS}")
        print(f"  active:     {ACTIVE_PIXELS}")
        print(f"  frame size: {FRAME_PIXELS * BPP} bytes")
        print(f"  buffers:    {max(2, int(args.buffer_count))}")
        print(f"  fixed:      Q4.{FIXED_FRAC_BITS} in {FIXED_W} bits")
        print(f"  display:    {'VDMA framebuffer swaps' if self.swap_framebuffers else 'fixed VDMA buffer with PS commit copy'}")
        print(f"  palette:    {PALETTE_SIZE} entries, scale frac={PALETTE_SCALE_FRAC}")
        print(f"  scales:     {self.scales}")
        print(f"  interaction:{self.interaction_scales}")
        print(f"  refine:     {self.refine_scales} after {args.refine_idle_s:.2f}s idle")

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

        palette_scale_ip = None
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

        self.fb = [
            allocate(shape=(HEIGHT, WIDTH), dtype=np.uint32)
            for _ in range(max(2, int(args.buffer_count)))
        ]
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
        # WR_FRAME_PIXELS is programmed by PS; after overlay load it can read as 0.
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
        """Force VDMA MM2S to read only framebuffer 0 in fixed-display mode."""
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

        # In fixed-display mode the VDMA should only ever read framebuffer 0.
        # PL renders go into a back buffer and are copied into framebuffer 0
        if self.swap_framebuffers:
            front_addr = self.fb[0].physical_address
            regs = (MM2S_START_ADDR1, MM2S_START_ADDR2, MM2S_START_ADDR3)
            for idx, reg in enumerate(regs):
                addr = self.fb[idx].physical_address if idx < len(self.fb) else front_addr
                self.vdma.write(reg, addr)
            self.vdma.write(PARK_PTR_REG, 0)
            self.last_park_time = time.time()
        else:
            self.repin_fixed_display_buffer()

        self.vdma.write(MM2S_DMACR, VDMA_DMACR_RUNSTOP)
        if self.swap_framebuffers:
            self.vdma.write(PARK_PTR_REG, 0)
            self.last_park_time = time.time()
        else:
            self.repin_fixed_display_buffer()
        self.vdma.write(MM2S_FRMDLY_STRIDE, STRIDE)
        self.vdma.write(MM2S_HSIZE, STRIDE)
        self.vdma.write(MM2S_VSIZE, HEIGHT)
        if not self.swap_framebuffers:
            self.repin_fixed_display_buffer()
        time.sleep(0.1)
        print("\nAfter MM2S start:")
        self.show_mm2s()

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

    def program_scheduler_view(self, state: Scene5State) -> None:
        y_width = state.x_width * HEIGHT / WIDTH
        x_min = state.center_r - state.x_width / 2.0
        y_min = state.center_i - y_width / 2.0
        x_jump = state.x_width / WIDTH
        y_jump = y_width / HEIGHT

        self.sched.write(SCH_X_JUMP, to_fixed_q4_22(x_jump))
        self.sched.write(SCH_Y_JUMP, to_fixed_q4_22(y_jump))
        self.sched.write(SCH_X_MIN, to_fixed_q4_22(x_min))
        self.sched.write(SCH_Y_MIN, to_fixed_q4_22(y_min))
        self.sched.write(SCH_JUL_C_R, to_fixed_q4_22(-0.8))
        self.sched.write(SCH_JUL_C_I, to_fixed_q4_22(0.156))
        self.sched.write(SCH_MODE_ITER, pack_mode_iter(MODE_MANDEL, state.max_iter))
        self.program_palette_scale(state.max_iter, verbose=False)
        self.program_palette_select(state.palette_index)

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
            if now - t0 > timeout_s:
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


    def choose_back_framebuffer(self) -> int:
        blocked = {self.current_front_idx}
        if len(self.fb) >= 3 and self.previous_front_idx is not None:
            blocked.add(self.previous_front_idx)

        for offset in range(len(self.fb)):
            idx = (self.next_fb_search_start + offset) % len(self.fb)
            if idx not in blocked:
                self.next_fb_search_start = (idx + 1) % len(self.fb)
                return idx

        return 1 - self.current_front_idx

    def park_framebuffer(self, frame_idx: int) -> None:
        old_front = self.current_front_idx
        self.vdma.write(PARK_PTR_REG, int(frame_idx))
        self.last_park_time = time.time()
        if self.args.swap_guard_s > 0.0:
            time.sleep(self.args.swap_guard_s)
        self.previous_front_idx = old_front
        self.current_front_idx = int(frame_idx)

    def commit_rendered_framebuffer(self, source_idx: int) -> None:
        if self.swap_framebuffers:
            self.park_framebuffer(source_idx)
            return

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

    def render_mandelbrot(
        self,
        state: Scene5State,
        scales: Optional[Iterable[int]] = None,
        draw_overlay: Optional[bool] = None,
        label: str = "render",
    ) -> dict[str, int | float]:
        active_scales = tuple(scales) if scales is not None else self.scales
        if not active_scales:
            raise ValueError("render_mandelbrot needs at least one scale")
        if draw_overlay is None:
            draw_overlay = state.hud_visible

        state.render_count += 1
        start = time.time()
        final_result: dict[str, int | float] = {
            "elapsed": 0.0,
            "accepted": 0,
            "written": 0,
            "errors": 0,
            "status": 0,
        }

        print(
            f"\n{label.capitalize()} {state.render_count}: center=({state.center_r:.9f}, {state.center_i:.9f}) "
            f"width={state.x_width:.9g} max_iter={state.max_iter} scales={active_scales}"
        )

        for scale in active_scales:
            target_writes = expected_active_writes_for_scale(scale)
            back_idx = self.choose_back_framebuffer() if self.swap_framebuffers else 1 - self.current_front_idx
            back_fb = self.fb[back_idx]

            self.hold_scheduler_reset()
            self.reset_writer()
            self.writer.write(WR_FRAME_PIXELS, target_writes)
            self.writer.write(WR_FRAMEBUFFER_BASE, back_fb.physical_address)
            self.start_writer(scale=scale)
            self.program_scheduler_view(state)
            self.start_scheduler(scale=scale)

            result = self.poll_writer(target_writes=target_writes, timeout_s=self.args.timeout_s)
            self.hold_scheduler_reset()
            final_result = result

            state.last_render_s = time.time() - start
            state.last_written = int(result.get("written", 0))
            state.last_errors = int(result.get("errors", 0))

            # The PL writes one sparse sample per scale block. Refresh the CPU
            # view, then expand those samples into readable preview blocks.
            try:
                back_fb.invalidate()
            except Exception:
                pass
            expand_sparse_progressive_pass(back_fb, scale)

            if draw_overlay:
                draw_hud(back_fb, state, result, scale, self.palette_select_mmio is not None)
                self.hud_panel_cache = snapshot_hud_panels(back_fb)
            elif state.hud_visible:
                if self.swap_framebuffers:
                    apply_hud_panel_cache(back_fb, self.hud_panel_cache)
                else:
                    copy_hud_panels(self.fb[self.current_front_idx], back_fb)
            else:
                clear_hud_panels(back_fb)
                self.hud_panel_cache = None

            back_fb.flush()
            self.commit_rendered_framebuffer(back_idx)

            if result["errors"] or int(result["written"]) < target_writes:
                break

        elapsed = time.time() - start
        state.last_render_s = elapsed
        state.last_written = int(final_result.get("written", 0))
        state.last_errors = int(final_result.get("errors", 0))
        state.dirty = False
        print(
            f"Done: {elapsed:.3f}s, written={state.last_written}, errors={state.last_errors}, "
            f"front=fb{self.current_front_idx}"
        )
        return final_result


# HUD overlay

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
    scale = int(scale)
    if scale <= 1:
        return

    raw = np.asarray(fb)
    samples = raw[0:HEIGHT:scale, 0:WIDTH:scale].copy()
    expanded = np.repeat(np.repeat(samples, scale, axis=0), scale, axis=1)
    raw[:, :] = expanded[0:HEIGHT, 0:WIDTH]


def snapshot_hud_panels(fb) -> tuple[np.ndarray, np.ndarray]:
    raw = np.asarray(fb)
    left = raw[0:PANEL_HEIGHT, 0:PANEL_WIDTH].copy()
    right = raw[0:PANEL_HEIGHT, WIDTH - PANEL_WIDTH:WIDTH].copy()
    return left, right


def apply_hud_panel_cache(fb, cache: Optional[tuple[np.ndarray, np.ndarray]]) -> None:
    if cache is None:
        clear_hud_panels(fb)
        return
    raw = np.asarray(fb)
    left, right = cache
    raw[0:PANEL_HEIGHT, 0:PANEL_WIDTH] = left
    raw[0:PANEL_HEIGHT, WIDTH - PANEL_WIDTH:WIDTH] = right


def _write_rgb_panel(raw, x0: int, y0: int, rgb: np.ndarray) -> None:
    h, w, _ = rgb.shape
    raw[y0:y0 + h, x0:x0 + w] = (
        (rgb[..., 0].astype(np.uint32) << 16)
        | (rgb[..., 1].astype(np.uint32) << 8)
        | rgb[..., 2].astype(np.uint32)
    )


def draw_hud(fb, state: Scene5State, result: dict[str, int | float], scale: int, palette_hw: bool) -> None:
    try:
        from PIL import Image, ImageDraw, ImageFont
    except Exception:
        clear_hud_panels(fb)
        return

    raw = np.asarray(fb)
    clear_hud_panels(fb)

    try:
        font_title = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", 19)
        font = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", 14)
        font_small = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", 11)
        font_mono = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf", 13)
    except Exception:
        font_title = ImageFont.load_default()
        font = ImageFont.load_default()
        font_small = ImageFont.load_default()
        font_mono = ImageFont.load_default()

    def make_panel() -> tuple[Image.Image, ImageDraw.ImageDraw]:
        img = Image.new("RGB", (PANEL_WIDTH, PANEL_HEIGHT), (5, 9, 18))
        d = ImageDraw.Draw(img)
        d.rounded_rectangle(
            (8, 8, PANEL_WIDTH - 8, PANEL_HEIGHT - 8),
            radius=14,
            fill=(8, 14, 24),
            outline=(70, 190, 215),
            width=1,
        )
        return img, d

    left, dl = make_panel()
    dl.text((24, 16), "Mandelbrot set", font=font_title, fill=(245, 250, 255))
    dl.text((24, 44), "Each pixel is one c value.", font=font, fill=(205, 225, 235))
    dl.text((24, 66), "Start z = 0, then repeat:", font=font, fill=(205, 225, 235))
    dl.text((24, 91), "z → z² + c", font=font_mono, fill=(255, 225, 150))
    dl.text((24, 119), f"center {state.center_r:+.4f} {state.center_i:+.4f}i", font=font_small, fill=(170, 195, 205))
    dl.text((24, 136), f"width {state.x_width:.4g}   iter {state.max_iter}", font=font_small, fill=(170, 195, 205))
    if state.fine_control:
        dl.text((PANEL_WIDTH - 72, 122), "fine", font=font_small, fill=(255, 150, 190))

    right, dr = make_panel()
    dr.text((24, 16), "Explore", font=font_title, fill=(245, 250, 255))
    dr.text((24, 47), "Joystick           pan", font=font_small, fill=(170, 195, 205))
    dr.text((24, 65), "Encoder 1          zoom", font=font_small, fill=(170, 195, 205))
    dr.text((24, 83), "Encoder 2          iterations", font=font_small, fill=(170, 195, 205))
    dr.text((24, 103), "Stick reset   B4 fine", font=font_small, fill=(170, 195, 205))
    dr.text((24, 116), "B2 next      B5 palette", font=font_small, fill=(245, 235, 170))

    palette_text = state.palette_names[state.palette_index]
    if not palette_hw:
        palette_text += "*"
    dr.text((24, 134), ("Palette: " + palette_text)[:26], font=font_small, fill=(155, 210, 225))

    _write_rgb_panel(raw, 0, 0, np.asarray(left, dtype=np.uint8))
    _write_rgb_panel(raw, WIDTH - PANEL_WIDTH, 0, np.asarray(right, dtype=np.uint8))


def print_controls() -> None:
    print("\nScene 5 controls")
    print("  W/A/S/D or arrows  : pan Mandelbrot view; W/up moves up, S/down moves down")
    print("  [ / ]              : encoder 1 zoom out / in")
    print("  - / =              : encoder 2 decrease / increase max_iter")
    print("  R                  : joystick click reset view")
    print("  P                  : button 5 cycle palette control")
    print("  F                  : button 4 toggle fine controls")
    print("  Space or H         : button 3 toggle HUD overlay")
    print("  B / N              : button 1 back / button 2 next scene")
    print("  M                  : button 6 menu request")
    print("  Q                  : terminal-only quit")


# Misc helpers and entry point
def parse_scales(text: str) -> tuple[int, ...]:
    vals = []
    for part in text.split(","):
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
    scale = int(scale)
    if scale <= 0 or 32 % scale != 0 or 16 % scale != 0:
        raise ValueError("Render scale must divide both 32 and 16")
    return ACTIVE_PIXELS // (scale * scale)


def calc_crc8(payload_bytes: bytes) -> int:
    crc = 0x00
    for b in payload_bytes:
        crc ^= b
        for _ in range(8):
            if crc & 0x80:
                crc = ((crc << 1) ^ 0x07) & 0xFF
            else:
                crc = (crc << 1) & 0xFF
    return crc


def pick_serial_port(mode: str) -> Optional[str]:
    if mode in ("", "none", "off", "false"):
        return None
    if mode != "auto":
        return mode
    for candidate in ("/dev/ttyACM0", "/dev/ttyACM1", "/dev/ttyUSB0", "/dev/ttyUSB1"):
        if os.path.exists(candidate):
            return candidate
    return None


def self_test() -> None:
    assert FIXED_FRAC_BITS == 22
    assert abs(from_fixed_q4_22(to_fixed_q4_22(-0.8)) + 0.8) < 1e-5
    assert abs(from_fixed_q4_22(to_fixed_q4_22(0.156)) - 0.156) < 1e-5
    assert compute_palette_scale(128) == ((PALETTE_SIZE - 1) << PALETTE_SCALE_FRAC) // 127 + (1 if ((PALETTE_SIZE - 1) << PALETTE_SCALE_FRAC) % 127 else 0)
    assert expected_active_writes_for_scale(8) == 12640
    assert expected_active_writes_for_scale(4) == 50560
    assert expected_active_writes_for_scale(2) == 202240
    assert expected_active_writes_for_scale(1) == ACTIVE_PIXELS

    scene = Scene5Mandelbrot()
    scene.state.enter_interactive()
    scene.handle_event(Event(EventKind.ZOOM, 1))
    assert scene.state.x_width < 3.5
    old_i = scene.state.center_i
    scene.handle_event(Event(EventKind.PAN, (1, 1)))
    assert scene.state.center_i < old_i
    assert scene.state.dirty
    scene.handle_event(Event(EventKind.RESET))
    assert scene.state.center_r == -0.75
    assert scene.state.center_i == 0.0
    assert scene.state.max_iter == 128
    print("Self-test PASS")


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="FractalScope Scene 5 Mandelbrot explorer")
    parser.add_argument("--bit", default=DEFAULT_BIT_PATH, help=".bit file or directory containing the latest .bit")
    parser.add_argument("--no-download", action="store_true", help="load overlay metadata but do not download the bitstream")
    parser.add_argument("--serial", default="auto", help="physical controller serial port, 'auto', or 'none'")
    parser.add_argument("--baudrate", type=int, default=115200)
    parser.add_argument("--scales", default="8,4,2,1", help="initial/full progressive render scales, e.g. 8,4,2,1 or 4,2,1")
    parser.add_argument("--interaction-scales", default="8", help="scales rendered immediately after input; keep coarse for smooth control")
    parser.add_argument("--refine-scales", default="4,2,1", help="scales rendered after input has been idle")
    parser.add_argument("--refine-idle-s", type=float, default=0.35, help="seconds of no input before starting refinement")
    parser.add_argument("--hud-during-interaction", dest="hud_during_interaction", action="store_true", default=True, help="draw the small panel HUD on coarse interaction previews; enabled by default")
    parser.add_argument("--no-hud-during-interaction", dest="hud_during_interaction", action="store_false", help="do not redraw the panel HUD during coarse interaction previews")
    parser.add_argument("--swap-framebuffers", action="store_true", help="use the old VDMA park-pointer swap path instead of the fixed-display commit path")
    parser.add_argument("--swap-guard-s", type=float, default=0.070, help="delay after parking VDMA on a new buffer; only used with --swap-framebuffers")
    parser.add_argument("--buffer-count", type=int, default=2, choices=(2, 3), help="framebuffer count; fixed-display mode only needs 2, old swap mode can use 3")
    parser.add_argument("--timeout-s", type=float, default=30.0)
    parser.add_argument("--wait-frame-pixels", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--palette-scale-ip", default="", help="override palette-scale AXI GPIO/IP name")
    parser.add_argument("--palette-select-ip", default="", help="optional palette-select AXI GPIO/IP name")
    parser.add_argument("--no-initial-render", action="store_true")
    parser.add_argument("--verbose-render", action="store_true")
    parser.add_argument("--self-test", action="store_true")
    return parser


def main(argv: Optional[Iterable[str]] = None) -> int:
    args = build_arg_parser().parse_args(argv)
    if args.self_test:
        self_test()
        return 0

    scene = Scene5Mandelbrot()
    # The standalone file remains a direct Mandelbrot explorer. The integrated
    # walkthrough runner keeps Scene 5 in INTRO until the slides are complete.
    scene.state.enter_interactive()
    keyboard = KeyboardInput()
    serial_input: Optional[SerialControllerInput] = None
    serial_port = pick_serial_port(args.serial)
    if serial_port:
        serial_input = SerialControllerInput(serial_port, args.baudrate)
        if not serial_input.open():
            serial_input = None

    hw = None
    try:
        hw = FractalHardware(args)
        print_controls()

        if not args.no_initial_render:
            hw.render_mandelbrot(scene.state, scales=hw.scales, draw_overlay=scene.state.hud_visible, label="initial render")

        refine_queue: list[int] = []
        last_input_time = time.time()

        print("\nReady. Change the view with the controls above.")
        print("Interaction mode: coarse preview immediately; finer passes only after input is idle.")
        with RawTerminal():
            while not scene.state.quit_requested:
                events = keyboard.poll()
                if serial_input is not None:
                    events.extend(serial_input.poll())

                if events:
                    for event in events:
                        scene.handle_event(event)
                    last_input_time = time.time()
                    refine_queue.clear()
                    print("  " + scene.state.last_message)

                if scene.state.transition_request is not None:
                    print(f"Standalone Scene 5 noted transition request: {scene.state.transition_request}")
                    scene.state.transition_request = None

                if scene.state.dirty:
                    # While the user is actively moving, render only the cheap preview pass.
                    # This keeps the input loop responsive and prevents a full 8->4->2->1
                    # sequence from blocking joystick/keyboard polling after every event.
                    hw.render_mandelbrot(
                        scene.state,
                        scales=hw.interaction_scales,
                        draw_overlay=scene.state.hud_visible and args.hud_during_interaction,
                        label="preview",
                    )
                    scene.state.dirty = False
                    refine_queue = list(hw.refine_scales)

                elif refine_queue and (time.time() - last_input_time) >= args.refine_idle_s:
                    # Refine one scale at a time, returning to the input loop between
                    # passes. If the user moves again, queued refinement is cancelled.
                    scale = refine_queue.pop(0)
                    final_refine_pass = not refine_queue
                    hw.render_mandelbrot(
                        scene.state,
                        scales=(scale,),
                        draw_overlay=scene.state.hud_visible and final_refine_pass,
                        label=f"refine x{scale}",
                    )

                time.sleep(0.02)

    except KeyboardInterrupt:
        print("\nInterrupted.")
    finally:
        if hw is not None:
            hw.close()
        if serial_input is not None:
            serial_input.close()

    print("Scene 5 closed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
