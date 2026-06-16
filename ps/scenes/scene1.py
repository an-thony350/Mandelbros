#!/usr/bin/env python3
r"""
This is a PS-drawn educational scene introducing the idea of recurrence relations

Controls:
    N / Enter   Button 2: reveal next intro item / next stage
    B           Button 1: previous intro item / previous stage
    Space       Button 3: reveal intro slide / play-pause recurrence
    [ / ]       Encoder 1: change x0 in repeated squaring, c in parameter stage
    - / =       Encoder 2: change displayed iteration limit
    R           Joystick click: reset current orbit
    P           Button 5: cycle visual palette
    Q           Quit
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

SCRIPT_VERSION = "v2_intro_slides_2026_06_10_streamlined"


# Display constants
WIDTH = 1280
HEIGHT = 720
BPP = 4

# Bitstream Path
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


# State and recurrence model

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
        title="Start with one number",
        groups=(
            "Pick a starting value.",
            "Apply one simple rule.",
            "Feed the answer back into the same rule.",
        ),
        formula="x → x²",
    ),
    IntroSlide(
        title="Repeating creates behaviour",
        groups=(
            "Some starting values settle down.",
            "Some stay fixed.",
            "Some grow without limit.",
            "The interesting part is not one step, but the whole orbit.",
        ),
        formula="0.5 → 0.25 → 0.0625 → ...",
    ),
    IntroSlide(
        title="Now try it yourself",
        groups=(
            "Use the encoder to choose the starting number.",
            "Press play to watch the orbit move.",
            "The number line shows where the value is now.",
            "The graph shows the history of the orbit.",
        ),
        formula=None,
    ),
]


@dataclass
class Scene1State:
    phase: AppPhase = AppPhase.INTRO

    intro_index: int = 0
    intro_progress: int = 1       # number of visible/revealing groups
    intro_fade_start: float = 0.0

    step_index: int = 0           # 0: x -> x^2, 1: x -> x^2 + c
    x0: float = 0.50
    c: float = -0.50

    max_iter: int = 12
    current_iter: int = 0
    playing: bool = False

    palette_index: int = 0
    status: str = "Press play when you are ready."

    last_tick: float = 0.0
    dirty: bool = True


PALETTES = [
    {
        "name": "Cyan",
        "accent": (80, 230, 230),
        "trail": (80, 230, 230),
        "current": (255, 120, 235),
    },
    {
        "name": "Fire",
        "accent": (255, 170, 70),
        "trail": (255, 120, 45),
        "current": (255, 230, 120),
    },
    {
        "name": "Ice",
        "accent": (130, 190, 255),
        "trail": (100, 175, 255),
        "current": (245, 250, 255),
    },
    {
        "name": "Mono",
        "accent": (225, 225, 225),
        "trail": (185, 185, 185),
        "current": (255, 255, 255),
    },
]


def clamp_float(value: float, lo: float, hi: float) -> float:
    return max(lo, min(hi, value))


def clamp_int(value: int, lo: int, hi: int) -> int:
    return max(lo, min(hi, value))


def recurrence_values(state: Scene1State) -> tuple[list[float], bool]:
    """Return values from x_0 up to the max_iter or divergence threshold."""
    values = [state.x0 if state.step_index == 0 else 0.0]
    diverged = abs(values[0]) > 100.0

    while len(values) <= state.max_iter and not diverged:
        x = values[-1]
        nxt = x * x if state.step_index == 0 else x * x + state.c
        values.append(nxt)
        diverged = abs(nxt) > 100.0

    return values, diverged


def visible_values(state: Scene1State) -> tuple[list[float], bool]:
    values, diverged = recurrence_values(state)
    n = min(state.current_iter + 1, len(values))
    return values[:n], diverged and n == len(values)


def classify_step_1a(values: Sequence[float]) -> str:
    x0 = values[0]
    x = values[-1]

    if abs(x0 - 1.0) < 1e-9:
        return "Fixed point: 1 stays at 1."
    if abs(x0 + 1.0) < 1e-9:
        return "-1 jumps to 1, then stays fixed."
    if abs(x) > 100.0:
        return "Diverging: the values have grown beyond 100."
    if abs(x0) < 1.0:
        return "Settling down towards 0."
    if abs(x0) > 1.0:
        return "Growing quickly; press play to watch it run away."
    return "On the boundary."


def classify_step_1b(values: Sequence[float]) -> str:
    x = values[-1]
    if abs(x) > 100.0:
        return "Diverging: the orbit has grown beyond 100."
    return "Bounded so far. Changing c changes the orbit."


def current_formula(state: Scene1State) -> str:
    return "x → x²" if state.step_index == 0 else "x → x² + c"


def current_title(state: Scene1State) -> str:
    return "Repeated squaring" if state.step_index == 0 else "Adding a parameter"


def fade_complete(state: Scene1State, now: float, fade_s: float) -> bool:
    return now - state.intro_fade_start >= fade_s


def current_intro_slide(state: Scene1State) -> IntroSlide:
    return INTRO_SLIDES[state.intro_index]


def intro_item_count(slide: IntroSlide) -> int:
    return len(slide.groups) + (1 if slide.formula else 0)


def enter_interactive(state: Scene1State) -> None:
    state.phase = AppPhase.INTERACTIVE
    state.playing = False
    state.current_iter = 0
    state.status = "Press play to watch the orbit."
    state.dirty = True


def handle_intro_event(state: Scene1State, event: Event, now: float, fade_s: float) -> bool:
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
        # During intro slides, Space means "reveal this slide" rather than play/pause.
        state.intro_progress = intro_item_count(slide)
        state.intro_fade_start = now - fade_s
        state.dirty = True
        return True

    if event.kind == EventKind.PALETTE_CYCLE:
        state.palette_index = (state.palette_index + 1) % len(PALETTES)
        state.dirty = True
        return True

    return True


def handle_interactive_event(state: Scene1State, event: Event) -> bool:
    if event.kind == EventKind.SCENE_ACTION:
        values, _ = recurrence_values(state)
        end_iter = min(state.max_iter, len(values) - 1)
        if state.current_iter >= end_iter:
            state.current_iter = 0
        state.playing = not state.playing
        state.status = "Playing." if state.playing else "Paused."
        state.dirty = True
        return True

    if event.kind == EventKind.RESET:
        state.current_iter = 0
        state.playing = False
        state.status = "Orbit reset."
        state.dirty = True
        return True

    if event.kind == EventKind.NEXT:
        if state.step_index == 0:
            state.step_index = 1
            state.current_iter = 0
            state.playing = False
            state.status = "Now the rule includes a parameter."
        else:
            state.status = "Next topic will introduce motion in a plane."
        state.dirty = True
        return True

    if event.kind == EventKind.BACK:
        if state.step_index == 1:
            state.step_index = 0
            state.current_iter = 0
            state.playing = False
            state.status = "Back to repeated squaring."
        else:
            state.phase = AppPhase.INTRO
            state.intro_index = len(INTRO_SLIDES) - 1
            state.intro_progress = intro_item_count(current_intro_slide(state))
            state.intro_fade_start = time.monotonic() - 1.0
            state.playing = False
        state.dirty = True
        return True

    if event.kind == EventKind.ENC1_DELTA:
        delta = 0.05 * event.delta
        if state.step_index == 0:
            state.x0 = clamp_float(state.x0 + delta, -2.0, 2.0)
            state.status = f"x0 = {state.x0:+.4f}"
        else:
            state.c = clamp_float(state.c + delta, -2.0, 0.5)
            state.status = f"c = {state.c:+.4f}"
        state.current_iter = 0
        state.playing = False
        state.dirty = True
        return True

    if event.kind == EventKind.ENC2_DELTA:
        state.max_iter = clamp_int(state.max_iter + event.delta, 1, 100)
        state.current_iter = min(state.current_iter, state.max_iter)
        state.status = f"Iterations shown: {state.max_iter}"
        state.dirty = True
        return True

    if event.kind == EventKind.PALETTE_CYCLE:
        state.palette_index = (state.palette_index + 1) % len(PALETTES)
        state.status = f"Colours: {PALETTES[state.palette_index]['name']}"
        state.dirty = True
        return True

    if event.kind in {EventKind.JOY_LEFT, EventKind.JOY_RIGHT, EventKind.JOY_UP, EventKind.JOY_DOWN}:
        # Deliberately no-op for the real-number scene.
        return True

    if event.kind == EventKind.MENU_TOGGLE:
        state.status = "Menu comes later; this view is focused on the recurrence."
        state.dirty = True
        return True

    if event.kind == EventKind.FUNCTION:
        state.status = "This button is unused for this first rule."
        state.dirty = True
        return True

    return True


def handle_event(state: Scene1State, event: Event, now: float, fade_s: float) -> bool:
    """Apply a controller-style event. Return False to quit."""
    if event.kind == EventKind.QUIT:
        return False

    if state.phase == AppPhase.INTRO:
        return handle_intro_event(state, event, now, fade_s)
    return handle_interactive_event(state, event)


def update_scene(state: Scene1State, now: float) -> None:
    if state.last_tick == 0.0:
        state.last_tick = now

    if state.phase != AppPhase.INTERACTIVE or not state.playing:
        return

    # delib. slow
    if now - state.last_tick < 0.42:
        return

    state.last_tick = now
    values, _ = recurrence_values(state)
    end_iter = min(state.max_iter, len(values) - 1)

    if state.current_iter < end_iter:
        state.current_iter += 1
        state.dirty = True
    else:
        state.playing = False
        state.status = "Reached the displayed iteration limit."
        state.dirty = True


# HDMI drawing

class Scene1Renderer:
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

    def intro_animating(self, state: Scene1State, now: float) -> bool:
        # switched to force static slide changes
        return False

    def draw(self, state: Scene1State, now: float) -> np.ndarray:
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

    def _draw_intro(self, state: Scene1State, now: float) -> Image.Image:
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

    def _draw_interactive(self, state: Scene1State) -> Image.Image:
        img = Image.new("RGB", (self.width, self.height), self.bg)
        draw = ImageDraw.Draw(img)
        palette = PALETTES[state.palette_index]
        accent = palette["accent"]

        self._draw_interactive_title(draw, state, accent)
        self._draw_number_line(draw, state, palette)
        self._draw_orbit_graph(draw, state, palette)
        self._draw_compact_controls(draw, state, accent)
        return img

    def _draw_interactive_title(self, draw, state: Scene1State, accent) -> None:
        self._text(draw, (58, 28), current_title(state), self.font_large, self.white)
        self._text(draw, (60, 70), current_formula(state), self.font_formula, accent)

        status = "PLAYING" if state.playing else "PAUSED"
        status_colour = (120, 255, 165) if state.playing else (255, 210, 80)
        draw.rounded_rectangle((1054, 36, 1218, 82), radius=14, fill=(14, 18, 26), outline=status_colour, width=2)
        self._text(draw, (1084, 47), status, self.font_normal, status_colour)

        if state.step_index == 0:
            param = f"x₀ = {state.x0:+.4f}"
        else:
            param = f"c = {state.c:+.4f}     x₀ = +0.0000"
        self._text(draw, (520, 50), param, self.font_mono, (250, 252, 255))
        self._text(draw, (520, 80), f"iterations shown: {state.max_iter}", self.font_mono_small, self.dim)

    def _draw_number_line(self, draw, state: Scene1State, palette) -> None:
        box = (62, 145, 1218, 330)
        self._panel(draw, box, self.panel, self.panel_outline, width=2, radius=24)
        x0, y0, x1, y1 = box
        cx0, cx1 = x0 + 72, x1 - 72
        mid_y = y0 + 88

        self._text(draw, (x0 + 28, y0 + 22), "Number line", self.font_medium, palette["accent"])

        display_min = -2.0
        display_max = 2.0

        def map_x(value: float) -> int:
            clipped = clamp_float(value, display_min, display_max)
            t = (clipped - display_min) / (display_max - display_min)
            return int(cx0 + t * (cx1 - cx0))

        draw.line((cx0, mid_y, cx1, mid_y), fill=(170, 176, 184), width=3)

        for tick in [-2, -1, 0, 1, 2]:
            px = map_x(tick)
            tick_len = 20 if tick == 0 else 14
            draw.line((px, mid_y - tick_len, px, mid_y + tick_len), fill=(170, 176, 184), width=2)
            self._text(draw, (px - 14, mid_y + 28), f"{tick}", self.font_small, (190, 198, 205))

        visible, _ = visible_values(state)
        if len(visible) >= 2:
            points = [(map_x(v), mid_y) for v in visible if abs(v) <= display_max]
            for a, b in zip(points, points[1:]):
                draw.line((a[0], a[1], b[0], b[1]), fill=(60, 90, 96), width=1)

        for i, value in enumerate(visible):
            px = map_x(value)
            radius = 5 + min(i, 6)
            fade = min(255, 80 + i * 22)
            colour = (
                min(255, palette["trail"][0] * fade // 255),
                min(255, palette["trail"][1] * fade // 255),
                min(255, palette["trail"][2] * fade // 255),
            )
            if i == len(visible) - 1:
                colour = palette["current"]
                radius = 13

            if abs(value) > display_max:
                px = cx1 + 28 if value > 0 else cx0 - 28
                tri = [(px, mid_y), (px - 14, mid_y - 11), (px - 14, mid_y + 11)] if value > 0 else [
                    (px, mid_y), (px + 14, mid_y - 11), (px + 14, mid_y + 11)
                ]
                draw.polygon(tri, fill=colour)
            else:
                draw.ellipse((px - radius, mid_y - radius, px + radius, mid_y + radius), fill=colour)

        current = visible[-1]
        self._text(draw, (x1 - 335, y0 + 24), f"n = {state.current_iter}", self.font_mono_small, self.white)
        self._text(draw, (x1 - 335, y0 + 54), f"xₙ = {current:+.4f}", self.font_mono_small, palette["current"])

    def _draw_orbit_graph(self, draw, state: Scene1State, palette) -> None:
        box = (62, 360, 1218, 610)
        self._panel(draw, box, self.panel, self.panel_outline, width=2, radius=24)
        x0, y0, x1, y1 = box
        self._text(draw, (x0 + 28, y0 + 20), "Orbit history", self.font_medium, palette["accent"])

        plot_left = x0 + 78
        plot_right = x1 - 48
        plot_top = y0 + 72
        plot_bottom = y1 - 56

        draw.line((plot_left, plot_bottom, plot_right, plot_bottom), fill=(130, 138, 146), width=2)
        draw.line((plot_left, plot_top, plot_left, plot_bottom), fill=(130, 138, 146), width=2)

        visible, _ = visible_values(state)
        y_abs_max = max(1.0, min(100.0, max(abs(v) for v in visible)))
        y_abs_max = max(2.0, math.ceil(y_abs_max))

        def map_point(i: int, value: float) -> tuple[int, int]:
            denom = max(1, state.max_iter)
            px = int(plot_left + (i / denom) * (plot_right - plot_left))
            clipped = clamp_float(value, -y_abs_max, y_abs_max)
            t = (clipped + y_abs_max) / (2.0 * y_abs_max)
            py = int(plot_bottom - t * (plot_bottom - plot_top))
            return px, py

        zero_y = map_point(0, 0.0)[1]
        draw.line((plot_left, zero_y, plot_right, zero_y), fill=(62, 72, 82), width=1)

        points = [map_point(i, v) for i, v in enumerate(visible)]
        if len(points) >= 2:
            draw.line(points, fill=palette["trail"], width=4)

        for i, (px, py) in enumerate(points):
            r = 4 if i != len(points) - 1 else 9
            colour = palette["trail"] if i != len(points) - 1 else palette["current"]
            draw.ellipse((px - r, py - r, px + r, py + r), fill=colour)

        self._text(draw, (plot_left - 52, plot_top - 8), f"+{y_abs_max:.0f}", self.font_small, (170, 178, 186))
        self._text(draw, (plot_left - 38, zero_y - 10), "0", self.font_small, (170, 178, 186))
        self._text(draw, (plot_left - 52, plot_bottom - 12), f"-{y_abs_max:.0f}", self.font_small, (170, 178, 186))

        recent = visible[-5:]
        recent_text = "  →  ".join(f"{v:+.4f}" if abs(v) <= 9999 else f"{v:+.2e}" for v in recent)
        self._text(draw, (plot_left, y1 - 35), recent_text, self.font_mono_small, (232, 236, 240))

    def _draw_compact_controls(self, draw, state: Scene1State, accent) -> None:
        box = (62, 632, 1218, 694)
        self._panel(draw, box, (12, 16, 23), (45, 62, 70), width=1, radius=18)

        visible, _ = visible_values(state)
        message = classify_step_1a(visible) if state.step_index == 0 else classify_step_1b(visible)

        self._text(draw, (86, 642), message, self.font_normal, self.white)
        self._text(draw, (86, 670), state.status, self.font_small, self.dim)

        controls = "B3 play/pause   Enc1 value   Enc2 iter   stick reset   B2 next   B1 back   B5 palette"
        bbox = draw.textbbox((0, 0), controls, font=self.font_small)
        text_w = bbox[2] - bbox[0]
        self._text(draw, (1195 - text_w, 665), controls, self.font_small, accent)


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
        # Import here so --self-test and syntax checks can run away from the PYNQ board.
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

        # Clear sticky status bits where supported.
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
    renderer = Scene1Renderer(args.width, args.height, swap_rb=args.swap_rb, fade_s=args.fade_seconds)
    state = Scene1State(max_iter=args.iterations)
    state.intro_fade_start = time.monotonic()

    print()
    print(f"Opening recurrence walkthrough is now running on HDMI. ({SCRIPT_VERSION})")
    print("Use keyboard over SSH as the controller emulator. Press Q to quit.")
    print("N continue | B back | Space reveal/play | [ ] Encoder 1 | - = Encoder 2 | R reset")

    try:
        with raw_terminal():
            last_draw = 0.0
            running = True
            while running:
                now = time.monotonic()

                # Drain all pending keyboard/controller events.
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
    state = Scene1State()
    state.current_iter = 5
    values, diverged = visible_values(state)
    assert len(values) == 6
    assert not diverged

    state.step_index = 1
    state.c = -0.75
    state.max_iter = 20
    values, _ = recurrence_values(state)
    assert values[0] == 0.0
    assert len(values) > 1

    renderer = Scene1Renderer(1280, 720)
    state.phase = AppPhase.INTRO
    state.intro_fade_start = time.monotonic() - 1.0
    packed = renderer.draw(state, time.monotonic())
    assert packed.shape == (720, 1280)
    assert packed.dtype == np.uint32

    state.phase = AppPhase.INTERACTIVE
    packed = renderer.draw(state, time.monotonic())
    assert packed.shape == (720, 1280)
    assert packed.dtype == np.uint32

    assert resolve_bit_path("/mnt/data/scene1.py").endswith("scene1.py")

    print("Self-test PASS")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="FractalScope opening recurrence HDMI prototype")
    parser.add_argument("--bit", default=DEFAULT_BIT_PATH, help="Path to the custom FractalScope .bit file or its directory")
    parser.add_argument("--width", type=int, default=WIDTH, help="Framebuffer width")
    parser.add_argument("--height", type=int, default=HEIGHT, help="Framebuffer height")
    parser.add_argument("--iterations", type=int, default=12, help="Initial displayed iteration limit")
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
