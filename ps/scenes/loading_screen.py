#!/usr/bin/env python3
"""
title screen / loading screen for FractalScope
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum, auto
from pathlib import Path
from typing import Optional

import numpy as np

WIDTH = 1280
HEIGHT = 720
LOADING_SCREEN_VERSION = "2026-06-15-v1-title-to-scene1"


class EventKind(Enum):
    START = auto()
    QUIT = auto()


@dataclass(frozen=True)
class Event:
    kind: EventKind
    value: object = None


@dataclass
class LoadingScreenState:
    dirty: bool = True
    quit_requested: bool = False
    transition_request: Optional[str] = None


class SceneLoadingScreen:
    def __init__(self, state: Optional[LoadingScreenState] = None) -> None:
        self.state = state or LoadingScreenState()

    def handle_event(self, event: Event) -> None:
        if event.kind is EventKind.QUIT:
            self.state.quit_requested = True
            return
        if event.kind is EventKind.START:
            self.state.transition_request = "scene1"
            self.state.dirty = True


class LoadingScreenRenderer:
    def __init__(self, width: int = WIDTH, height: int = HEIGHT) -> None:
        self.width = int(width)
        self.height = int(height)
        self.logo_path = self._find_logo_path()

    def draw_packed(self, state: LoadingScreenState, swap_rb: bool = False) -> np.ndarray:
        return self._pack_rgb(self.draw_rgb(state), swap_rb=swap_rb)

    def draw_rgb(self, state: LoadingScreenState) -> np.ndarray:
        from PIL import Image, ImageDraw

        img = Image.new("RGB", (self.width, self.height), (0, 0, 0))
        draw = ImageDraw.Draw(img)

        if not self._draw_logo_image(img):
            self._draw_text_logo(draw)

        prompt_font = self._font(30)
        prompt = "press any button to start"
        bbox = draw.textbbox((0, 0), prompt, font=prompt_font)
        draw.text(
            ((self.width - (bbox[2] - bbox[0])) // 2, int(self.height * 0.70)),
            prompt,
            font=prompt_font,
            fill=(235, 239, 245),
        )

        return np.asarray(img, dtype=np.uint8)

    def _draw_logo_image(self, img) -> bool:
        if self.logo_path is None:
            return False
        try:
            from PIL import Image

            logo = Image.open(self.logo_path).convert("RGBA")
            max_w = int(self.width * 0.42)
            max_h = int(self.height * 0.32)
            scale = min(max_w / max(1, logo.width), max_h / max(1, logo.height))
            new_size = (max(1, int(logo.width * scale)), max(1, int(logo.height * scale)))
            logo = logo.resize(new_size, Image.LANCZOS)
            x = (self.width - logo.width) // 2
            y = int(self.height * 0.33) - logo.height // 2
            img.paste(logo, (x, y), logo)
            return True
        except Exception:
            return False

    def _draw_text_logo(self, draw) -> None:
        title_font = self._font(82, bold=True)
        text = "FractalScope"
        bbox = draw.textbbox((0, 0), text, font=title_font)
        draw.text(
            ((self.width - (bbox[2] - bbox[0])) // 2, int(self.height * 0.30)),
            text,
            font=title_font,
            fill=(245, 248, 252),
        )

    @staticmethod
    def _font(size: int, bold: bool = False):
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
    def _find_logo_path() -> Optional[Path]:
        here = Path(__file__).resolve()
        candidates = (
            here.parent.parent / "assets" / "logo.png",
            here.parent / "assets" / "logo.png",
            here.parent.parent / "logo.png",
            here.parent / "logo.png",
        )
        for path in candidates:
            if path.exists():
                return path
        return None

    @staticmethod
    def _pack_rgb(rgb: np.ndarray, *, swap_rb: bool = False) -> np.ndarray:
        if rgb.dtype != np.uint8:
            rgb = rgb.astype(np.uint8)
        if swap_rb:
            r = rgb[..., 2].astype(np.uint32)
            g = rgb[..., 1].astype(np.uint32)
            b = rgb[..., 0].astype(np.uint32)
        else:
            r = rgb[..., 0].astype(np.uint32)
            g = rgb[..., 1].astype(np.uint32)
            b = rgb[..., 2].astype(np.uint32)
        return (r << 16) | (g << 8) | b
