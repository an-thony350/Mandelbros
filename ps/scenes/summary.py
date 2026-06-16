#!/usr/bin/env python3
"""
This PS-drawn scene gives the demo a clean ending before the menu
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum, auto
from typing import Optional

import numpy as np

WIDTH = 1280
HEIGHT = 720
BPP = 4
SUMMARY_VERSION = "2026-06-11-v1-guided-summary"


class EventKind(Enum):
    NEXT = auto()
    BACK = auto()
    PAN = auto()
    RESET = auto()
    CYCLE_PALETTE = auto()
    MENU = auto()
    QUIT = auto()


@dataclass(frozen=True)
class Event:
    kind: EventKind
    value: object = None


@dataclass
class SummaryState:
    palette_index: int = 0
    dirty: bool = True
    quit_requested: bool = False
    transition_request: Optional[str] = None
    last_message: str = "Guided walkthrough complete"


class SceneSummary:
    def __init__(self, state: Optional[SummaryState] = None) -> None:
        self.state = state or SummaryState()

    def handle_event(self, event: Event) -> None:
        s = self.state

        if event.kind is EventKind.QUIT:
            s.quit_requested = True
            return

        if event.kind is EventKind.NEXT:
            s.transition_request = "next"
            s.last_message = "Opening exploration menu"
            return

        if event.kind is EventKind.BACK:
            s.transition_request = "back"
            s.last_message = "Returning to Julia link"
            return

        if event.kind is EventKind.MENU:
            s.transition_request = "menu"
            s.last_message = "Opening exploration menu"
            return

        if event.kind is EventKind.RESET:
            s.last_message = "Summary reset"
            s.dirty = True
            return

        if event.kind is EventKind.CYCLE_PALETTE:
            s.palette_index = (s.palette_index + 1) % 4
            s.last_message = f"Summary accent palette {s.palette_index + 1}"
            s.dirty = True
            return

        if event.kind is EventKind.PAN:
            s.last_message = "Press N to continue to the menu, or B to revisit Julia."
            s.dirty = True


class SummaryRenderer:
    def __init__(self) -> None:
        self.bg = (7, 9, 13)
        self.panel = (13, 18, 28)
        self.white = (242, 244, 247)
        self.dim = (166, 174, 184)
        self.accent_colours = (
            (80, 230, 230),
            (255, 206, 110),
            (255, 130, 185),
            (150, 225, 150),
        )
        self.font_title = self._load_font(54, bold=True)
        self.font_subtitle = self._load_font(24)
        self.font_card_title = self._load_font(27, bold=True)
        self.font_body = self._load_font(24)
        self.font_small = self._load_font(16)
        self.font_mono = self._load_font(21, mono=True)

    @staticmethod
    def _load_font(size: int, bold: bool = False, mono: bool = False):
        from PIL import ImageFont

        if mono:
            candidates = (
                "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
                "/usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf",
            )
        else:
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

    def draw_packed(self, state: SummaryState, swap_rb: bool = False) -> np.ndarray:
        return self._pack_rgb(self.draw_rgb(state), swap_rb=swap_rb)

    def draw_rgb(self, state: SummaryState) -> np.ndarray:
        from PIL import Image, ImageDraw

        img = Image.new("RGB", (WIDTH, HEIGHT), self.bg)
        draw = ImageDraw.Draw(img)
        accent = self.accent_colours[state.palette_index % len(self.accent_colours)]

        for x in range(80, WIDTH, 160):
            draw.line((x, 0, x - 140, HEIGHT), fill=(10, 14, 21), width=1)
        draw.rounded_rectangle((42, 32, WIDTH - 42, HEIGHT - 34), radius=30, outline=(18, 28, 39), width=2)

        self._text_center(draw, 70, "Guided walkthrough complete", self.font_title, accent)

        card = (278, 178, WIDTH - 278, 560)
        draw.rounded_rectangle(card, radius=28, fill=self.panel, outline=(36, 58, 72), width=2)

        self._section(draw, 445, 240, "Concepts covered", (
            "recurrence",
            "complex orbits",
            "escape radius",
            "escape-time colouring",
        ), accent)
        return np.asarray(img, dtype=np.uint8)

    def _section(self, draw, x: int, y: int, title: str, items: tuple[str, ...], accent) -> None:
        draw.text((x, y), title, font=self.font_card_title, fill=accent)
        y += 52
        for item in items:
            draw.ellipse((x, y + 8, x + 12, y + 20), fill=accent)
            draw.text((x + 30, y), item, font=self.font_body, fill=self.white)
            y += 43

    @staticmethod
    def _text(draw, xy, text: str, font, fill) -> None:
        x, y = xy
        draw.text((x + 1, y + 1), text, font=font, fill=(0, 0, 0))
        draw.text((x, y), text, font=font, fill=fill)

    def _text_center(self, draw, y: int, text: str, font, fill) -> None:
        bbox = draw.textbbox((0, 0), text, font=font)
        w = bbox[2] - bbox[0]
        self._text(draw, ((WIDTH - w) // 2, y), text, font, fill)
