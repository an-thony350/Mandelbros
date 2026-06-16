#!/usr/bin/env python3
r"""
This PS-drawn educational scene introduces colouring

Controls:
    N / Enter       Button 2: reveal next intro item / next view
    B               Button 1: previous intro item / previous view
    Space           Button 3: reveal intro slide / play-pause grid fill
    W/A/S/D/arrows  Joystick: pan around the complex plane
    [ / ]           Encoder 1: zoom the view
    - / =           Encoder 2: change max checks / colour detail
    R               Joystick click: reset the grid reveal
    P               Button 5: cycle visual palette
    Q               Quit
"""

from __future__ import annotations

from contextlib import contextmanager
from dataclasses import dataclass
from enum import Enum, auto
import argparse
import glob
import math
import os
import select
import sys
import termios
import time
import tty
from typing import Sequence

import numpy as np
from PIL import Image, ImageDraw, ImageFont

SCRIPT_VERSION = "scene4_escape_time_colour_2026_06_10_streamlined"


# Display constants

WIDTH = 1280
HEIGHT = 720
BPP = 4

DEFAULT_BIT_PATH = "/home/xilinx/jupyter_notebooks/fractalscope"


# AXI VDMA MM2S register offsets
MM2S_DMACR         = 0x00
MM2S_DMASR         = 0x04
PARK_PTR_REG       = 0x28
MM2S_VSIZE         = 0x50
MM2S_HSIZE         = 0x54
MM2S_FRMDLY_STRIDE = 0x58
MM2S_START_ADDR1   = 0x5C
MM2S_START_ADDR2   = 0x60
MM2S_START_ADDR3   = 0x64

VDMA_DMACR_RUNSTOP = 1 << 0
VDMA_DMACR_RESET   = 1 << 2


# Controller-style events

class EventKind(Enum):
    BACK = auto()
    NEXT = auto()
    MENU_TOGGLE = auto()
    SCENE_ACTION = auto()
    PALETTE_CYCLE = auto()
    FUNCTION = auto()
    RESET = auto()
    JOY_LEFT = auto()
    JOY_RIGHT = auto()
    JOY_UP = auto()
    JOY_DOWN = auto()
    ENC1_DELTA = auto()
    ENC2_DELTA = auto()
    QUIT = auto()


@dataclass(frozen=True)
class Event:
    kind: EventKind
    delta: int = 0


KEY_EVENTS = {
    "b": Event(EventKind.BACK),
    "B": Event(EventKind.BACK),
    "n": Event(EventKind.NEXT),
    "N": Event(EventKind.NEXT),
    "\n": Event(EventKind.NEXT),
    "\r": Event(EventKind.NEXT),

    "m": Event(EventKind.MENU_TOGGLE),
    "M": Event(EventKind.MENU_TOGGLE),
    " ": Event(EventKind.SCENE_ACTION),
    "p": Event(EventKind.PALETTE_CYCLE),
    "P": Event(EventKind.PALETTE_CYCLE),
    "f": Event(EventKind.FUNCTION),
    "F": Event(EventKind.FUNCTION),
    "r": Event(EventKind.RESET),
    "R": Event(EventKind.RESET),

    "w": Event(EventKind.JOY_UP),
    "W": Event(EventKind.JOY_UP),
    "s": Event(EventKind.JOY_DOWN),
    "S": Event(EventKind.JOY_DOWN),
    "a": Event(EventKind.JOY_LEFT),
    "A": Event(EventKind.JOY_LEFT),
    "d": Event(EventKind.JOY_RIGHT),
    "D": Event(EventKind.JOY_RIGHT),

    "[": Event(EventKind.ENC1_DELTA, -1),
    "]": Event(EventKind.ENC1_DELTA, +1),
    "-": Event(EventKind.ENC2_DELTA, -1),
    "=": Event(EventKind.ENC2_DELTA, +1),

    "q": Event(EventKind.QUIT),
    "Q": Event(EventKind.QUIT),
}

ARROW_EVENTS = {
    "\x1b[A": Event(EventKind.JOY_UP),
    "\x1b[B": Event(EventKind.JOY_DOWN),
    "\x1b[C": Event(EventKind.JOY_RIGHT),
    "\x1b[D": Event(EventKind.JOY_LEFT),
}


@contextmanager
def raw_terminal():
    """Put SSH terminal into cbreak mode while the scene is running."""
    if not sys.stdin.isatty():
        yield
        return

    old_settings = termios.tcgetattr(sys.stdin)
    try:
        tty.setcbreak(sys.stdin.fileno())
        print("\033[?25l", end="", flush=True)
        yield
    finally:
        print("\033[?25h", end="", flush=True)
        termios.tcsetattr(sys.stdin, termios.TCSADRAIN, old_settings)


def read_event(timeout_s: float = 0.0) -> Event | None:
    if not sys.stdin.isatty():
        return None

    ready, _, _ = select.select([sys.stdin], [], [], timeout_s)
    if not ready:
        return None

    ch = sys.stdin.read(1)
    if ch == "\x1b":
        seq = ch
        end_time = time.monotonic() + 0.02
        while time.monotonic() < end_time:
            ready, _, _ = select.select([sys.stdin], [], [], 0.005)
            if not ready:
                break
            seq += sys.stdin.read(1)
            if seq in ARROW_EVENTS:
                return ARROW_EVENTS[seq]
        return None

    return KEY_EVENTS.get(ch)


# State and escape-time model

class AppPhase(Enum):
    INTRO = auto()
    INTERACTIVE = auto()


@dataclass(frozen=True)
class IntroSlide:
    title: str
    groups: tuple[str, ...]
    formula: str | None = None


INTRO_SLIDES = [
    IntroSlide(
        title="One point gives one number",
        groups=(
            "Choose a point c in the complex plane.",
            "Start at z = 0 and repeat the same rule.",
            "Count how many checks it takes to escape.",
        ),
        formula="z → z² + c",
    ),
    IntroSlide(
        title="The count is useful",
        groups=(
            "A fast escape gets a small number.",
            "A slow escape gets a larger number.",
            "If it does not escape, keep it dark.",
        ),
        formula="escape time → colour",
    ),
    IntroSlide(
        title="A picture is many tests",
        groups=(
            "Now test lots of nearby c values.",
            "Each square stores one escape-time number.",
            "Colour all the squares and a shape appears.",
        ),
        formula=None,
    ),
]


@dataclass
class Scene4State:
    phase: AppPhase = AppPhase.INTRO

    intro_index: int = 0
    intro_progress: int = 1
    intro_fade_start: float = 0.0

    view_index: int = 0       # 0: numbers, 1: colours, 2: denser preview
    centre_r: float = -0.50
    centre_i: float = 0.00
    view_width: float = 3.20

    max_iter: int = 32
    reveal_count: int = 0
    playing: bool = False

    palette_index: int = 0
    status: str = "Press play to fill the grid."

    last_tick: float = 0.0
    dirty: bool = True

    cached_key: tuple | None = None
    cached_grid: tuple[np.ndarray, np.ndarray] | None = None
    cached_preview_key: tuple | None = None
    cached_preview: Image.Image | None = None


PALETTES = [
    {
        "name": "Cyan",
        "accent": (80, 230, 230),
        "low": (24, 55, 82),
        "high": (116, 238, 238),
        "current": (255, 120, 235),
    },
    {
        "name": "Fire",
        "accent": (255, 170, 70),
        "low": (70, 25, 20),
        "high": (255, 206, 96),
        "current": (120, 225, 255),
    },
    {
        "name": "Ice",
        "accent": (130, 190, 255),
        "low": (26, 42, 82),
        "high": (220, 244, 255),
        "current": (255, 215, 115),
    },
    {
        "name": "Mono",
        "accent": (225, 225, 225),
        "low": (56, 56, 56),
        "high": (235, 235, 235),
        "current": (255, 255, 255),
    },
]


COARSE_COLS = 32
COARSE_ROWS = 18
PREVIEW_COLS = 128
PREVIEW_ROWS = 72


def clamp_float(value: float, lo: float, hi: float) -> float:
    return max(lo, min(hi, value))


def clamp_int(value: int, lo: int, hi: int) -> int:
    return max(lo, min(hi, value))


def fade_complete(state: Scene4State, now: float, fade_s: float) -> bool:
    return now - state.intro_fade_start >= fade_s


def current_intro_slide(state: Scene4State) -> IntroSlide:
    return INTRO_SLIDES[state.intro_index]


def intro_item_count(slide: IntroSlide) -> int:
    return len(slide.groups) + (1 if slide.formula else 0)


def enter_interactive(state: Scene4State) -> None:
    state.phase = AppPhase.INTERACTIVE
    state.playing = False
    state.reveal_count = 0
    state.status = "Press play to fill the grid."
    state.dirty = True


def view_height(state: Scene4State) -> float:
    return state.view_width * 9.0 / 16.0


def mandelbrot_escape(c: complex, max_iter: int) -> tuple[int, bool]:
    z = 0.0 + 0.0j
    for n in range(1, max_iter + 1):
        z = z * z + c
        if z.real * z.real + z.imag * z.imag > 4.0:
            return n, True
    return max_iter, False


def grid_point(state: Scene4State, col: int, row: int, cols: int, rows: int) -> complex:
    h = view_height(state)
    real = state.centre_r - state.view_width / 2.0 + (col + 0.5) * state.view_width / cols
    imag = state.centre_i + h / 2.0 - (row + 0.5) * h / rows
    return complex(real, imag)


def escape_grid(state: Scene4State, cols: int = COARSE_COLS, rows: int = COARSE_ROWS) -> tuple[np.ndarray, np.ndarray]:
    key = (cols, rows, round(state.centre_r, 6), round(state.centre_i, 6), round(state.view_width, 6), state.max_iter)
    if cols == COARSE_COLS and rows == COARSE_ROWS and state.cached_key == key and state.cached_grid is not None:
        return state.cached_grid

    counts = np.zeros((rows, cols), dtype=np.uint16)
    escaped = np.zeros((rows, cols), dtype=np.bool_)
    for row in range(rows):
        for col in range(cols):
            n, esc = mandelbrot_escape(grid_point(state, col, row, cols, rows), state.max_iter)
            counts[row, col] = n
            escaped[row, col] = esc

    result = (counts, escaped)
    if cols == COARSE_COLS and rows == COARSE_ROWS:
        state.cached_key = key
        state.cached_grid = result
    return result


def reset_grid(state: Scene4State, message: str) -> None:
    state.reveal_count = 0
    state.playing = False
    state.status = message
    state.cached_key = None
    state.cached_grid = None
    state.cached_preview_key = None
    state.cached_preview = None
    state.dirty = True


def visible_cell_count(state: Scene4State) -> int:
    total = COARSE_COLS * COARSE_ROWS
    if state.view_index == 2:
        return total
    return clamp_int(state.reveal_count, 0, total)


def view_name(state: Scene4State) -> str:
    if state.view_index == 0:
        return "escape-time numbers"
    if state.view_index == 1:
        return "coloured grid"
    return "denser preview"


def handle_intro_event(state: Scene4State, event: Event, now: float, fade_s: float) -> bool:
    slide = current_intro_slide(state)

    if event.kind == EventKind.NEXT:
        if not fade_complete(state, now, fade_s):
            state.intro_fade_start = now - fade_s
        elif state.intro_progress < intro_item_count(slide):
            state.intro_progress += 1
            state.intro_fade_start = now
        elif state.intro_index < len(INTRO_SLIDES) - 1:
            state.intro_index += 1
            state.intro_progress = 1
            state.intro_fade_start = now
        else:
            enter_interactive(state)
        state.dirty = True
        return True

    if event.kind == EventKind.BACK:
        if state.intro_progress > 1:
            state.intro_progress -= 1
            state.intro_fade_start = now - fade_s
        elif state.intro_index > 0:
            state.intro_index -= 1
            state.intro_progress = intro_item_count(current_intro_slide(state))
            state.intro_fade_start = now - fade_s
        state.dirty = True
        return True

    if event.kind == EventKind.SCENE_ACTION:
        state.intro_progress = intro_item_count(slide)
        state.intro_fade_start = now - fade_s
        state.dirty = True
        return True

    if event.kind == EventKind.PALETTE_CYCLE:
        state.palette_index = (state.palette_index + 1) % len(PALETTES)
        state.dirty = True
        return True

    return True


def handle_interactive_event(state: Scene4State, event: Event) -> bool:
    total = COARSE_COLS * COARSE_ROWS

    if event.kind == EventKind.SCENE_ACTION:
        if state.reveal_count >= total:
            state.reveal_count = 0
        state.playing = not state.playing
        state.status = "Filling the grid." if state.playing else "Paused."
        state.dirty = True
        return True

    if event.kind == EventKind.RESET:
        reset_grid(state, "Grid reveal reset.")
        return True

    if event.kind == EventKind.NEXT:
        if state.view_index < 2:
            state.view_index += 1
            state.reveal_count = total
            state.playing = False
            state.status = f"Showing {view_name(state)}."
        else:
            state.status = "Next topic will use the full hardware-rendered image."
        state.dirty = True
        return True

    if event.kind == EventKind.BACK:
        if state.view_index > 0:
            state.view_index -= 1
            state.status = f"Back to {view_name(state)}."
        else:
            state.phase = AppPhase.INTRO
            state.intro_index = len(INTRO_SLIDES) - 1
            state.intro_progress = intro_item_count(current_intro_slide(state))
            state.intro_fade_start = time.monotonic() - 1.0
            state.playing = False
        state.dirty = True
        return True

    pan_step = 0.08 * state.view_width
    if event.kind == EventKind.JOY_LEFT:
        state.centre_r -= pan_step
        reset_grid(state, f"centre = {state.centre_r:+.3f} {state.centre_i:+.3f}i")
        return True

    if event.kind == EventKind.JOY_RIGHT:
        state.centre_r += pan_step
        reset_grid(state, f"centre = {state.centre_r:+.3f} {state.centre_i:+.3f}i")
        return True

    if event.kind == EventKind.JOY_UP:
        state.centre_i += pan_step
        reset_grid(state, f"centre = {state.centre_r:+.3f} {state.centre_i:+.3f}i")
        return True

    if event.kind == EventKind.JOY_DOWN:
        state.centre_i -= pan_step
        reset_grid(state, f"centre = {state.centre_r:+.3f} {state.centre_i:+.3f}i")
        return True

    if event.kind == EventKind.ENC1_DELTA:
        for _ in range(abs(event.delta)):
            if event.delta > 0:
                state.view_width *= 0.82
            else:
                state.view_width /= 0.82
        state.view_width = clamp_float(state.view_width, 0.35, 4.0)
        reset_grid(state, "View adjusted.")
        return True

    if event.kind == EventKind.ENC2_DELTA:
        state.max_iter = clamp_int(state.max_iter + event.delta, 8, 160)
        reset_grid(state, "Iteration limit adjusted.")
        return True

    if event.kind == EventKind.PALETTE_CYCLE:
        state.palette_index = (state.palette_index + 1) % len(PALETTES)
        state.cached_preview_key = None
        state.cached_preview = None
        state.status = f"Colours: {PALETTES[state.palette_index]['name']}"
        state.dirty = True
        return True

    if event.kind == EventKind.MENU_TOGGLE:
        state.status = "Menu comes later; this view is focused on colouring escape times."
        state.dirty = True
        return True

    if event.kind == EventKind.FUNCTION:
        state.status = "This button is unused for this colour-mapping step."
        state.dirty = True
        return True

    return True


def handle_event(state: Scene4State, event: Event, now: float, fade_s: float) -> bool:
    if event.kind == EventKind.QUIT:
        return False

    if state.phase == AppPhase.INTRO:
        return handle_intro_event(state, event, now, fade_s)
    return handle_interactive_event(state, event)


def update_scene(state: Scene4State, now: float) -> None:
    if state.last_tick == 0.0:
        state.last_tick = now

    if state.phase != AppPhase.INTERACTIVE or not state.playing:
        return

    if now - state.last_tick < 0.08:
        return

    state.last_tick = now
    total = COARSE_COLS * COARSE_ROWS
    if state.reveal_count < total:
        state.reveal_count = min(total, state.reveal_count + 24)
        state.dirty = True
    else:
        state.playing = False
        state.status = "Grid filled. Press N to colour the numbers."
        state.dirty = True


# HDMI drawing

class Scene4Renderer:
    def __init__(self, width: int = WIDTH, height: int = HEIGHT, swap_rb: bool = False, fade_s: float = 0.55):
        self.width = width
        self.height = height
        self.swap_rb = swap_rb
        self.fade_s = fade_s

        self.bg = (7, 9, 13)
        self.panel = (14, 18, 26)
        self.panel_outline = (55, 80, 76)
        self.white = (242, 244, 247)
        self.dim = (166, 174, 184)
        self.inside = (4, 5, 10)

        self.font_tiny = self._load_font(12, mono=True)
        self.font_small = self._load_font(15)
        self.font_normal = self._load_font(20)
        self.font_medium = self._load_font(26)
        self.font_large = self._load_font(42)
        self.font_xlarge = self._load_font(54)
        self.font_formula = self._load_font(64)
        self.font_mono = self._load_font(22, mono=True)
        self.font_mono_small = self._load_font(16, mono=True)

    @staticmethod
    def _load_font(size: int, mono: bool = False):
        candidates = []
        if mono:
            candidates.extend([
                "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
                "/usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf",
            ])
        candidates.extend([
            "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
            "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
        ])

        for path in candidates:
            try:
                return ImageFont.truetype(path, size)
            except (OSError, IOError):
                continue
        return ImageFont.load_default()

    def intro_animating(self, state: Scene4State, now: float) -> bool:
        # Match Scene 6 v3: static slide changes only. The old fade path
        # caused unnecessary HDMI framebuffer updates and could look unstable.
        return False

    def draw(self, state: Scene4State, now: float) -> np.ndarray:
        if state.phase == AppPhase.INTRO:
            img = self._draw_intro(state, now)
        else:
            img = self._draw_interactive(state)
        rgb = np.asarray(img, dtype=np.uint8)
        return self._pack_rgb(rgb)

    def _pack_rgb(self, rgb: np.ndarray) -> np.ndarray:
        r = rgb[..., 0].astype(np.uint32)
        g = rgb[..., 1].astype(np.uint32)
        b = rgb[..., 2].astype(np.uint32)

        if self.swap_rb:
            return (b << 16) | (g << 8) | r
        return (r << 16) | (g << 8) | b

    @staticmethod
    def _mix(a, b, t: float) -> tuple[int, int, int]:
        t = clamp_float(t, 0.0, 1.0)
        return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))

    @staticmethod
    def _text(draw: ImageDraw.ImageDraw, xy, text: str, font, fill) -> None:
        x, y = xy
        draw.text((x + 1, y + 1), text, font=font, fill=(0, 0, 0))
        draw.text((x, y), text, font=font, fill=fill)

    def _text_center(self, draw, y: int, text: str, font, fill) -> None:
        bbox = draw.textbbox((0, 0), text, font=font)
        w = bbox[2] - bbox[0]
        self._text(draw, ((self.width - w) // 2, y), text, font, fill)

    @staticmethod
    def _panel(draw: ImageDraw.ImageDraw, box, fill, outline, width: int = 2, radius: int = 20) -> None:
        draw.rounded_rectangle(box, radius=radius, fill=fill, outline=outline, width=width)

    def _wrap_text(self, draw, text: str, font, max_width: int) -> list[str]:
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

    def _draw_intro(self, state: Scene4State, now: float) -> Image.Image:
        img = Image.new("RGB", (self.width, self.height), self.bg)
        draw = ImageDraw.Draw(img)
        palette = PALETTES[state.palette_index]
        accent = palette["accent"]
        slide = current_intro_slide(state)

        for x in range(80, self.width, 160):
            draw.line((x, 0, x - 140, self.height), fill=(10, 14, 21), width=1)

        self._text_center(draw, 78, slide.title, self.font_xlarge, accent)

        y = 188
        max_text_width = self.width - 190
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
            box_x0 = (self.width - box_w) // 2
            box = (box_x0, 505, box_x0 + box_w, 610)
            self._panel(
                draw,
                box,
                self.panel,
                self._mix((15, 20, 28), accent, 0.55),
                width=2,
                radius=26,
            )
            formula_font = self.font_formula if len(slide.formula) <= 18 else self.font_large
            formula_y = 527 if formula_font is self.font_formula else 532
            self._text_center(draw, formula_y, slide.formula, formula_font, self.white)

        total = len(INTRO_SLIDES)
        dot_y = 646
        start_x = self.width // 2 - (total - 1) * 18
        for i in range(total):
            r = 7 if i == state.intro_index else 5
            colour = accent if i == state.intro_index else (70, 78, 88)
            cx = start_x + i * 36
            draw.ellipse((cx - r, dot_y - r, cx + r, dot_y + r), fill=colour)

        hint = "Button 2: continue    Button 3: reveal    Button 1: back"
        self._text_center(draw, 675, hint, self.font_small, self.dim)
        return img

    def _draw_interactive(self, state: Scene4State) -> Image.Image:
        img = Image.new("RGB", (self.width, self.height), self.bg)
        draw = ImageDraw.Draw(img)
        palette = PALETTES[state.palette_index]
        accent = palette["accent"]

        self._draw_interactive_title(draw, state, accent)
        self._draw_main_grid(img, draw, state, palette)
        self._draw_compact_controls(draw, state, accent)
        return img

    def _draw_interactive_title(self, draw, state: Scene4State, accent) -> None:
        self._text(draw, (58, 28), "Escape-time colouring", self.font_large, self.white)
        self._text(draw, (60, 70), "escape time → colour", self.font_formula, accent)

        status = "FILLING" if state.playing else "PAUSED"
        status_colour = (120, 255, 165) if state.playing else (255, 210, 80)
        draw.rounded_rectangle((1054, 36, 1218, 82), radius=14, fill=(14, 18, 26), outline=status_colour, width=2)
        self._text(draw, (1080, 47), status, self.font_normal, status_colour)

        centre = f"centre = {state.centre_r:+.4f} {state.centre_i:+.4f}i"
        self._text(draw, (565, 58), centre, self.font_mono_small, (250, 252, 255))

    def _colour_for_escape(self, n: int, escaped: bool, max_iter: int, palette) -> tuple[int, int, int]:
        if not escaped:
            return self.inside

        t = n / max(1, max_iter)
        t = math.sqrt(clamp_float(t, 0.0, 1.0))
        base = self._mix(palette["low"], palette["high"], t)

        band = 0.75 + 0.25 * math.sin(0.65 * n)
        return tuple(clamp_int(int(channel * band), 0, 255) for channel in base)

    def _draw_main_grid(self, img: Image.Image, draw, state: Scene4State, palette) -> None:
        box = (62, 145, 1218, 610)
        self._panel(draw, box, self.panel, self.panel_outline, width=2, radius=24)
        x0, y0, x1, y1 = box

        self._text(draw, (x0 + 28, y0 + 22), self._main_panel_title(state), self.font_medium, palette["accent"])

        grid_left = x0 + 42
        grid_top = y0 + 70
        grid_right = x1 - 342
        grid_bottom = y1 - 42
        side_x = grid_right + 34

        if state.view_index == 2:
            self._draw_dense_preview(img, draw, state, grid_left, grid_top, grid_right, grid_bottom, palette)
        else:
            self._draw_coarse_grid(draw, state, grid_left, grid_top, grid_right, grid_bottom, palette)

        self._draw_side_readout(draw, state, side_x, y0 + 76, x1 - 42, y1 - 56, palette)

    def _main_panel_title(self, state: Scene4State) -> str:
        if state.view_index == 0:
            return "Each square stores an escape-time number"
        if state.view_index == 1:
            return "The same numbers, now shown as colour"
        return "More samples reveal the familiar shape"

    def _draw_coarse_grid(self, draw, state: Scene4State, left: int, top: int, right: int, bottom: int, palette) -> None:
        counts, escaped = escape_grid(state)
        visible = visible_cell_count(state)
        cell_w = (right - left) / COARSE_COLS
        cell_h = (bottom - top) / COARSE_ROWS

        draw.rectangle((left, top, right, bottom), fill=(8, 11, 18), outline=(92, 106, 118), width=2)

        for row in range(COARSE_ROWS):
            for col in range(COARSE_COLS):
                idx = row * COARSE_COLS + col
                x_a = int(left + col * cell_w)
                y_a = int(top + row * cell_h)
                x_b = int(left + (col + 1) * cell_w)
                y_b = int(top + (row + 1) * cell_h)

                if idx >= visible:
                    draw.rectangle((x_a, y_a, x_b, y_b), fill=(11, 14, 20), outline=(28, 34, 42))
                    continue

                n = int(counts[row, col])
                esc = bool(escaped[row, col])
                if state.view_index == 0:
                    fill = (16, 22, 31) if esc else self.inside
                    draw.rectangle((x_a, y_a, x_b, y_b), fill=fill, outline=(36, 44, 54))
                    text = str(n) if esc else "·"
                    text_colour = palette["accent"] if esc else (80, 88, 98)
                    bbox = draw.textbbox((0, 0), text, font=self.font_tiny)
                    tx = x_a + max(1, (x_b - x_a - (bbox[2] - bbox[0])) // 2)
                    ty = y_a + max(0, (y_b - y_a - (bbox[3] - bbox[1])) // 2 - 1)
                    self._text(draw, (tx, ty), text, self.font_tiny, text_colour)
                else:
                    fill = self._colour_for_escape(n, esc, state.max_iter, palette)
                    draw.rectangle((x_a, y_a, x_b, y_b), fill=fill, outline=(17, 22, 28))

        if 0 < visible < COARSE_COLS * COARSE_ROWS:
            current = visible - 1
            row = current // COARSE_COLS
            col = current % COARSE_COLS
            x_a = int(left + col * cell_w)
            y_a = int(top + row * cell_h)
            x_b = int(left + (col + 1) * cell_w)
            y_b = int(top + (row + 1) * cell_h)
            draw.rectangle((x_a, y_a, x_b, y_b), outline=palette["current"], width=3)

        self._draw_axes_labels(draw, state, left, top, right, bottom)

    def _draw_dense_preview(self, img: Image.Image, draw, state: Scene4State, left: int, top: int, right: int, bottom: int, palette) -> None:
        preview = self._preview_image(state, palette)
        resampling = getattr(getattr(Image, "Resampling", Image), "NEAREST")
        preview = preview.resize((right - left, bottom - top), resampling)
        img.paste(preview, (left, top))
        draw.rectangle((left, top, right, bottom), outline=(92, 106, 118), width=2)
        self._draw_axes_labels(draw, state, left, top, right, bottom)

    def _preview_image(self, state: Scene4State, palette) -> Image.Image:
        key = (
            round(state.centre_r, 6), round(state.centre_i, 6), round(state.view_width, 6),
            state.max_iter, state.palette_index,
        )
        if state.cached_preview_key == key and state.cached_preview is not None:
            return state.cached_preview

        counts, escaped = escape_grid(state, PREVIEW_COLS, PREVIEW_ROWS)
        rgb = np.zeros((PREVIEW_ROWS, PREVIEW_COLS, 3), dtype=np.uint8)
        for row in range(PREVIEW_ROWS):
            for col in range(PREVIEW_COLS):
                rgb[row, col] = self._colour_for_escape(int(counts[row, col]), bool(escaped[row, col]), state.max_iter, palette)

        img = Image.fromarray(rgb, mode="RGB")
        state.cached_preview_key = key
        state.cached_preview = img
        return img

    def _draw_axes_labels(self, draw, state: Scene4State, left: int, top: int, right: int, bottom: int) -> None:
        h = view_height(state)
        label_colour = (172, 182, 192)
        self._text(draw, (left, bottom + 10), f"real {state.centre_r - state.view_width / 2:+.2f}", self.font_small, label_colour)
        right_label = f"{state.centre_r + state.view_width / 2:+.2f}"
        bbox = draw.textbbox((0, 0), right_label, font=self.font_small)
        self._text(draw, (right - (bbox[2] - bbox[0]), bottom + 10), right_label, self.font_small, label_colour)
        self._text(draw, (left - 8, top - 24), f"imag {state.centre_i + h / 2:+.2f}", self.font_small, label_colour)
        self._text(draw, (left - 8, bottom - 2), f"{state.centre_i - h / 2:+.2f}", self.font_small, label_colour)

    def _draw_side_readout(self, draw, state: Scene4State, x0: int, y0: int, x1: int, y1: int, palette) -> None:
        draw.rounded_rectangle((x0, y0, x1, y1), radius=18, fill=(11, 15, 22), outline=(39, 52, 62), width=1)

        counts, escaped = escape_grid(state)
        total = COARSE_COLS * COARSE_ROWS
        visible = visible_cell_count(state)
        visible_counts = counts.reshape(-1)[:visible]
        visible_escaped = escaped.reshape(-1)[:visible]
        escaped_seen = int(np.count_nonzero(visible_escaped)) if visible > 0 else 0
        inside_seen = visible - escaped_seen

        self._text(draw, (x0 + 18, y0 + 18), "What each pixel stores", self.font_normal, palette["accent"])
        self._text(draw, (x0 + 22, y0 + 64), "z starts at 0", self.font_mono_small, self.white)
        self._text(draw, (x0 + 22, y0 + 94), "repeat z → z² + c", self.font_mono_small, self.white)
        self._text(draw, (x0 + 22, y0 + 124), "stop when |z| > 2", self.font_mono_small, self.white)

        self._text(draw, (x0 + 22, y0 + 166), "Grid progress", self.font_medium, palette["current"])
        self._text(draw, (x0 + 22, y0 + 204), f"tested = {visible}/{total}", self.font_mono_small, self.white)
        self._text(draw, (x0 + 22, y0 + 232), f"escaped = {escaped_seen}", self.font_mono_small, self.white)
        self._text(draw, (x0 + 22, y0 + 260), f"dark / inside = {inside_seen}", self.font_mono_small, self.white)

        if visible > 0:
            recent = visible_counts[-3:]
            recent_text = "  →  ".join(str(int(v)) for v in recent)
        else:
            recent_text = "not started"
        self._text(draw, (x0 + 22, y0 + 272), "recent counts", self.font_normal, self.dim)
        self._text(draw, (x0 + 22, y0 + 300), recent_text, self.font_mono_small, self.white)

    def _draw_compact_controls(self, draw, state: Scene4State, accent) -> None:
        box = (62, 632, 1218, 694)
        self._panel(draw, box, (12, 16, 23), (45, 62, 70), width=1, radius=18)

        message = self._status_message(state)
        self._text(draw, (86, 642), message, self.font_normal, self.white)
        self._text(draw, (86, 670), state.status, self.font_small, self.dim)

        controls = "Joystick pan   B3 fill/pause   Enc1 zoom   Enc2 checks   stick reset   B2 next   B1 back   B5 palette"
        bbox = draw.textbbox((0, 0), controls, font=self.font_small)
        text_w = bbox[2] - bbox[0]
        self._text(draw, (1195 - text_w, 665), controls, self.font_small, accent)

    def _status_message(self, state: Scene4State) -> str:
        if state.view_index == 0:
            return "First, look at the raw escape-time numbers."
        if state.view_index == 1:
            return "Now the same numbers are mapped to colour."
        return "With more samples, the Mandelbrot shape starts to appear."


# PYNQ VDMA display backend

def resolve_bit_path(path_or_dir: str) -> str:
    """Accept either a .bit file path or a directory containing the current .bit."""
    if os.path.isfile(path_or_dir):
        return path_or_dir

    if not os.path.isdir(path_or_dir):
        raise FileNotFoundError(f"Bitstream path not found: {path_or_dir}")

    candidates = sorted(
        glob.glob(os.path.join(path_or_dir, "*.bit")),
        key=lambda p: os.path.getmtime(p),
        reverse=True,
    )
    if not candidates:
        raise FileNotFoundError(f"No .bit file found in directory: {path_or_dir}")
    return candidates[0]


def decode_vdma_status(status: int) -> list[str]:
    flags = []
    if status & (1 << 0):  flags.append("HALTED")
    if status & (1 << 1):  flags.append("VDMA_INTERNAL_ERR")
    if status & (1 << 4):  flags.append("SLAVE_ERR")
    if status & (1 << 5):  flags.append("DECODE_ERR")
    if status & (1 << 8):  flags.append("SOF_EARLY_ERR")
    if status & (1 << 12): flags.append("FRAME_COUNT_IRQ")
    if status & (1 << 13): flags.append("DELAY_COUNT_IRQ")
    if status & (1 << 14): flags.append("ERROR_IRQ")
    if status & (1 << 16): flags.append("PARKED_OR_FRAME_SYNC")
    return flags


class VdmaFramebufferDisplay:
    def __init__(self, bit_path: str, width: int = WIDTH, height: int = HEIGHT, download: bool = True):
        from pynq import Overlay, allocate, MMIO

        self.width = width
        self.height = height
        self.bpp = BPP
        self.stride = width * self.bpp

        resolved_bit = resolve_bit_path(bit_path)
        if not os.path.exists(resolved_bit):
            raise FileNotFoundError(
                f"Bitstream not found: {resolved_bit}\n"
                "Use --bit to point at your current FractalScope .bit file or directory."
            )

        print(f"Loading overlay: {resolved_bit}")
        self.overlay = Overlay(resolved_bit)
        if download:
            self.overlay.download()

        vdma_ip = self._find_ip_by_name_contains("axi_vdma")
        info = self.overlay.ip_dict[vdma_ip]
        self.vdma = MMIO(info["phys_addr"], info["addr_range"])
        print(f"Using VDMA IP: {vdma_ip} @ 0x{info['phys_addr']:08X}")

        self.buffers = [
            allocate(shape=(height, width), dtype=np.uint32),
            allocate(shape=(height, width), dtype=np.uint32),
        ]
        for i, fb in enumerate(self.buffers):
            fb[:] = 0x00000000
            fb.flush()
            print(f"Framebuffer {i}: phys=0x{fb.physical_address:08X}, nbytes={fb.nbytes}")

        self.front_index = 0
        self._start_mm2s()

    def close(self) -> None:
        try:
            self.vdma.write(MM2S_DMACR, 0)
        except Exception:
            pass

        for fb in getattr(self, "buffers", []):
            try:
                fb.freebuffer()
            except Exception:
                pass

    def _find_ip_by_name_contains(self, substr: str) -> str:
        matches = [name for name in self.overlay.ip_dict if substr.lower() in name.lower()]
        if not matches:
            raise RuntimeError(f"No IP name contains {substr!r}. Available: {list(self.overlay.ip_dict)}")
        return matches[0]

    def _reset_mm2s(self, timeout_s: float = 1.0) -> bool:
        self.vdma.write(MM2S_DMACR, VDMA_DMACR_RESET)
        t0 = time.time()
        while time.time() - t0 < timeout_s:
            if (self.vdma.read(MM2S_DMACR) & VDMA_DMACR_RESET) == 0:
                return True
            time.sleep(0.001)
        return False

    def _start_mm2s(self) -> None:
        print("Resetting VDMA MM2S...")
        ok = self._reset_mm2s()
        print("MM2S reset ok:", ok)

        self.vdma.write(MM2S_DMASR, 0x0000FFFF)

        self.vdma.write(MM2S_START_ADDR1, self.buffers[0].physical_address)
        self.vdma.write(MM2S_START_ADDR2, self.buffers[1].physical_address)

        self.vdma.write(MM2S_DMACR, VDMA_DMACR_RUNSTOP)
        self.vdma.write(PARK_PTR_REG, 0)

        self.vdma.write(MM2S_FRMDLY_STRIDE, self.stride)
        self.vdma.write(MM2S_HSIZE, self.stride)
        self.vdma.write(MM2S_VSIZE, self.height)

        time.sleep(0.1)
        status = self.vdma.read(MM2S_DMASR)
        print(f"MM2S status: 0x{status:08X} {decode_vdma_status(status)}")

    def show(self, packed_rgb: np.ndarray) -> None:
        if packed_rgb.shape != (self.height, self.width):
            raise ValueError(f"Expected frame shape {(self.height, self.width)}, got {packed_rgb.shape}")

        back_index = 1 - self.front_index
        fb = self.buffers[back_index]
        fb[:] = packed_rgb
        fb.flush()

        self.vdma.write(PARK_PTR_REG, back_index)
        self.front_index = back_index


# Main loop

def run_scene(args: argparse.Namespace) -> None:
    display = VdmaFramebufferDisplay(
        bit_path=args.bit,
        width=args.width,
        height=args.height,
        download=not args.no_download,
    )
    renderer = Scene4Renderer(args.width, args.height, swap_rb=args.swap_rb, fade_s=args.fade_seconds)
    state = Scene4State(max_iter=args.iterations)
    state.intro_fade_start = time.monotonic()

    print()
    print(f"Escape-time colouring walkthrough is now running on HDMI. ({SCRIPT_VERSION})")
    print("Use keyboard over SSH as the controller emulator. Press Q to quit.")
    print("N continue | B back | Space reveal/fill | WASD/arrows pan | [ ] zoom | - = checks | R reset")

    try:
        with raw_terminal():
            last_draw = 0.0
            running = True
            while running:
                now = time.monotonic()

                while True:
                    event = read_event(0.0)
                    if event is None:
                        break
                    running = handle_event(state, event, now, renderer.fade_s)
                    if not running:
                        break

                update_scene(state, now)

                animating = renderer.intro_animating(state, now)
                interval = 1.0 / max(1.0, args.fps)
                if (state.dirty or animating) and (now - last_draw >= interval):
                    frame = renderer.draw(state, now)
                    display.show(frame)
                    last_draw = now
                    state.dirty = False

                time.sleep(0.004)
    finally:
        display.close()
        print("\nWalkthrough stopped.")


def self_test() -> None:
    state = Scene4State()
    counts, escaped = escape_grid(state)
    assert counts.shape == (COARSE_ROWS, COARSE_COLS)
    assert escaped.shape == (COARSE_ROWS, COARSE_COLS)
    assert counts.dtype == np.uint16

    n, esc = mandelbrot_escape(0.0 + 0.0j, 20)
    assert n == 20
    assert not esc

    n, esc = mandelbrot_escape(2.0 + 0.0j, 20)
    assert n <= 2
    assert esc

    before = state.centre_r
    state.phase = AppPhase.INTERACTIVE
    handle_interactive_event(state, Event(EventKind.JOY_RIGHT))
    assert state.centre_r > before
    assert state.reveal_count == 0
    assert not state.playing

    renderer = Scene4Renderer(1280, 720)
    state.phase = AppPhase.INTRO
    state.intro_fade_start = time.monotonic() - 1.0
    packed = renderer.draw(state, time.monotonic())
    assert packed.shape == (720, 1280)
    assert packed.dtype == np.uint32

    state.phase = AppPhase.INTERACTIVE
    state.reveal_count = COARSE_COLS * COARSE_ROWS
    packed = renderer.draw(state, time.monotonic())
    assert packed.shape == (720, 1280)
    assert packed.dtype == np.uint32

    state.view_index = 2
    packed = renderer.draw(state, time.monotonic())
    assert packed.shape == (720, 1280)
    assert packed.dtype == np.uint32

    assert resolve_bit_path(__file__) == __file__

    print("Self-test PASS")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="FractalScope escape-time colouring HDMI prototype")
    parser.add_argument("--bit", default=DEFAULT_BIT_PATH, help="Path to the custom FractalScope .bit file or its directory")
    parser.add_argument("--width", type=int, default=WIDTH, help="Framebuffer width")
    parser.add_argument("--height", type=int, default=HEIGHT, help="Framebuffer height")
    parser.add_argument("--iterations", type=int, default=32, help="Initial maximum escape checks")
    parser.add_argument("--fps", type=float, default=12.0, help="HDMI UI redraw rate while animating/fading")
    parser.add_argument("--fade-seconds", type=float, default=0.55, help="Intro text fade duration")
    parser.add_argument("--swap-rb", action="store_true", help="Swap red and blue when packing 0x00RRGGBB")
    parser.add_argument("--no-download", action="store_true", help="Do not call overlay.download()")
    parser.add_argument("--self-test", action="store_true", help="Run local checks without PYNQ hardware")
    return parser.parse_args()


def main() -> None:
    args = parse_args()

    if args.self_test:
        self_test()
        return

    run_scene(args)


if __name__ == "__main__":
    main()
