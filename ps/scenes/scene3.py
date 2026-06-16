#!/usr/bin/env python3
r"""
This PS-drawn educational scene introduces the escape-radius test

Controls:
    N / Enter       Button 2: reveal next intro item / next stage
    B               Button 1: previous intro item / previous stage
    Space           Button 3: reveal intro slide / play-pause recurrence
    W/A/S/D/arrows  Joystick: move c in the complex plane
    [ / ]           Encoder 1: zoom the visual plane
    - / =           Encoder 2: change displayed iteration/check length
    R               Joystick click: reset current orbit
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

SCRIPT_VERSION = "scene3_escape_radius_2026_06_10_streamlined"


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
        title="Measure distance from 0",
        groups=(
            "In the plane, an orbit can move in any direction.",
            "So we track its distance from the centre.",
            "That distance is written as |z|.",
        ),
        formula="|z|",
    ),
    IntroSlide(
        title="Draw a circle of radius 2",
        groups=(
            "The circle marks every point with distance 2.",
            "For this repeated rule, crossing it is a point of no return.",
            "Once |z| is bigger than 2, the orbit has escaped.",
        ),
        formula="|z| > 2",
    ),
    IntroSlide(
        title="Now test the orbit",
        groups=(
            "Move c around the plane.",
            "Press play and watch z step forward.",
            "If the trail crosses the circle, mark it as escaped.",
            "If it stays inside, keep checking more iterations.",
        ),
        formula=None,
    ),
]


@dataclass
class Scene3State:
    phase: AppPhase = AppPhase.INTRO

    intro_index: int = 0
    intro_progress: int = 1
    intro_fade_start: float = 0.0

    c_r: float = 0.40
    c_i: float = 0.40
    view_radius: float = 2.35
    escape_radius: float = 2.0

    max_iter: int = 24
    current_iter: int = 0
    playing: bool = False

    palette_index: int = 0
    status: str = "Press play to test the escape circle."

    last_tick: float = 0.0
    dirty: bool = True


PALETTES = [
    {
        "name": "Cyan",
        "accent": (80, 230, 230),
        "trail": (80, 230, 230),
        "current": (255, 120, 235),
        "c_point": (255, 230, 120),
    },
    {
        "name": "Fire",
        "accent": (255, 170, 70),
        "trail": (255, 120, 45),
        "current": (255, 230, 120),
        "c_point": (120, 225, 255),
    },
    {
        "name": "Ice",
        "accent": (130, 190, 255),
        "trail": (100, 175, 255),
        "current": (245, 250, 255),
        "c_point": (255, 215, 115),
    },
    {
        "name": "Mono",
        "accent": (225, 225, 225),
        "trail": (185, 185, 185),
        "current": (255, 255, 255),
        "c_point": (230, 230, 230),
    },
]


def clamp_float(value: float, lo: float, hi: float) -> float:
    return max(lo, min(hi, value))


def clamp_int(value: int, lo: int, hi: int) -> int:
    return max(lo, min(hi, value))


def fmt_complex(z: complex) -> str:
    sign = "+" if z.imag >= 0 else "-"
    return f"{z.real:+.4f} {sign} {abs(z.imag):.4f}i"


def recurrence_values(state: Scene3State) -> tuple[list[complex], bool]:
    """Return z_0, z_1, ... until max_iter or the escape radius is crossed."""
    c = complex(state.c_r, state.c_i)
    values = [0.0 + 0.0j]
    escaped = False

    while len(values) <= state.max_iter and not escaped:
        z = values[-1]
        nxt = z * z + c
        values.append(nxt)
        escaped = abs(nxt) > state.escape_radius

    return values, escaped


def visible_values(state: Scene3State) -> tuple[list[complex], bool]:
    values, escaped = recurrence_values(state)
    n = min(state.current_iter + 1, len(values))
    visible = values[:n]
    visible_escaped = escaped and n == len(values) and abs(visible[-1]) > state.escape_radius
    return visible, visible_escaped


def escape_index(values: Sequence[complex], radius: float) -> int | None:
    for i, z in enumerate(values):
        if abs(z) > radius:
            return i
    return None


def classify_orbit(values: Sequence[complex], escaped: bool, radius: float = 2.0) -> str:
    if escaped:
        return "Escaped: once |z| is bigger than 2, the orbit will keep growing."
    if len(values) <= 1:
        return "The orbit starts at 0. Press play to test it."

    mag = abs(values[-1])
    if mag > 0.85 * radius:
        return "Close to the escape circle; keep stepping carefully."
    return "Still inside the escape circle."


def fade_complete(state: Scene3State, now: float, fade_s: float) -> bool:
    return now - state.intro_fade_start >= fade_s


def current_intro_slide(state: Scene3State) -> IntroSlide:
    return INTRO_SLIDES[state.intro_index]


def intro_item_count(slide: IntroSlide) -> int:
    return len(slide.groups) + (1 if slide.formula else 0)


def enter_interactive(state: Scene3State) -> None:
    state.phase = AppPhase.INTERACTIVE
    state.playing = False
    state.current_iter = 0
    state.status = "Press play to test the escape circle."
    state.dirty = True


def handle_intro_event(state: Scene3State, event: Event, now: float, fade_s: float) -> bool:
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


def reset_orbit_after_c_move(state: Scene3State, message: str) -> None:
    state.current_iter = 0
    state.playing = False
    state.status = message
    state.dirty = True


def handle_interactive_event(state: Scene3State, event: Event) -> bool:
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
        state.status = "Next topic will turn escape times into a picture."
        state.dirty = True
        return True

    if event.kind == EventKind.BACK:
        state.phase = AppPhase.INTRO
        state.intro_index = len(INTRO_SLIDES) - 1
        state.intro_progress = intro_item_count(current_intro_slide(state))
        state.intro_fade_start = time.monotonic() - 1.0
        state.playing = False
        state.dirty = True
        return True

    move_step = 0.05
    if event.kind == EventKind.JOY_LEFT:
        state.c_r = clamp_float(state.c_r - move_step, -2.0, 2.0)
        reset_orbit_after_c_move(state, f"c = {state.c_r:+.4f} {state.c_i:+.4f}i")
        return True

    if event.kind == EventKind.JOY_RIGHT:
        state.c_r = clamp_float(state.c_r + move_step, -2.0, 2.0)
        reset_orbit_after_c_move(state, f"c = {state.c_r:+.4f} {state.c_i:+.4f}i")
        return True

    if event.kind == EventKind.JOY_UP:
        state.c_i = clamp_float(state.c_i + move_step, -2.0, 2.0)
        reset_orbit_after_c_move(state, f"c = {state.c_r:+.4f} {state.c_i:+.4f}i")
        return True

    if event.kind == EventKind.JOY_DOWN:
        state.c_i = clamp_float(state.c_i - move_step, -2.0, 2.0)
        reset_orbit_after_c_move(state, f"c = {state.c_r:+.4f} {state.c_i:+.4f}i")
        return True

    if event.kind == EventKind.ENC1_DELTA:
        for _ in range(abs(event.delta)):
            if event.delta > 0:
                state.view_radius *= 0.85
            else:
                state.view_radius /= 0.85
        state.view_radius = clamp_float(state.view_radius, 0.35, 4.0)
        state.status = f"View radius: ±{state.view_radius:.2f}"
        state.dirty = True
        return True

    if event.kind == EventKind.ENC2_DELTA:
        state.max_iter = clamp_int(state.max_iter + event.delta, 2, 120)
        state.current_iter = min(state.current_iter, state.max_iter)
        state.status = "Iteration limit adjusted."
        state.dirty = True
        return True

    if event.kind == EventKind.PALETTE_CYCLE:
        state.palette_index = (state.palette_index + 1) % len(PALETTES)
        state.status = f"Colours: {PALETTES[state.palette_index]['name']}"
        state.dirty = True
        return True

    if event.kind == EventKind.MENU_TOGGLE:
        state.status = "Menu comes later; this view is focused on escape testing."
        state.dirty = True
        return True

    if event.kind == EventKind.FUNCTION:
        state.status = "This button is unused for this escape test."
        state.dirty = True
        return True

    return True


def handle_event(state: Scene3State, event: Event, now: float, fade_s: float) -> bool:
    if event.kind == EventKind.QUIT:
        return False

    if state.phase == AppPhase.INTRO:
        return handle_intro_event(state, event, now, fade_s)
    return handle_interactive_event(state, event)


def update_scene(state: Scene3State, now: float) -> None:
    if state.last_tick == 0.0:
        state.last_tick = now

    if state.phase != AppPhase.INTERACTIVE or not state.playing:
        return

    if now - state.last_tick < 0.42:
        return

    state.last_tick = now
    values, escaped = recurrence_values(state)
    end_iter = min(state.max_iter, len(values) - 1)

    if state.current_iter < end_iter:
        state.current_iter += 1
        state.dirty = True
    else:
        state.playing = False
        hit_at = escape_index(values, state.escape_radius)
        if escaped and hit_at is not None:
            state.status = f"Escaped at n = {hit_at}."
        else:
            state.status = "No escape within the displayed checks."
        state.dirty = True


# HDMI drawing

class Scene3Renderer:
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

    def intro_animating(self, state: Scene3State, now: float) -> bool:
        return False

    def draw(self, state: Scene3State, now: float) -> np.ndarray:
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

    def _draw_intro(self, state: Scene3State, now: float) -> Image.Image:
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

    def _draw_interactive(self, state: Scene3State) -> Image.Image:
        img = Image.new("RGB", (self.width, self.height), self.bg)
        draw = ImageDraw.Draw(img)
        palette = PALETTES[state.palette_index]
        accent = palette["accent"]

        self._draw_interactive_title(draw, state, accent)
        self._draw_complex_plane(draw, state, palette)
        self._draw_compact_controls(draw, state, accent)
        return img

    def _draw_interactive_title(self, draw, state: Scene3State, accent) -> None:
        self._text(draw, (58, 28), "Escape radius", self.font_large, self.white)
        self._text(draw, (60, 70), "|z| > 2  ⇒  escape", self.font_formula, accent)

        status = "PLAYING" if state.playing else "PAUSED"
        status_colour = (120, 255, 165) if state.playing else (255, 210, 80)
        draw.rounded_rectangle((1054, 36, 1218, 82), radius=14, fill=(14, 18, 26), outline=status_colour, width=2)
        self._text(draw, (1084, 47), status, self.font_normal, status_colour)

        c_text = f"c = {state.c_r:+.4f} {state.c_i:+.4f}i"
        self._text(draw, (520, 58), c_text, self.font_mono, (250, 252, 255))

    def _draw_complex_plane(self, draw, state: Scene3State, palette) -> None:
        box = (62, 145, 1218, 610)
        self._panel(draw, box, self.panel, self.panel_outline, width=2, radius=24)
        x0, y0, x1, y1 = box

        self._text(draw, (x0 + 28, y0 + 22), "Complex plane with escape circle", self.font_medium, palette["accent"])

        plot_left = x0 + 58
        plot_right = x1 - 340
        plot_top = y0 + 48
        plot_bottom = y1 - 42
        plot_w = plot_right - plot_left
        plot_h = plot_bottom - plot_top
        side_x = plot_right + 34

        radius = state.view_radius

        def map_z(z: complex) -> tuple[int, int]:
            px = int(plot_left + ((z.real + radius) / (2.0 * radius)) * plot_w)
            py = int(plot_bottom - ((z.imag + radius) / (2.0 * radius)) * plot_h)
            return px, py

        def in_view(z: complex) -> bool:
            return -radius <= z.real <= radius and -radius <= z.imag <= radius

        grid_colour = (31, 39, 51)
        axis_colour = (135, 146, 156)
        label_colour = (172, 182, 192)

        step = self._grid_step(radius)
        tick = -math.floor(radius / step) * step
        while tick <= radius + 1e-9:
            px, _ = map_z(complex(tick, 0.0))
            _, py = map_z(complex(0.0, tick))
            if plot_left <= px <= plot_right:
                draw.line((px, plot_top, px, plot_bottom), fill=grid_colour, width=1)
            if plot_top <= py <= plot_bottom:
                draw.line((plot_left, py, plot_right, py), fill=grid_colour, width=1)
            tick += step

        origin = map_z(0.0 + 0.0j)
        draw.line((origin[0], plot_top, origin[0], plot_bottom), fill=axis_colour, width=2)
        draw.line((plot_left, origin[1], plot_right, origin[1]), fill=axis_colour, width=2)

        self._text(draw, (plot_right - 58, origin[1] + 12), "real", self.font_small, label_colour)
        self._text(draw, (origin[0] + 12, plot_top + 8), "imaginary", self.font_small, label_colour)

        # The radius-2 circle is the main idea in this scene.
        for ring in [1.0, state.escape_radius]:
            if ring <= radius:
                r_px = int((ring / (2.0 * radius)) * min(plot_w, plot_h))
                outline = palette["accent"] if abs(ring - state.escape_radius) < 1e-9 else (42, 51, 64)
                width = 4 if abs(ring - state.escape_radius) < 1e-9 else 1
                draw.ellipse((origin[0] - r_px, origin[1] - r_px, origin[0] + r_px, origin[1] + r_px), outline=outline, width=width)
                if abs(ring - state.escape_radius) < 1e-9:
                    label_x = origin[0] + r_px + 10
                    label_y = origin[1] - r_px - 38
                    self._text(draw, (label_x, label_y), "|z| = 2", self.font_medium, palette["accent"])

        values, escaped = visible_values(state)
        visible_points = [(z, map_z(z)) for z in values if in_view(z)]

        if len(visible_points) >= 2:
            for i in range(len(visible_points) - 1):
                p0 = visible_points[i][1]
                p1 = visible_points[i + 1][1]
                width = 2 if i < len(visible_points) - 2 else 4
                draw.line((p0[0], p0[1], p1[0], p1[1]), fill=palette["trail"], width=width)

        for i, (z, (px, py)) in enumerate(visible_points):
            is_last = i == len(visible_points) - 1
            r = 5 if not is_last else 10
            colour = palette["trail"] if not is_last else palette["current"]
            draw.ellipse((px - r, py - r, px + r, py + r), fill=colour)

        if values and not in_view(values[-1]):
            edge = self._clip_to_plot_edge(values[-1], radius, plot_left, plot_top, plot_right, plot_bottom)
            self._draw_arrow_marker(draw, edge, palette["current"])

        c = complex(state.c_r, state.c_i)
        if in_view(c):
            cx, cy = map_z(c)
            r = 12
            draw.line((cx - r, cy, cx + r, cy), fill=palette["c_point"], width=3)
            draw.line((cx, cy - r, cx, cy + r), fill=palette["c_point"], width=3)
            self._text(draw, (cx + 14, cy - 28), "c", self.font_medium, palette["c_point"])

        ox, oy = origin
        draw.ellipse((ox - 5, oy - 5, ox + 5, oy + 5), fill=(235, 240, 245))
        self._text(draw, (ox + 10, oy + 8), "0", self.font_small, label_colour)

        self._draw_side_readout(draw, state, side_x, y0 + 76, x1 - 42, y1 - 56, values, escaped, palette)

    @staticmethod
    def _grid_step(radius: float) -> float:
        if radius <= 0.6:
            return 0.25
        if radius <= 1.25:
            return 0.5
        if radius <= 2.5:
            return 1.0
        return 2.0

    @staticmethod
    def _clip_to_plot_edge(z: complex, radius: float, left: int, top: int, right: int, bottom: int) -> tuple[int, int]:
        scale = max(abs(z.real) / radius, abs(z.imag) / radius, 1e-9)
        clipped = complex(z.real / scale, z.imag / scale)
        px = int(left + ((clipped.real + radius) / (2.0 * radius)) * (right - left))
        py = int(bottom - ((clipped.imag + radius) / (2.0 * radius)) * (bottom - top))
        return clamp_int(px, left, right), clamp_int(py, top, bottom)

    @staticmethod
    def _draw_arrow_marker(draw, pos: tuple[int, int], colour) -> None:
        px, py = pos
        draw.ellipse((px - 12, py - 12, px + 12, py + 12), outline=colour, width=3)
        draw.line((px - 7, py, px + 7, py), fill=colour, width=3)
        draw.line((px, py - 7, px, py + 7), fill=colour, width=3)

    def _draw_side_readout(self, draw, state: Scene3State, x0: int, y0: int, x1: int, y1: int,
                           values: Sequence[complex], escaped: bool, palette) -> None:
        draw.rounded_rectangle((x0, y0, x1, y1), radius=18, fill=(11, 15, 22), outline=(39, 52, 62), width=1)

        z = values[-1]
        status_text = "ESCAPED" if escaped else "inside so far"
        status_colour = palette["current"] if escaped else self.white

        self._text(draw, (x0 + 22, y0 + 18), "Escape test", self.font_medium, palette["accent"])
        self._text(draw, (x0 + 22, y0 + 58), f"radius = {state.escape_radius:.4f}", self.font_mono_small, self.white)
        self._text(draw, (x0 + 22, y0 + 86), f"status = {status_text}", self.font_mono_small, status_colour)

        self._text(draw, (x0 + 22, y0 + 134), "Current orbit", self.font_medium, palette["current"])
        self._text(draw, (x0 + 22, y0 + 176), f"n = {state.current_iter}", self.font_mono_small, self.white)
        self._text(draw, (x0 + 22, y0 + 206), f"|zₙ| = {abs(z):.4f}", self.font_mono_small, self.white)

        recent = values[-3:]
        recent_text = "  →  ".join(f"{abs(v):.2f}" if abs(v) < 1000 else f"{abs(v):.1e}" for v in recent)
        self._text(draw, (x0 + 22, y0 + 256), "recent |z|", self.font_medium, self.dim)
        self._text(draw, (x0 + 22, y0 + 302), recent_text, self.font_mono_small, self.white)

    def _draw_compact_controls(self, draw, state: Scene3State, accent) -> None:
        box = (62, 632, 1218, 694)
        self._panel(draw, box, (12, 16, 23), (45, 62, 70), width=1, radius=18)

        visible, escaped = visible_values(state)
        message = classify_orbit(visible, escaped, state.escape_radius)

        self._text(draw, (86, 642), message, self.font_normal, self.white)
        self._text(draw, (86, 670), state.status, self.font_small, self.dim)

        controls = "Joystick move c   B3 play/pause   Enc1 zoom   Enc2 checks   stick reset   B2 next   B1 back   B5 palette"
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
    renderer = Scene3Renderer(args.width, args.height, swap_rb=args.swap_rb, fade_s=args.fade_seconds)
    state = Scene3State(max_iter=args.iterations)
    state.intro_fade_start = time.monotonic()

    print()
    print(f"Escape-radius walkthrough is now running on HDMI. ({SCRIPT_VERSION})")
    print("Use keyboard over SSH as the controller emulator. Press Q to quit.")
    print("N continue | B back | Space reveal/play | WASD/arrows move c | [ ] zoom | - = checks | R reset")

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
    state = Scene3State()
    state.current_iter = 5
    values, escaped = visible_values(state)
    assert len(values) == 6
    assert not escaped
    assert state.escape_radius == 2.0

    before = state.c_r
    handle_interactive_event(state, Event(EventKind.JOY_RIGHT))
    assert state.c_r > before
    assert state.current_iter == 0
    assert not state.playing

    state.max_iter = 20
    values, _ = recurrence_values(state)
    assert values[0] == 0.0 + 0.0j
    assert len(values) > 1

    renderer = Scene3Renderer(1280, 720)
    state.phase = AppPhase.INTRO
    state.intro_fade_start = time.monotonic() - 1.0
    packed = renderer.draw(state, time.monotonic())
    assert packed.shape == (720, 1280)
    assert packed.dtype == np.uint32

    state.phase = AppPhase.INTERACTIVE
    packed = renderer.draw(state, time.monotonic())
    assert packed.shape == (720, 1280)
    assert packed.dtype == np.uint32

    assert resolve_bit_path(__file__) == __file__

    print("Self-test PASS")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="FractalScope escape-radius HDMI prototype")
    parser.add_argument("--bit", default=DEFAULT_BIT_PATH, help="Path to the custom FractalScope .bit file or its directory")
    parser.add_argument("--width", type=int, default=WIDTH, help="Framebuffer width")
    parser.add_argument("--height", type=int, default=HEIGHT, help="Framebuffer height")
    parser.add_argument("--iterations", type=int, default=24, help="Initial displayed iteration/check length")
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
