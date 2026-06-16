#!/usr/bin/env python3
"""
free-roam PL fractal modes
    Mandelbrot    MODE_MANDEL  = 0
    Julia         MODE_JULIA   = 1
    Burning Ship  MODE_BURNING = 2
    Tricorn       MODE_TRICORN = 3
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from enum import Enum, auto
from typing import Optional

import numpy as np

WIDTH = 1280
HEIGHT = 720
BPP = 4
PANEL_WIDTH = 352
PANEL_HEIGHT = 160

MODE_MANDEL = 0
MODE_JULIA = 1
MODE_BURNING = 2
MODE_TRICORN = 3
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

FREE_ROAM_VERSION = "2026-06-15-v5-controller-hud"


class EventKind(Enum):
    NEXT = auto()
    BACK = auto()
    ACTION = auto()
    MENU = auto()
    RESET = auto()
    PALETTE = auto()
    FUNCTION = auto()
    PAN = auto()
    ZOOM = auto()
    ITER = auto()
    QUIT = auto()


@dataclass(frozen=True)
class Event:
    kind: EventKind
    value: object = None


# julia interface
JULIA_C_R_MIN = -2.40
JULIA_C_R_MAX = 1.40
JULIA_C_I_MIN = -1.60
JULIA_C_I_MAX = 1.60
JULIA_C_STEP_MIN = 0.001
JULIA_C_STEP_MAX = 0.120
MANDEL_REF_W = 420
MANDEL_REF_H = 140
MANDEL_REF_MAX_ITER = 144
MANDEL_DISPLAY_W = 280
MANDEL_DISPLAY_H = 82
_MANDEL_REF_CACHE: Optional[np.ndarray] = None


@dataclass(frozen=True)
class FractalPreset:
    key: str
    title: str
    mode: int
    formula: str
    description: str
    center_r: float
    center_i: float
    x_width: float
    max_iter: int
    julia_c_r: float = -0.800
    julia_c_i: float = 0.156
    julia_c_step: float = 0.015


PRESETS: dict[str, FractalPreset] = {
    "mandelbrot": FractalPreset(
        key="mandelbrot",
        title="Standard Mandelbrot",
        mode=MODE_MANDEL,
        formula="z → z² + c",
        description="Classic escape-time set. Each pixel is a different c value.",
        center_r=-0.75,
        center_i=0.0,
        x_width=3.5,
        max_iter=128,
    ),
    "julia": FractalPreset(
        key="julia",
        title="Julia",
        mode=MODE_JULIA,
        formula="z → z² + c",
        description="Fixed-c escape-time set. Each pixel is a different starting value z₀.",
        center_r=0.0,
        center_i=0.0,
        x_width=3.2,
        max_iter=160,
        julia_c_r=-0.800,
        julia_c_i=0.156,
        julia_c_step=0.015,
    ),
    "burning_ship": FractalPreset(
        key="burning_ship",
        title="Burning Ship",
        mode=MODE_BURNING,
        formula="z → (|Re(z)| + i|Im(z)|)² + c",
        description="Uses absolute values before squaring, creating sharp ship-like detail.",
        center_r=-0.45,
        center_i=-0.55,
        x_width=3.6,
        max_iter=160,
    ),
    "tricorn": FractalPreset(
        key="tricorn",
        title="Tricorn",
        mode=MODE_TRICORN,
        formula="z → conjugate(z)² + c",
        description="Conjugates z before squaring, giving a Mandelbrot-like set with different symmetry.",
        center_r=0.0,
        center_i=0.0,
        x_width=3.6,
        max_iter=160,
    ),
}



@dataclass
class FreeRoamState:
    preset_key: str = "mandelbrot"
    center_r: float = -0.75
    center_i: float = 0.0
    x_width: float = 3.5
    max_iter: int = 128
    julia_c_r: float = -0.800
    julia_c_i: float = 0.156
    julia_c_step: float = 0.015
    julia_control_mode: str = "view"
    palette_index: int = 0
    hud_visible: bool = True
    fine_control: bool = False
    dirty: bool = True
    quit_requested: bool = False
    transition_request: Optional[str] = None
    last_message: str = "Free-roam ready"
    last_render_s: float = 0.0
    last_written: int = 0
    last_errors: int = 0
    render_count: int = 0
    palette_names: tuple[str, ...] = PALETTE_NAMES

    @property
    def preset(self) -> FractalPreset:
        return PRESETS[self.preset_key]

    @property
    def mode(self) -> int:
        return self.preset.mode

    @property
    def title(self) -> str:
        return self.preset.title

    @property
    def formula(self) -> str:
        return self.preset.formula

    @property
    def description(self) -> str:
        return self.preset.description

    @property
    def is_julia(self) -> bool:
        return self.mode == MODE_JULIA

    @property
    def control_label(self) -> str:
        if not self.is_julia:
            return "fine" if self.fine_control else "coarse"
        return "choose c" if self.julia_control_mode == "c" else "explore Julia"

    def apply_preset(self, preset_key: str, *, reset_palette: bool = False) -> None:
        if preset_key not in PRESETS:
            raise KeyError(f"Unknown free-roam preset {preset_key!r}")
        preset = PRESETS[preset_key]
        self.preset_key = preset.key
        self.center_r = preset.center_r
        self.center_i = preset.center_i
        self.x_width = preset.x_width
        self.max_iter = preset.max_iter
        self.julia_c_r = preset.julia_c_r
        self.julia_c_i = preset.julia_c_i
        self.julia_c_step = preset.julia_c_step
        self.julia_control_mode = "c" if preset.mode == MODE_JULIA else "view"
        if reset_palette:
            self.palette_index = 0
        self.dirty = True
        self.last_message = f"Loaded {preset.title}"

    def reset_view(self) -> None:
        self.apply_preset(self.preset_key)
        self.last_message = f"{self.title} view reset"

    def clamp_view(self) -> None:
        self.x_width = min(max(float(self.x_width), 1.0e-9), 5.0)
        self.max_iter = min(max(int(self.max_iter), 16), 4096)
        self.center_r = min(max(float(self.center_r), -4.0), 4.0)
        self.center_i = min(max(float(self.center_i), -4.0), 4.0)
        self.julia_c_r = min(max(float(self.julia_c_r), JULIA_C_R_MIN), JULIA_C_R_MAX)
        self.julia_c_i = min(max(float(self.julia_c_i), JULIA_C_I_MIN), JULIA_C_I_MAX)
        self.julia_c_step = min(max(float(self.julia_c_step), JULIA_C_STEP_MIN), JULIA_C_STEP_MAX)


class SceneFreeRoam:
    def __init__(self, state: Optional[FreeRoamState] = None, preset_key: str = "mandelbrot") -> None:
        self.state = state or FreeRoamState()
        self.state.apply_preset(preset_key, reset_palette=False)

    def handle_event(self, event: Event) -> None:
        s = self.state

        if event.kind is EventKind.QUIT:
            s.quit_requested = True
            return

        if event.kind in (EventKind.NEXT, EventKind.BACK, EventKind.MENU):
            s.transition_request = "menu"
            s.last_message = "Returning to exploration menu"
            return

        if event.kind is EventKind.ACTION:
            s.hud_visible = not s.hud_visible
            s.dirty = True
            s.last_message = "HUD on" if s.hud_visible else "HUD off"
            return

        if event.kind is EventKind.RESET:
            s.reset_view()
            return

        if event.kind is EventKind.PALETTE:
            s.palette_index = (s.palette_index + 1) % len(s.palette_names)
            s.dirty = True
            s.last_message = f"Palette control: {s.palette_names[s.palette_index]}"
            return

        if event.kind is EventKind.FUNCTION:
            if s.is_julia:
                s.julia_control_mode = "view" if s.julia_control_mode == "c" else "c"
                s.dirty = True
                if s.julia_control_mode == "c":
                    s.last_message = "Choosing c: joystick moves c, Encoder 1 changes c-step"
                else:
                    s.last_message = "Exploring Julia: joystick pans, Encoder 1 zooms"
            else:
                s.fine_control = not s.fine_control
                s.last_message = "Fine controls on" if s.fine_control else "Coarse controls on"
            return

        if event.kind is EventKind.PAN:
            dx, dy = event.value or (0.0, 0.0)
            if s.is_julia and s.julia_control_mode == "c":
                s.julia_c_r += float(dx) * s.julia_c_step
                s.julia_c_i += float(dy) * s.julia_c_step
                s.clamp_view()
                s.dirty = True
                s.last_message = f"c = {s.julia_c_r:+.5f} {s.julia_c_i:+.5f}i"
                return

            speed = 0.020 if s.fine_control else 0.065
            step = s.x_width * speed
            s.center_r += float(dx) * step
            # Match the working Scene 5 HDMI feel: joystick-up should move the
            # visible set upwards even though the framebuffer y-axis is inverted.
            s.center_i -= float(dy) * step
            s.clamp_view()
            s.dirty = True
            s.last_message = f"Pan to ({s.center_r:+.6f}, {s.center_i:+.6f})"
            return

        if event.kind is EventKind.ZOOM:
            delta = float(event.value or 0.0)
            if delta == 0.0:
                return
            if s.is_julia and s.julia_control_mode == "c":
                # While choosing c, Encoder 1 controls cursor precision instead
                # of changing the Julia viewport. Positive zoom means finer steps.
                precision_factor = 0.75
                if delta > 0:
                    s.julia_c_step *= precision_factor ** abs(delta)
                else:
                    s.julia_c_step /= precision_factor ** abs(delta)
                s.clamp_view()
                s.dirty = True
                s.last_message = f"c step {s.julia_c_step:.4f}"
                return

            factor = 0.90 if s.fine_control else 0.78
            if delta > 0:
                s.x_width *= factor ** abs(delta)
            else:
                s.x_width /= factor ** abs(delta)
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


# Julia free-roam Mandelbrot reference map

def _generate_mandelbrot_reference() -> np.ndarray:
    real = np.linspace(JULIA_C_R_MIN, JULIA_C_R_MAX, MANDEL_REF_W, dtype=np.float64)
    imag = np.linspace(JULIA_C_I_MAX, JULIA_C_I_MIN, MANDEL_REF_H, dtype=np.float64)
    c = real[None, :] + 1j * imag[:, None]
    z = np.zeros_like(c)
    counts = np.zeros(c.shape, dtype=np.uint16)
    alive = np.ones(c.shape, dtype=bool)

    for i in range(1, MANDEL_REF_MAX_ITER + 1):
        z_alive = z[alive]
        c_alive = c[alive]
        z[alive] = z_alive * z_alive + c_alive
        escaped = alive & (z.real * z.real + z.imag * z.imag > 4.0)
        counts[escaped] = i
        alive &= ~escaped

    counts[alive] = MANDEL_REF_MAX_ITER
    t = counts.astype(np.float32) / float(MANDEL_REF_MAX_ITER)
    rgb = np.zeros((MANDEL_REF_H, MANDEL_REF_W, 3), dtype=np.uint8)
    outside = counts < MANDEL_REF_MAX_ITER
    rgb[..., 0] = np.where(outside, (25 + 135 * np.sqrt(t)).astype(np.uint8), 4)
    rgb[..., 1] = np.where(outside, (58 + 155 * t).astype(np.uint8), 9)
    rgb[..., 2] = np.where(outside, (95 + 145 * (1.0 - t)).astype(np.uint8), 20)
    return rgb


def mandelbrot_reference_rgb() -> np.ndarray:
    global _MANDEL_REF_CACHE
    if _MANDEL_REF_CACHE is not None:
        return _MANDEL_REF_CACHE

    cache_path = None
    try:
        from PIL import Image
        cache_path = Path(__file__).with_name(f"free_roam_mandelbrot_reference_{MANDEL_REF_W}x{MANDEL_REF_H}.png")
        if cache_path.exists():
            img = Image.open(cache_path).convert("RGB")
            if img.size == (MANDEL_REF_W, MANDEL_REF_H):
                _MANDEL_REF_CACHE = np.asarray(img, dtype=np.uint8)
                return _MANDEL_REF_CACHE
    except Exception:
        cache_path = None

    _MANDEL_REF_CACHE = _generate_mandelbrot_reference()
    try:
        from PIL import Image
        if cache_path is not None:
            Image.fromarray(_MANDEL_REF_CACHE, mode="RGB").save(cache_path)
    except Exception:
        pass
    return _MANDEL_REF_CACHE


def c_to_reference_pixel(c_r: float, c_i: float, x0: int, y0: int, w: int, h: int) -> tuple[int, int]:
    tr = (float(c_r) - JULIA_C_R_MIN) / (JULIA_C_R_MAX - JULIA_C_R_MIN)
    ti = (JULIA_C_I_MAX - float(c_i)) / (JULIA_C_I_MAX - JULIA_C_I_MIN)
    px = int(round(x0 + min(max(tr, 0.0), 1.0) * (w - 1)))
    py = int(round(y0 + min(max(ti, 0.0), 1.0) * (h - 1)))
    return px, py


def make_state(preset_key: str) -> FreeRoamState:
    state = FreeRoamState()
    state.apply_preset(preset_key, reset_palette=False)
    return state


def clear_hud_panels(fb) -> None:
    raw = np.asarray(fb)
    raw[0:PANEL_HEIGHT, 0:PANEL_WIDTH] = 0x00000000
    raw[0:PANEL_HEIGHT, WIDTH - PANEL_WIDTH:WIDTH] = 0x00000000


def _write_rgb_panel(raw: np.ndarray, x0: int, y0: int, rgb: np.ndarray) -> None:
    packed = (
        (rgb[..., 0].astype(np.uint32) << 16)
        | (rgb[..., 1].astype(np.uint32) << 8)
        | rgb[..., 2].astype(np.uint32)
    )
    h, w = packed.shape
    raw[y0:y0 + h, x0:x0 + w] = packed


def draw_hud(fb, state: FreeRoamState, result: dict[str, int | float], scale: int, palette_hw: bool) -> None:
    try:
        from PIL import Image, ImageDraw, ImageFont
    except Exception:
        clear_hud_panels(fb)
        return

    raw = np.asarray(fb)
    clear_hud_panels(fb)

    try:
        font_title = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", 18)
        font = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", 13)
        font_small = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", 11)
        font_mono = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf", 12)
    except Exception:
        font_title = ImageFont.load_default()
        font = ImageFont.load_default()
        font_small = ImageFont.load_default()
        font_mono = ImageFont.load_default()

    accent = {
        "mandelbrot": (80, 230, 230),
        "julia": (120, 225, 255),
        "burning_ship": (255, 170, 80),
        "tricorn": (255, 135, 190),
    }.get(state.preset_key, (80, 230, 230))

    def make_panel() -> tuple[Image.Image, ImageDraw.ImageDraw]:
        img = Image.new("RGB", (PANEL_WIDTH, PANEL_HEIGHT), (5, 9, 18))
        d = ImageDraw.Draw(img)
        d.rounded_rectangle(
            (8, 8, PANEL_WIDTH - 8, PANEL_HEIGHT - 8),
            radius=14,
            fill=(8, 14, 24),
            outline=accent,
            width=1,
        )
        return img, d

    left, dl = make_panel()
    dl.text((24, 16), state.title, font=font_title, fill=(245, 250, 255))
    desc_words = state.description.split()
    first_line = " ".join(desc_words[:7])
    second_line = " ".join(desc_words[7:14])
    dl.text((24, 43), first_line[:42], font=font, fill=(205, 225, 235))
    if second_line:
        dl.text((24, 62), second_line[:42], font=font, fill=(205, 225, 235))
    dl.text((24, 88), state.formula[:42], font=font_mono, fill=(255, 225, 150))
    if state.is_julia:
        dl.text((24, 108), f"c {state.julia_c_r:+.5f} {state.julia_c_i:+.5f}i", font=font_small, fill=(170, 225, 245))
        dl.text((24, 123), f"view {state.center_r:+.3f} {state.center_i:+.3f}i  w {state.x_width:.4g}", font=font_small, fill=(170, 195, 205))
        dl.text((24, 138), f"iter {state.max_iter}   c-step {state.julia_c_step:.4f}", font=font_small, fill=(170, 195, 205))
    else:
        dl.text((24, 119), f"center {state.center_r:+.4f} {state.center_i:+.4f}i", font=font_small, fill=(170, 195, 205))
        dl.text((24, 136), f"width {state.x_width:.4g}   iter {state.max_iter}", font=font_small, fill=(170, 195, 205))
    if state.fine_control and not state.is_julia:
        dl.text((PANEL_WIDTH - 72, 122), "fine", font=font_small, fill=(255, 150, 190))

    right, dr = make_panel()
    palette_text = state.palette_names[state.palette_index]
    if not palette_hw:
        palette_text += "*"

    if state.is_julia:
        dr.text((24, 14), "Mandelbrot c-map", font=font_title, fill=(245, 250, 255))
        dr.text((PANEL_WIDTH - 150, 18), palette_text[:18], font=font_small, fill=(155, 210, 225))

        map_x, map_y = 36, 39
        ref_img = Image.fromarray(mandelbrot_reference_rgb(), mode="RGB").resize((MANDEL_DISPLAY_W, MANDEL_DISPLAY_H))
        dr.rounded_rectangle(
            (map_x - 2, map_y - 2, map_x + MANDEL_DISPLAY_W + 1, map_y + MANDEL_DISPLAY_H + 1),
            radius=8,
            outline=(45, 70, 82),
            width=1,
        )
        right.paste(ref_img, (map_x, map_y))

        px, py = c_to_reference_pixel(state.julia_c_r, state.julia_c_i, map_x, map_y, MANDEL_DISPLAY_W, MANDEL_DISPLAY_H)
        cursor_colour = (255, 245, 130) if state.julia_control_mode == "c" else (120, 225, 255)
        dr.ellipse((px - 7, py - 7, px + 7, py + 7), outline=cursor_colour, width=3)
        dr.line((px - 11, py, px + 11, py), fill=cursor_colour, width=1)
        dr.line((px, py - 11, px, py + 11), fill=cursor_colour, width=1)

        mode_text = "Mode: choose c" if state.julia_control_mode == "c" else "Mode: explore Julia"
        control_text = "Joystick c   Enc1 step   B4 explore" if state.julia_control_mode == "c" else "Joystick pan   Enc1 zoom   B4 choose c"
        dr.text((24, 126), mode_text, font=font_small, fill=cursor_colour)
        dr.text((24, 140), control_text[:38], font=font_small, fill=(245, 235, 170))
    else:
        dr.text((24, 16), "Free roam", font=font_title, fill=(245, 250, 255))
        dr.text((24, 43), "Joystick            pan", font=font_small, fill=(170, 195, 205))
        dr.text((24, 62), "Encoder 1           zoom", font=font_small, fill=(170, 195, 205))
        dr.text((24, 80), "Encoder 2           iterations", font=font_small, fill=(170, 195, 205))
        dr.text((24, 98), "Joy click reset   B5 palette", font=font_small, fill=(170, 195, 205))
        dr.text((24, 116), "B3 HUD   B4 fine   B1/B2/B6 menu", font=font_small, fill=(245, 235, 170))
        dr.text((24, 134), f"Palette: {palette_text[:22]}", font=font_small, fill=(155, 210, 225))

    _write_rgb_panel(raw, 0, 0, np.asarray(left, dtype=np.uint8))
    _write_rgb_panel(raw, WIDTH - PANEL_WIDTH, 0, np.asarray(right, dtype=np.uint8))
