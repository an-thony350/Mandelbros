"""
ui_renderer.py — FractalScope HDMI overlay renderer
Draws a HUD-style overlay on top of the FPGA-rendered fractal framebuffer.
Uses Pillow (PIL) for text rendering into a NumPy framebuffer.

Dependencies:
    pip install pillow numpy

Usage (called every frame from main.py):
    from ui_renderer import UIRenderer
    renderer = UIRenderer(width=1280, height=720)
    renderer.draw(framebuffer, state)
"""

import numpy as np
from PIL import Image, ImageDraw, ImageFont
import time


# ---------------------------------------------------------------------------
# Colour constants (R, G, B)
# ---------------------------------------------------------------------------
WHITE       = (255, 255, 255)
YELLOW      = (255, 220,  50)
CYAN        = ( 80, 220, 220)
RED         = (255,  80,  80)
ORANGE      = (255, 160,  40)
DIM_WHITE   = (180, 180, 180)
BLACK       = (  0,   0,   0)

# Semi-transparent overlay panel colour (applied via NumPy blending)
PANEL_COLOUR   = np.array([0, 0, 0], dtype=np.float32)

# Warning badge colours
BADGE_OVERFLOW = np.array([180, 40, 40], dtype=np.float32)
BADGE_DISCO    = np.array([40,  40, 40], dtype=np.float32)


class UIRenderer:
    """
    Draws the HUD overlay onto a (height, width, 3) uint8 NumPy framebuffer.

    Call draw() once per frame after the FPGA has written its output.
    The framebuffer is modified in-place.

    Panel dimensions (for FPGA pixel-skip optimisation):
        top-left:  x=0,             y=0, w=PANEL_W, h=PANEL_H
        top-right: x=width-PANEL_W, y=0, w=PANEL_W, h=PANEL_H
    """

    # HUD layout constants
    PAD        = 14    # padding for text inside panels (pixels from panel edge)
    LINE_H     = 22    # line height for normal text
    SMALL_LINE = 18    # line height for small/label text
    PANEL_W    = 192   # width of both panels — fixed constant for FPGA
    PANEL_H    = 160   # height of both panels — fixed constant for FPGA
                       # sized at maximum needed (Julia mode with c parameter line)

    def __init__(self, width: int = 1280, height: int = 720):
        self.width  = width
        self.height = height

        # FPS tracking
        self._last_time   = time.monotonic()
        self._frame_count = 0
        self._fps         = 0.0

        # Try to load a monospace font; fall back to PIL default if not found
        self._font_normal = self._load_font(15)
        self._font_small  = self._load_font(12)
        self._font_large  = self._load_font(18)

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    def draw(self, framebuffer: np.ndarray, state) -> None:
        """
        Draw the overlay onto framebuffer (modified in-place).

        state must expose:
            state.center_r      float   — real part of view centre
            state.center_i      float   — imaginary part of view centre
            state.zoom          float   — zoom factor (1.0 = default view)
            state.max_iter      int     — requested max iterations
            state.actual_iter   int     — actual max iter used last frame
            state.palette_name  str     — current palette name
            state.fractal_mode  str     — e.g. "Mandelbrot", "Julia"
            state.julia_c_r     float   — Julia c real (shown in Julia mode)
            state.julia_c_i     float   — Julia c imag
            state.overflow      bool    — FPGA overflow flag
            state.connected     bool    — controller connected flag
            state.joy_x         float   — joystick X, -1.0 .. 1.0
            state.joy_y         float   — joystick Y, -1.0 .. 1.0
        """
        self._update_fps()

        # Draw dark panels flush to corners before PIL text
        # Panels are fixed size — FPGA can skip rendering these regions
        self._draw_panel(framebuffer,
                         x=0, y=0,
                         w=self.PANEL_W, h=self.PANEL_H)
        self._draw_panel(framebuffer,
                         x=self.width - self.PANEL_W, y=0,
                         w=self.PANEL_W, h=self.PANEL_H)

        # Convert framebuffer to PIL Image for text drawing
        # Done AFTER panels so text draws on top of dark background
        img  = Image.fromarray(framebuffer, mode='RGB')
        draw = ImageDraw.Draw(img)

        # --- Top-left panel: fractal mode + coordinates + zoom ---
        self._draw_top_left(draw, state)

        # --- Top-right panel: iterations + FPS + palette + controller ---
        self._draw_top_right(draw, state)

        # --- Warning badges (bottom-left) ---
        self._draw_badges(draw, framebuffer, state)

        # --- Crosshair at joystick position ---
        self._draw_crosshair(draw, state)

        # Write modified image back into the framebuffer array in-place
        framebuffer[:] = np.array(img)

    # ------------------------------------------------------------------
    # Panel background (NumPy blending — no per-pixel Python loop)
    # ------------------------------------------------------------------

    def _draw_panel(self, framebuffer: np.ndarray,
                    x: int, y: int, w: int, h: int,
                    colour=PANEL_COLOUR, alpha=0.88) -> None:
        """Blend a near-black rectangle into the framebuffer region."""
        region = framebuffer[y:y+h, x:x+w].astype(np.float32)
        dark = np.full_like(region, 10)  # very dark base (near black)
        region = region * (1.0 - alpha) + dark * alpha
        framebuffer[y:y+h, x:x+w] = region.astype(np.uint8)

    # ------------------------------------------------------------------
    # Helper: draw text with a 1px black drop shadow for readability
    # ------------------------------------------------------------------

    @staticmethod
    def _text(draw: ImageDraw.Draw, pos, text, font, fill) -> None:
        """Draw text with a 1px black shadow underneath for contrast."""
        x, y = pos
        draw.text((x + 1, y + 1), text, font=font, fill=BLACK)
        draw.text((x, y),         text, font=font, fill=fill)

    @staticmethod
    def _text_right(draw: ImageDraw.Draw, right_x: int, y: int,
                    text, font, fill) -> None:
        """Draw right-aligned text with a 1px black shadow.
        right_x is the x coordinate of the right edge the text aligns to."""
        bbox = draw.textbbox((0, 0), text, font=font)
        text_w = bbox[2] - bbox[0]
        x = right_x - text_w
        draw.text((x + 1, y + 1), text, font=font, fill=BLACK)
        draw.text((x, y),         text, font=font, fill=fill)

    # ------------------------------------------------------------------
    # Top-left panel: fractal mode, coordinates, zoom, Julia c
    # ------------------------------------------------------------------

    def _draw_top_left(self, draw: ImageDraw.Draw, state) -> None:
        x = self.PAD
        y = self.PAD

        # Mode label
        self._text(draw, (x, y), state.fractal_mode.upper(),
                   font=self._font_large, fill=CYAN)
        y += self.LINE_H + 4

        # Coordinates
        self._text(draw, (x, y), "Centre",
                   font=self._font_small, fill=DIM_WHITE)
        y += self.SMALL_LINE
        self._text(draw, (x, y),
                   f"Re: {state.center_r:+.8f}",
                   font=self._font_normal, fill=WHITE)
        y += self.LINE_H
        self._text(draw, (x, y),
                   f"Im: {state.center_i:+.8f}",
                   font=self._font_normal, fill=WHITE)
        y += self.LINE_H

        # Zoom
        self._text(draw, (x, y),
                   f"Zoom:  {state.zoom:,.0f}x",
                   font=self._font_normal, fill=YELLOW)
        y += self.LINE_H

        # Julia c parameter (only shown in Julia mode)
        if state.fractal_mode == "Julia":
            self._text(draw, (x, y),
                       f"c =  {state.julia_c_r:+.5f} {state.julia_c_i:+.5f}i",
                       font=self._font_normal, fill=CYAN)

    # ------------------------------------------------------------------
    # Top-right panel: iterations, FPS, palette, controller status
    # ------------------------------------------------------------------

    def _draw_top_right(self, draw: ImageDraw.Draw, state) -> None:
        # Right edge of panel minus padding
        right_x = self.width - self.PAD
        y = self.PAD

        # Iterations — orange if FPGA clamped below requested
        iter_colour = ORANGE if state.actual_iter < state.max_iter else WHITE
        self._text_right(draw, right_x, y, "Max iter",
                         font=self._font_small, fill=DIM_WHITE)
        y += self.SMALL_LINE
        if state.actual_iter < state.max_iter:
            self._text_right(draw, right_x, y,
                             f"{state.actual_iter}  (req: {state.max_iter})",
                             font=self._font_normal, fill=iter_colour)
        else:
            self._text_right(draw, right_x, y,
                             f"{state.max_iter}",
                             font=self._font_normal, fill=WHITE)
        y += self.LINE_H

        # FPS — colour coded: white >= 50, orange >= 25, red < 25
        fps_colour = WHITE if self._fps >= 50 else (ORANGE if self._fps >= 25 else RED)
        self._text_right(draw, right_x, y, "FPS",
                         font=self._font_small, fill=DIM_WHITE)
        y += self.SMALL_LINE
        self._text_right(draw, right_x, y, f"{self._fps:.1f}",
                         font=self._font_normal, fill=fps_colour)
        y += self.LINE_H

        # Palette
        self._text_right(draw, right_x, y, "Palette",
                         font=self._font_small, fill=DIM_WHITE)
        y += self.SMALL_LINE
        self._text_right(draw, right_x, y, state.palette_name,
                         font=self._font_normal, fill=WHITE)
        y += self.LINE_H

        # Controller status
        status_text   = "Controller connected" if state.connected else "Controller disconnected"
        status_colour = CYAN if state.connected else RED
        self._text_right(draw, right_x, y, status_text,
                         font=self._font_small, fill=status_colour)

    # ------------------------------------------------------------------
    # Warning badges (bottom-left, appear only when needed)
    # ------------------------------------------------------------------

    def _draw_badges(self, draw: ImageDraw.Draw,
                     framebuffer: np.ndarray, state) -> None:
        badge_y = self.height - self.PAD - self.LINE_H - 4
        badge_x = self.PAD

        if state.overflow:
            bw, bh = 240, self.LINE_H + 8
            self._draw_panel(framebuffer,
                             x=badge_x, y=badge_y - 4,
                             w=bw, h=bh,
                             colour=BADGE_OVERFLOW, alpha=0.85)
            self._text(draw, (badge_x + 8, badge_y),
                       "!  Precision limit reached",
                       font=self._font_small, fill=WHITE)
            badge_y -= bh + 4

        if not state.connected:
            bw, bh = 220, self.LINE_H + 8
            self._draw_panel(framebuffer,
                             x=badge_x, y=badge_y - 4,
                             w=bw, h=bh,
                             colour=BADGE_DISCO, alpha=0.85)
            self._text(draw, (badge_x + 8, badge_y),
                       "Keyboard fallback active",
                       font=self._font_small, fill=ORANGE)

    # ------------------------------------------------------------------
    # Crosshair (follows joystick position)
    # ------------------------------------------------------------------

    def _draw_crosshair(self, draw: ImageDraw.Draw, state) -> None:
        """
        Draw a small crosshair at the joystick position.
        joy_x and joy_y are -1.0 .. 1.0, mapped to screen coordinates.
        At (0, 0) the crosshair sits at the screen centre.
        """
        cx = int(self.width  / 2 + state.joy_x * self.width  / 2)
        cy = int(self.height / 2 - state.joy_y * self.height / 2)

        arm = 10  # arm length in pixels
        gap =  3  # gap around centre point

        # Shadow pass
        draw.line((cx - arm + 1, cy + 1, cx - gap + 1, cy + 1), fill=BLACK, width=1)
        draw.line((cx + gap + 1, cy + 1, cx + arm + 1, cy + 1), fill=BLACK, width=1)
        draw.line((cx + 1, cy - arm + 1, cx + 1, cy - gap + 1), fill=BLACK, width=1)
        draw.line((cx + 1, cy + gap + 1, cx + 1, cy + arm + 1), fill=BLACK, width=1)

        # Crosshair lines
        draw.line((cx - arm, cy, cx - gap, cy), fill=WHITE, width=1)
        draw.line((cx + gap, cy, cx + arm, cy), fill=WHITE, width=1)
        draw.line((cx, cy - arm, cx, cy - gap), fill=WHITE, width=1)
        draw.line((cx, cy + gap, cx, cy + arm), fill=WHITE, width=1)

        # Centre dot
        draw.ellipse((cx - 1, cy - 1, cx + 1, cy + 1), fill=WHITE)

    # ------------------------------------------------------------------
    # FPS tracking
    # ------------------------------------------------------------------

    def _update_fps(self) -> None:
        self._frame_count += 1
        now     = time.monotonic()
        elapsed = now - self._last_time
        if elapsed >= 0.5:   # update display twice per second
            self._fps         = self._frame_count / elapsed
            self._frame_count = 0
            self._last_time   = now

    # ------------------------------------------------------------------
    # Font loader
    # ------------------------------------------------------------------

    @staticmethod
    def _load_font(size: int) -> ImageFont.FreeTypeFont:
        """
        Try common monospace fonts on the PYNQ Linux image.
        Falls back to PIL built-in if none found.
        """
        candidates = [
            "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
            "/usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf",
            "/usr/share/fonts/truetype/freefont/FreeMono.ttf",
        ]
        for path in candidates:
            try:
                return ImageFont.truetype(path, size)
            except (IOError, OSError):
                continue
        return ImageFont.load_default()
