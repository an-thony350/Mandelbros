#!/usr/bin/env python3
"""
global fractal menu
"""

from __future__ import annotations

import argparse
import os
import select
import sys
import termios
import time
import tty
from dataclasses import dataclass
from enum import Enum, auto
from pathlib import Path
from typing import Iterable, Optional

import numpy as np


DEFAULT_BIT_PATH = "/home/xilinx/jupyter_notebooks/fractalscope"

WIDTH = 1280
HEIGHT = 720
BPP = 4
STRIDE = WIDTH * BPP
FRAME_PIXELS = WIDTH * HEIGHT

MENU_VERSION = "2026-06-15-v4-menu-edge-nav"

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


class EventKind(Enum):
    NEXT = auto()
    BACK = auto()
    PAN = auto()
    RESET = auto()
    CYCLE_PALETTE = auto()
    TOGGLE_FINE = auto()
    MENU = auto()
    QUIT = auto()


@dataclass(frozen=True)
class Event:
    kind: EventKind
    value: object = None


class MenuPhase(Enum):
    GRID = auto()
    HELP = auto()


@dataclass(frozen=True)
class MenuItem:
    title: str
    key: str
    description: str
    detail: str
    thumbnail: str


MENU_ITEMS: tuple[MenuItem, ...] = (
    MenuItem(
        title="Standard Mandelbrot",
        key="standard_mandelbrot",
        description="Explore the classic set z → z² + c.",
        detail="Best starting point for free exploration, zooming, panning, and colour palette demos.",
        thumbnail="mandelbrot",
    ),
    MenuItem(
        title="Julia",
        key="julia",
        description="Generate Julia sets from a chosen value of c.",
        detail="Launches the Julia scene. Button 5 / F toggles between map-linked view and full-image view.",
        thumbnail="julia",
    ),
    MenuItem(
        title="Burning Ship",
        key="burning_ship",
        description="Use absolute values before squaring.",
        detail="A Mandelbrot-like variant with sharp ship-shaped structures and strong symmetry.",
        thumbnail="burning_ship",
    ),
    MenuItem(
        title="Tricorn",
        key="tricorn",
        description="Conjugate z before applying the recurrence.",
        detail="Shows how a tiny change to the recurrence creates a completely different global shape.",
        thumbnail="tricorn",
    ),
    MenuItem(
        title="CPU vs Hardware",
        key="cpu_vs_hardware",
        description="Compare software and PL rendering paths.",
        detail="Useful for explaining why the FPGA pipeline matters and for showing timing/throughput differences.",
        thumbnail="comparison",
    ),
    MenuItem(
        title="Help",
        key="help",
        description="View controls and scene notes.",
        detail="A compact reminder of WASD, buttons, encoders, reset, palette, and menu controls.",
        thumbnail="help",
    ),
)


@dataclass
class MenuState:
    phase: MenuPhase = MenuPhase.GRID
    selected_index: int = 0
    columns: int = 3
    julia_map_view: bool = True
    palette_index: int = 0
    dirty: bool = True
    quit_requested: bool = False
    transition_request: Optional[str] = None
    last_message: str = "Menu ready"

    @property
    def selected_item(self) -> MenuItem:
        return MENU_ITEMS[self.selected_index]

    @property
    def julia_mode_label(self) -> str:
        return "Mandelbrot map + Julia image" if self.julia_map_view else "Full Julia image"

    @property
    def julia_transition_key(self) -> str:
        return "julia_link_map" if self.julia_map_view else "julia_full_image"


class SceneMenu:
    def __init__(self, state: Optional[MenuState] = None) -> None:
        self.state = state or MenuState()

    def handle_event(self, event: Event) -> None:
        s = self.state

        if event.kind is EventKind.QUIT:
            s.quit_requested = True
            return

        if s.phase is MenuPhase.HELP:
            self._handle_help_event(event)
            return

        self._handle_grid_event(event)

    def _handle_help_event(self, event: Event) -> None:
        s = self.state
        if event.kind in (EventKind.BACK, EventKind.MENU, EventKind.NEXT):
            s.phase = MenuPhase.GRID
            s.dirty = True
            s.last_message = "Returned to menu"
            return
        if event.kind is EventKind.RESET:
            s.phase = MenuPhase.GRID
            s.selected_index = 0
            s.dirty = True
            s.last_message = "Menu reset"

    def _handle_grid_event(self, event: Event) -> None:
        s = self.state

        if event.kind is EventKind.BACK:
            s.transition_request = "back"
            s.last_message = "Back scene requested"
            return

        if event.kind is EventKind.MENU:
            s.transition_request = "close_menu"
            s.last_message = "Close menu requested"
            return

        if event.kind is EventKind.RESET:
            s.selected_index = 0
            s.dirty = True
            s.last_message = "Selection reset to Standard Mandelbrot"
            return

        if event.kind is EventKind.CYCLE_PALETTE:
            s.palette_index = (s.palette_index + 1) % 4
            s.dirty = True
            s.last_message = f"Menu accent palette {s.palette_index + 1}"
            return

        if event.kind is EventKind.TOGGLE_FINE:
            if s.selected_item.key == "julia":
                s.julia_map_view = not s.julia_map_view
                s.dirty = True
                s.last_message = f"Julia launch mode: {s.julia_mode_label}"
            else:
                s.last_message = "Button 5 toggles the Julia launch mode when Julia is selected"
            return

        if event.kind is EventKind.PAN:
            dx, dy = event.value or (0, 0)
            self._move_selection(float(dx), float(dy))
            return

        if event.kind is EventKind.NEXT:
            item = s.selected_item
            if item.key == "help":
                s.phase = MenuPhase.HELP
                s.dirty = True
                s.last_message = "Help section opened"
            elif item.key == "julia":
                s.transition_request = s.julia_transition_key
                s.last_message = f"Selected Julia: {s.julia_mode_label}"
            else:
                s.transition_request = item.key
                s.last_message = f"Selected {item.title}"

    def _move_selection(self, dx: float, dy: float) -> None:
        s = self.state
        old = s.selected_index
        col = old % s.columns
        row = old // s.columns
        rows = (len(MENU_ITEMS) + s.columns - 1) // s.columns

        if abs(dx) >= abs(dy) and abs(dx) > 0.0:
            if dx > 0 and col < s.columns - 1 and old + 1 < len(MENU_ITEMS):
                s.selected_index += 1
            elif dx < 0 and col > 0:
                s.selected_index -= 1
        elif abs(dy) > 0.0:
            # W / joystick-up produces dy > 0 in the existing scene mapping.
            if dy > 0 and row > 0:
                s.selected_index -= s.columns
            elif dy < 0 and row < rows - 1 and old + s.columns < len(MENU_ITEMS):
                s.selected_index += s.columns

        if s.selected_index != old:
            s.dirty = True
            s.last_message = f"Ready to select: {s.selected_item.title}"


class MenuRenderer:
    def __init__(self) -> None:
        self.bg = (7, 9, 13)
        self.panel = (13, 18, 28)
        self.panel_selected = (18, 29, 42)
        self.white = (242, 244, 247)
        self.dim = (160, 170, 184)
        self.accent_colours = (
            (80, 230, 230),
            (255, 206, 110),
            (255, 130, 185),
            (150, 225, 150),
        )
        self.font_title = self._load_font(46, bold=True)
        self.font_subtitle = self._load_font(20)
        self.font_card_title = self._load_font(22, bold=True)
        self.font_card = self._load_font(15)
        self.font_small = self._load_font(13)
        self.font_tiny = self._load_font(11)
        self.font_help_title = self._load_font(40, bold=True)
        self.thumbnail_cache: dict[str, np.ndarray] = {}

    @staticmethod
    def _load_font(size: int, bold: bool = False):
        from PIL import ImageFont

        candidates = (
            "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf" if bold else "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
            "/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf" if bold else "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
        )
        for path in candidates:
            try:
                return ImageFont.truetype(path, size)
            except Exception:
                continue
        return ImageFont.load_default()

    @staticmethod
    def _pack_rgb(rgb: np.ndarray, swap_rb: bool = False) -> np.ndarray:
        if swap_rb:
            r = rgb[..., 2].astype(np.uint32)
            g = rgb[..., 1].astype(np.uint32)
            b = rgb[..., 0].astype(np.uint32)
        else:
            r = rgb[..., 0].astype(np.uint32)
            g = rgb[..., 1].astype(np.uint32)
            b = rgb[..., 2].astype(np.uint32)
        return (r << 16) | (g << 8) | b

    def draw_packed(self, state: MenuState, swap_rb: bool = False) -> np.ndarray:
        return self._pack_rgb(self.draw_rgb(state), swap_rb=swap_rb)

    def draw_rgb(self, state: MenuState) -> np.ndarray:
        from PIL import Image, ImageDraw

        img = Image.new("RGB", (WIDTH, HEIGHT), self.bg)
        draw = ImageDraw.Draw(img)
        accent = self.accent_colours[state.palette_index % len(self.accent_colours)]

        for x in range(-120, WIDTH + 120, 135):
            draw.line((x, 0, x + 240, HEIGHT), fill=(9, 14, 22), width=1)
        draw.rounded_rectangle((38, 30, WIDTH - 38, HEIGHT - 32), radius=28, outline=(18, 28, 39), width=2)

        if state.phase is MenuPhase.HELP:
            self._draw_help(draw, accent)
        else:
            self._draw_grid(img, draw, state, accent)

        return np.asarray(img, dtype=np.uint8)

    def _draw_grid(self, img, draw, state: MenuState, accent) -> None:
        self._text_center(draw, 43, "Guided walkthrough complete", self.font_title, self.white)
        self._text_center(draw, 99, "Use WASD to choose a mode. Mandelbrot, Burning Ship, and Tricorn now launch free roam.", self.font_subtitle, self.dim)

        card_w = 356
        card_h = 158
        gap_x = 34
        gap_y = 24
        start_x = (WIDTH - (3 * card_w + 2 * gap_x)) // 2
        start_y = 148

        for idx, item in enumerate(MENU_ITEMS):
            row = idx // state.columns
            col = idx % state.columns
            x0 = start_x + col * (card_w + gap_x)
            y0 = start_y + row * (card_h + gap_y)
            selected = idx == state.selected_index
            self._draw_card(img, draw, x0, y0, card_w, card_h, item, state, selected, accent)

        selected = state.selected_item
        detail_y = 534
        draw.rounded_rectangle((78, detail_y, WIDTH - 78, detail_y + 84), radius=20, fill=(10, 16, 25), outline=(31, 47, 62), width=1)
        draw.text((104, detail_y + 15), "Selected mode:", font=self.font_small, fill=self.dim)
        draw.text((104, detail_y + 36), selected.title, font=self.font_card_title, fill=accent)
        detail = selected.detail
        if selected.key == "julia":
            detail = f"{detail} Current launch mode: {state.julia_mode_label}."
        for line_no, line in enumerate(self._wrap_text(draw, detail, self.font_card, 780)[:2]):
            draw.text((360, detail_y + 18 + 24 * line_no), line, font=self.font_card, fill=self.white)

        controls = "WASD/arrows move   N/Enter select   B/M stay here   P accent   F Julia toggle   Q quit"
        self._text_center(draw, 655, controls, self.font_small, (190, 202, 214))

    def _draw_card(self, img, draw, x0: int, y0: int, w: int, h: int, item: MenuItem, state: MenuState, selected: bool, accent) -> None:
        fill = self.panel_selected if selected else self.panel
        outline = accent if selected else (33, 47, 62)
        border_w = 4 if selected else 1
        shadow = (0, 0, 0)
        if selected:
            draw.rounded_rectangle((x0 - 7, y0 - 7, x0 + w + 7, y0 + h + 7), radius=24, outline=(25, 55, 65), width=2)
        draw.rounded_rectangle((x0 + 4, y0 + 5, x0 + w + 4, y0 + h + 5), radius=20, fill=shadow)
        draw.rounded_rectangle((x0, y0, x0 + w, y0 + h), radius=20, fill=fill, outline=outline, width=border_w)

        thumb = self._thumbnail(item.thumbnail)
        thumb_x, thumb_y = x0 + 18, y0 + 18
        draw.rounded_rectangle((thumb_x - 2, thumb_y - 2, thumb_x + 116, thumb_y + 69), radius=10, outline=(45, 65, 78), width=1)
        from PIL import Image
        card_img = Image.fromarray(thumb, mode="RGB")
        img.paste(card_img, (thumb_x, thumb_y))

        title_x = x0 + 148
        title_lines = self._wrap_text(draw, item.title, self.font_card_title, w - 170)[:2]
        for line_no, line in enumerate(title_lines):
            draw.text((title_x, y0 + 17 + 25 * line_no), line, font=self.font_card_title, fill=self.white)

        desc = item.description
        if item.key == "julia":
            desc = f"{desc} Mode: {state.julia_mode_label}."
        desc_y = y0 + 55 + max(0, len(title_lines) - 1) * 21
        for line_no, line in enumerate(self._wrap_text(draw, desc, self.font_card, w - 166)[:3]):
            draw.text((title_x, desc_y + 21 * line_no), line, font=self.font_card, fill=(198, 213, 225))

        if selected:
            tag = "PRESS N"
            bbox = draw.textbbox((0, 0), tag, font=self.font_tiny)
            tw = bbox[2] - bbox[0]
            draw.rounded_rectangle((x0 + w - tw - 35, y0 + h - 31, x0 + w - 16, y0 + h - 12), radius=8, fill=accent)
            draw.text((x0 + w - tw - 25, y0 + h - 29), tag, font=self.font_tiny, fill=(6, 10, 15))

    def _draw_help(self, draw, accent) -> None:
        self._text_center(draw, 58, "Help", self.font_help_title, self.white)
        self._text_center(draw, 111, "These are the controls for the menu and the exploration scenes.", self.font_subtitle, self.dim)

        x0, y0, w, h = 168, 160, 944, 398
        draw.rounded_rectangle((x0, y0, x0 + w, y0 + h), radius=26, fill=(10, 16, 25), outline=accent, width=2)

        lines = (
            ("W / A / S / D", "Move through the menu. In fractal scenes, use the joystick/WASD for navigation."),
            ("N / Enter / Button 2", "Select the highlighted item, or move to the next walkthrough section."),
            ("B / Button 1", "Go back to the previous scene or return from this help screen."),
            ("Encoders", "Zoom and adjust max iterations in exploration scenes."),
            ("R / Joystick click", "Reset the current view or cursor."),
            ("P / Button 4", "Cycle colour palettes or menu accent colour."),
            ("F / Button 5", "For Julia, switch between Mandelbrot-linked view and full-image view."),
            ("M / Button 6", "Open or close the global menu."),
        )
        y = y0 + 34
        for control, explanation in lines:
            draw.text((x0 + 38, y), control, font=self.font_card_title, fill=accent)
            for line_no, wrapped in enumerate(self._wrap_text(draw, explanation, self.font_card, 620)[:2]):
                draw.text((x0 + 320, y + 4 + 21 * line_no), wrapped, font=self.font_card, fill=self.white)
            y += 42

        self._text_center(draw, 615, "B, N, or M returns to the menu", self.font_subtitle, accent)
        self._text_center(draw, 655, "Q is terminal-only quit for this standalone script", self.font_small, self.dim)

    def _thumbnail(self, name: str) -> np.ndarray:
        if name not in self.thumbnail_cache:
            self.thumbnail_cache[name] = make_thumbnail(name, 116, 67)
        return self.thumbnail_cache[name]

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


def make_thumbnail(name: str, width: int, height: int) -> np.ndarray:
    if name in {"mandelbrot", "julia", "burning_ship", "tricorn"}:
        return make_fractal_thumbnail(name, width, height)
    if name == "comparison":
        return make_comparison_thumbnail(width, height)
    return make_help_thumbnail(width, height)


def make_fractal_thumbnail(name: str, width: int, height: int) -> np.ndarray:
    if name == "julia":
        real = np.linspace(-1.55, 1.55, width, dtype=np.float64)
        imag = np.linspace(0.95, -0.95, height, dtype=np.float64)
        z = real[None, :] + 1j * imag[:, None]
        c = np.full((height, width), -0.8 + 0.156j, dtype=np.complex128)
    else:
        real = np.linspace(-2.15, 1.05, width, dtype=np.float64)
        imag = np.linspace(1.1, -1.1, height, dtype=np.float64)
        c = real[None, :] + 1j * imag[:, None]
        z = np.zeros_like(c)

    counts = np.zeros((height, width), dtype=np.uint16)
    alive = np.ones((height, width), dtype=bool)
    max_iter = 48

    for i in range(max_iter):
        if name == "burning_ship":
            z_step = np.abs(z.real) + 1j * np.abs(z.imag)
            z[alive] = z_step[alive] * z_step[alive] + c[alive]
        elif name == "tricorn":
            z_step = np.conjugate(z)
            z[alive] = z_step[alive] * z_step[alive] + c[alive]
        else:
            z[alive] = z[alive] * z[alive] + c[alive]
        escaped = alive & (np.abs(z) > 2.0)
        counts[escaped] = i
        alive &= ~escaped

    counts[alive] = max_iter
    t = counts.astype(np.float32) / float(max_iter)
    outside = counts < max_iter
    rgb = np.zeros((height, width, 3), dtype=np.uint8)
    rgb[..., 0] = np.where(outside, (32 + 170 * np.sqrt(t)).astype(np.uint8), 3)
    rgb[..., 1] = np.where(outside, (60 + 130 * t).astype(np.uint8), 8)
    rgb[..., 2] = np.where(outside, (100 + 125 * (1.0 - t)).astype(np.uint8), 18)
    return rgb


def make_comparison_thumbnail(width: int, height: int) -> np.ndarray:
    rgb = np.zeros((height, width, 3), dtype=np.uint8)
    rgb[:] = (10, 16, 25)
    for x in range(width):
        rgb[:, x, 2] = 50 + int(60 * x / max(1, width - 1))
    cpu_h = int(height * 0.36)
    hw_h = int(height * 0.78)
    rgb[height - cpu_h : height - 8, 18:44] = (210, 120, 95)
    rgb[height - hw_h : height - 8, 72:98] = (80, 230, 230)
    rgb[height - 8 : height - 6, 10:106] = (190, 202, 214)
    return rgb


def make_help_thumbnail(width: int, height: int) -> np.ndarray:
    rgb = np.zeros((height, width, 3), dtype=np.uint8)
    rgb[:] = (10, 16, 25)
    cy, cx = height // 2, width // 2
    yy, xx = np.ogrid[:height, :width]
    mask = (xx - cx) ** 2 + (yy - cy) ** 2 <= min(width, height) ** 2 // 7
    rgb[mask] = (80, 230, 230)
    rgb[cy - 17 : cy - 10, cx - 4 : cx + 5] = (8, 12, 18)
    rgb[cy - 7 : cy + 10, cx - 4 : cx + 5] = (8, 12, 18)
    rgb[cy + 16 : cy + 22, cx - 4 : cx + 5] = (8, 12, 18)
    return rgb


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
            "r": Event(EventKind.RESET),
            "p": Event(EventKind.CYCLE_PALETTE),
            "f": Event(EventKind.TOGGLE_FINE),
            "5": Event(EventKind.TOGGLE_FINE),
            "m": Event(EventKind.MENU),
            " ": Event(EventKind.NEXT),
        }
        return [mapping[key]] if key in mapping else []


class SerialControllerInput:
    def __init__(self, port: str, baudrate: int = 115200) -> None:
        self.port = port
        self.baudrate = baudrate
        self.serial = None
        self.prev_buttons = 0
        self.last_pan_direction: Optional[tuple[int, int]] = None

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
            2: Event(EventKind.NEXT),
            3: Event(EventKind.CYCLE_PALETTE),
            4: Event(EventKind.TOGGLE_FINE),
            5: Event(EventKind.MENU),
        }
        for bit, event in button_map.items():
            if rising & (1 << bit):
                events.append(event)

        pan = self._joystick_to_menu_step(joy_x, joy_y)
        if pan is None:
            self.last_pan_direction = None
        elif pan != self.last_pan_direction:
            events.append(Event(EventKind.PAN, pan))
            self.last_pan_direction = pan

        return events

    @staticmethod
    def _joystick_to_menu_step(joy_x: int, joy_y: int) -> Optional[tuple[int, int]]:
        deadzone = 25
        dx = 0
        dy = 0
        if joy_x > deadzone:
            dx = 1
        elif joy_x < -deadzone:
            dx = -1
        if joy_y < -deadzone:
            dy = 1
        elif joy_y > deadzone:
            dy = -1

        if dx == 0 and dy == 0:
            return None
        if abs(joy_x) >= abs(joy_y):
            return dx, 0
        return 0, dy


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


class VdmaFramebufferDisplay:
    def __init__(self, args: argparse.Namespace) -> None:
        from pynq import MMIO, Overlay, allocate

        self.args = args
        self.bit_path = resolve_bit_path(args.bit)
        print(f"Scene menu HDMI version: {MENU_VERSION}")
        print("Configured for:")
        print(f"  bitstream:  {self.bit_path}")
        print(f"  resolution: {WIDTH}x{HEIGHT}")
        print(f"  bpp:        {BPP}")
        print(f"  stride:     {STRIDE}")
        print(f"  frame size: {FRAME_PIXELS * BPP} bytes")

        self.overlay = Overlay(str(self.bit_path), download=not args.no_download)
        if args.no_download:
            print("Overlay metadata loaded without downloading bitstream")
        else:
            print("Loaded overlay:", self.bit_path)

        vdma_ip = find_ip_by_name_contains(self.overlay.ip_dict, "axi_vdma")
        print("Using VDMA IP:", vdma_ip, hex(self.overlay.ip_dict[vdma_ip]["phys_addr"]))
        self.vdma = MMIO(self.overlay.ip_dict[vdma_ip]["phys_addr"], self.overlay.ip_dict[vdma_ip]["addr_range"])
        self.fb = allocate(shape=(HEIGHT, WIDTH), dtype=np.uint32)
        print("Framebuffer:")
        print("  physical address:", hex(self.fb.physical_address))
        print("  nbytes:          ", self.fb.nbytes)
        if self.fb.nbytes != FRAME_PIXELS * BPP:
            raise RuntimeError(f"Framebuffer has unexpected size {self.fb.nbytes}")
        self.fb[:] = 0x00000000
        self.fb.flush()
        self.start_mm2s()

    def close(self) -> None:
        try:
            self.vdma.write(MM2S_DMACR, 0x0)
        except Exception:
            pass

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
        print(f"MM2S_HSIZE       = {self.vdma.read(MM2S_HSIZE)}")
        print(f"MM2S_STRIDE      = {self.vdma.read(MM2S_FRMDLY_STRIDE) & 0xFFFF}")
        print(f"MM2S_VSIZE       = {self.vdma.read(MM2S_VSIZE)}")

    def start_mm2s(self) -> None:
        print("\nResetting MM2S...")
        ok = self.reset_mm2s()
        print("MM2S reset ok:", ok)
        self.vdma.write(MM2S_DMASR, 0x0000FFFF)
        self.vdma.write(MM2S_START_ADDR1, self.fb.physical_address)
        self.vdma.write(MM2S_START_ADDR2, self.fb.physical_address)
        self.vdma.write(MM2S_START_ADDR3, self.fb.physical_address)
        self.vdma.write(MM2S_DMACR, VDMA_DMACR_RUNSTOP)
        self.vdma.write(PARK_PTR_REG, 0)
        self.vdma.write(MM2S_FRMDLY_STRIDE, STRIDE)
        self.vdma.write(MM2S_HSIZE, STRIDE)
        self.vdma.write(MM2S_VSIZE, HEIGHT)
        time.sleep(0.1)
        print("\nAfter MM2S start:")
        self.show_mm2s()

    def show_packed(self, packed_rgb: np.ndarray) -> None:
        if packed_rgb.shape != (HEIGHT, WIDTH):
            raise ValueError(f"Expected frame shape {(HEIGHT, WIDTH)}, got {packed_rgb.shape}")
        self.fb[:] = packed_rgb
        self.fb.flush()


def print_controls() -> None:
    print("\nFractalScope menu controls")
    print("  W/A/S/D or arrows  : move highlighted selection")
    print("  N / Enter / Space  : select highlighted option")
    print("  B                  : back scene request")
    print("  M                  : close menu request")
    print("  F or 5             : toggle Julia launch mode when Julia is highlighted")
    print("  P                  : cycle menu accent colour")
    print("  R                  : reset selection")
    print("  Q                  : terminal-only quit")


def self_test() -> None:
    scene = SceneMenu()
    assert scene.state.selected_item.key == "standard_mandelbrot"
    scene.handle_event(Event(EventKind.PAN, (1, 0)))
    assert scene.state.selected_item.key == "julia"
    scene.handle_event(Event(EventKind.TOGGLE_FINE))
    assert scene.state.julia_transition_key == "julia_full_image"
    scene.handle_event(Event(EventKind.NEXT))
    assert scene.state.transition_request == "julia_full_image"
    scene.state.transition_request = None
    scene.handle_event(Event(EventKind.PAN, (1, 0)))
    scene.handle_event(Event(EventKind.PAN, (1, 0)))
    scene.handle_event(Event(EventKind.PAN, (1, 0)))
    assert scene.state.selected_index <= len(MENU_ITEMS) - 1
    scene.handle_event(Event(EventKind.RESET))
    assert scene.state.selected_index == 0

    renderer = MenuRenderer()
    frame = renderer.draw_packed(scene.state)
    assert frame.shape == (HEIGHT, WIDTH)
    assert frame.dtype == np.uint32
    scene.state.selected_index = 5
    scene.handle_event(Event(EventKind.NEXT))
    assert scene.state.phase is MenuPhase.HELP
    help_frame = renderer.draw_packed(scene.state)
    assert help_frame.shape == (HEIGHT, WIDTH)
    print("Self-test PASS")


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="FractalScope HDMI menu scene")
    parser.add_argument("--bit", default=DEFAULT_BIT_PATH, help=".bit file or directory containing the latest .bit")
    parser.add_argument("--no-download", action="store_true", help="load overlay metadata but do not download the bitstream")
    parser.add_argument("--serial", default="auto", help="physical controller serial port, 'auto', or 'none'")
    parser.add_argument("--baudrate", type=int, default=115200)
    parser.add_argument("--swap-rb", action="store_true", help="swap red/blue packing if the display path needs BGR order")
    parser.add_argument("--self-test", action="store_true")
    return parser


def main(argv: Optional[Iterable[str]] = None) -> int:
    args = build_arg_parser().parse_args(argv)
    if args.self_test:
        self_test()
        return 0

    scene = SceneMenu()
    renderer = MenuRenderer()
    keyboard = KeyboardInput()
    serial_input: Optional[SerialControllerInput] = None
    serial_port = pick_serial_port(args.serial)
    if serial_port:
        serial_input = SerialControllerInput(serial_port, args.baudrate)
        if not serial_input.open():
            serial_input = None

    display = None
    try:
        display = VdmaFramebufferDisplay(args)
        print_controls()
        display.show_packed(renderer.draw_packed(scene.state, swap_rb=args.swap_rb))
        scene.state.dirty = False

        print("\nReady. Use WASD to move the highlighted menu card.")
        with RawTerminal():
            while not scene.state.quit_requested:
                events = keyboard.poll()
                if serial_input is not None:
                    events.extend(serial_input.poll())

                if events:
                    for event in events:
                        scene.handle_event(event)
                    print("  " + scene.state.last_message)

                if scene.state.transition_request is not None:
                    print(f"Standalone menu noted transition request: {scene.state.transition_request}")
                    scene.state.transition_request = None
                    scene.state.dirty = True

                if scene.state.dirty:
                    display.show_packed(renderer.draw_packed(scene.state, swap_rb=args.swap_rb))
                    scene.state.dirty = False

                time.sleep(0.02)

    except KeyboardInterrupt:
        print("\nInterrupted.")
    finally:
        if display is not None:
            display.close()
        if serial_input is not None:
            serial_input.close()

    print("Menu scene closed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
