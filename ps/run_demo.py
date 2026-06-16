#!/usr/bin/env python3
"""
integrated walkthrough scene manager.

keeps scene logic in the existing standalone files while providing the missing app shell around them
"""

from __future__ import annotations

import argparse
import importlib.util
import os
import select
import sys
import termios
import time
import tty
from contextlib import contextmanager
from dataclasses import dataclass
from enum import Enum, auto
from pathlib import Path
from types import ModuleType, SimpleNamespace
from typing import Iterable, Optional, Protocol

import numpy as np

PROJECT_ROOT = Path(__file__).resolve().parent
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

from backend.pl_backend import (
    MODE_BURNING,
    MODE_JULIA,
    MODE_MANDEL,
    MODE_TRICORN,
    PlWalkthroughBackend,
    add_backend_args,
)

from backend.cpu_baseline_runner import (
    CpuRenderConfig,
    CpuRenderResult,
    format_cpu_stats,
    make_temp_output_config,
    pack_rgb888 as pack_cpu_rgb888,
    render_cpu_frame,
    resize_rgb_nearest,
)


# Shared display/app constants

WIDTH = 1280
HEIGHT = 720
BPP = 4
DEFAULT_BIT_PATH = "/home/xilinx/jupyter_notebooks/fractalscope"
SCRIPT_VERSION = "2026-06-15-scene-manager-v14-loading-screen"


# Shared logical event layer

class AppEventKind(Enum):
    NEXT = auto()
    BACK = auto()
    ACTION = auto()
    MENU = auto()
    RESET = auto()
    PALETTE = auto()
    FUNCTION = auto()
    PAN = auto()       # value: (dx, dy), where dy > 0 means up
    ZOOM = auto()      # value: signed encoder delta
    ITER = auto()      # value: signed encoder delta
    QUIT = auto()


@dataclass(frozen=True)
class AppEvent:
    kind: AppEventKind
    value: object = None
    source: str = "keyboard"


class SceneAdapter(Protocol):
    key: str
    title: str
    transition_request: Optional[str]
    quit_requested: bool

    def on_enter(self) -> None: ...
    def handle_app_event(self, event: AppEvent) -> None: ...
    def update(self, now: float) -> None: ...
    def wants_redraw(self, now: float) -> bool: ...
    def draw_packed(self, now: float) -> np.ndarray: ...
    def clear_transition(self) -> None: ...


# Keyboard input backend

@contextmanager
def raw_terminal():
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


class KeyboardInput:
    """Terminal keyboard emulator for the future physical controller."""

    def poll(self) -> list[AppEvent]:
        events: list[AppEvent] = []
        if not sys.stdin.isatty():
            return events

        while sys.stdin in select.select([sys.stdin], [], [], 0)[0]:
            ch = sys.stdin.read(1)
            if not ch:
                break
            events.extend(self._map_char(ch))
        return events

    def _map_char(self, ch: str) -> list[AppEvent]:
        if ch == "\x1b":
            seq = ch
            deadline = time.time() + 0.015
            while time.time() < deadline and sys.stdin in select.select([sys.stdin], [], [], 0)[0]:
                seq += sys.stdin.read(1)
            arrows = {
                "\x1b[A": AppEvent(AppEventKind.PAN, (0, 1)),
                "\x1b[B": AppEvent(AppEventKind.PAN, (0, -1)),
                "\x1b[C": AppEvent(AppEventKind.PAN, (1, 0)),
                "\x1b[D": AppEvent(AppEventKind.PAN, (-1, 0)),
            }
            return [arrows[seq]] if seq in arrows else []

        key = ch.lower()
        mapping = {
            "q": AppEvent(AppEventKind.QUIT),
            "n": AppEvent(AppEventKind.NEXT),
            "\n": AppEvent(AppEventKind.NEXT),
            "\r": AppEvent(AppEventKind.NEXT),
            "b": AppEvent(AppEventKind.BACK),
            " ": AppEvent(AppEventKind.ACTION),
            "m": AppEvent(AppEventKind.MENU),
            "r": AppEvent(AppEventKind.RESET),
            "p": AppEvent(AppEventKind.PALETTE),
            "f": AppEvent(AppEventKind.FUNCTION),
            "5": AppEvent(AppEventKind.FUNCTION),
            "w": AppEvent(AppEventKind.PAN, (0, 1)),
            "s": AppEvent(AppEventKind.PAN, (0, -1)),
            "a": AppEvent(AppEventKind.PAN, (-1, 0)),
            "d": AppEvent(AppEventKind.PAN, (1, 0)),
            "[": AppEvent(AppEventKind.ZOOM, -1),
            "]": AppEvent(AppEventKind.ZOOM, 1),
            "-": AppEvent(AppEventKind.ITER, -1),
            "_": AppEvent(AppEventKind.ITER, -1),
            "=": AppEvent(AppEventKind.ITER, 1),
            "+": AppEvent(AppEventKind.ITER, 1),
        }
        return [mapping[key]] if key in mapping else []


# Pico USB controller input backend
class ControllerInput:
    """
    Non-blocking reader for the Raspberry Pi Pico USB CDC controller.

    Expected packet, emitted by the current Pico firmware at roughly 100 Hz:
        TDT,<seq>,<btn_hex>,<zoom_d>,<iter_d>,<jx>,<jy>,<crc>
    """

    BUTTON_EVENT_BITS = {
        0: AppEventKind.NEXT,      # physical Button 2 / confirm in the app mapping
        1: AppEventKind.BACK,      # physical Button 1 / back
        2: AppEventKind.ACTION,    # physical Button 3 / scene action or HUD
        3: AppEventKind.FUNCTION,  # physical Button 5 / scene-specific function
        4: AppEventKind.PALETTE,   # physical Button 4 / palette
        5: AppEventKind.MENU,      # physical Button 6 / open or close menu
        8: AppEventKind.RESET,     # joystick click / reset view
    }

    def __init__(
        self,
        device: str = "auto",
        *,
        deadzone: int = 450,
        pan_repeat_s: float = 0.075,
        invert_x: bool = False,
        invert_y: bool = False,
    ) -> None:
        self.device_arg = str(device or "auto")
        self.deadzone = max(0, int(deadzone))
        self.pan_repeat_s = max(0.020, float(pan_repeat_s))
        self.invert_x = bool(invert_x)
        self.invert_y = bool(invert_y)
        self.fd: Optional[int] = None
        self.device_path: Optional[str] = None
        self.buffer = b""
        self.prev_buttons: Optional[int] = None
        self.last_pan_time = 0.0
        self.last_pan_direction: Optional[tuple[int, int]] = None
        self.last_retry_time = 0.0
        self.bad_crc_count = 0
        self.bad_line_count = 0

        if self.device_arg.lower() != "off":
            self._try_open(force=True)

    @property
    def enabled(self) -> bool:
        return self.device_arg.lower() != "off"

    def close(self) -> None:
        if self.fd is not None:
            try:
                os.close(self.fd)
            except OSError:
                pass
        self.fd = None
        self.device_path = None

    def poll(self) -> list[AppEvent]:
        events: list[AppEvent] = []
        if not self.enabled:
            return events
        if self.fd is None:
            self._try_open(force=False)
            return events

        try:
            while True:
                chunk = os.read(self.fd, 4096)
                if not chunk:
                    break
                self.buffer += chunk
                if len(self.buffer) > 8192:
                    # Drop stale partial data rather than letting a bad cable or reset consume memory forever.
                    self.buffer = self.buffer[-2048:]
        except BlockingIOError:
            pass
        except OSError as exc:
            print(f"Controller disconnected from {self.device_path}: {exc}")
            self.close()
            return events

        while b"\n" in self.buffer:
            raw_line, self.buffer = self.buffer.split(b"\n", 1)
            packet = self._parse_line(raw_line)
            if packet is not None:
                events.extend(self._packet_to_events(packet))
        return events

    def _try_open(self, *, force: bool) -> None:
        now = time.monotonic()
        if not force and now - self.last_retry_time < 1.0:
            return
        self.last_retry_time = now

        for path in self._candidate_devices():
            try:
                fd = os.open(path, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
                self._configure_tty(fd)
                self.fd = fd
                self.device_path = path
                self.buffer = b""
                self.prev_buttons = None
                print(f"Controller input connected: {path}")
                return
            except OSError:
                continue

        if force and self.device_arg.lower() == "auto":
            print("Controller input: no /dev/ttyACM* or /dev/ttyUSB* device found yet; keyboard fallback remains active.")
        elif force:
            print(f"Controller input: could not open {self.device_arg!r}; keyboard fallback remains active.")

    def _candidate_devices(self) -> list[str]:
        if self.device_arg.lower() != "auto":
            return [self.device_arg]
        dev = Path("/dev")
        candidates = [str(p) for p in sorted(dev.glob("ttyACM*"))]
        candidates += [str(p) for p in sorted(dev.glob("ttyUSB*"))]
        return candidates

    @staticmethod
    def _configure_tty(fd: int) -> None:
        try:
            attrs = termios.tcgetattr(fd)
            attrs[0] = 0
            attrs[1] = 0
            attrs[2] = attrs[2] | termios.CREAD | termios.CLOCAL
            attrs[3] = 0
            attrs[6][termios.VMIN] = 0
            attrs[6][termios.VTIME] = 0
            termios.tcsetattr(fd, termios.TCSANOW, attrs)
        except Exception:
            # USB CDC from the Pico normally works even if termios setup is not fully supported by the driver.
            pass

    def _parse_line(self, raw_line: bytes) -> Optional[tuple[int, int, int, int, int, int]]:
        text_line = raw_line.decode("ascii", errors="ignore").strip()
        if not text_line:
            return None
        parts = text_line.split(",")
        if len(parts) != 8 or parts[0] not in ("TDT", "FSCP"):
            self.bad_line_count += 1
            return None

        payload = ",".join(parts[:-1])
        try:
            expected_crc = int(parts[-1], 16) & 0xFF
        except ValueError:
            self.bad_line_count += 1
            return None
        actual_crc = self._crc8_ccitt(payload.encode("ascii"))
        if actual_crc != expected_crc:
            self.bad_crc_count += 1
            return None

        try:
            seq = int(parts[1], 10) & 0xFFFF
            buttons = int(parts[2], 16) & 0xFFFF
            zoom_d = int(parts[3], 10)
            iter_d = int(parts[4], 10)
            jx = int(parts[5], 10)
            jy = int(parts[6], 10)
        except ValueError:
            self.bad_line_count += 1
            return None
        return seq, buttons, zoom_d, iter_d, jx, jy

    def _packet_to_events(self, packet: tuple[int, int, int, int, int, int]) -> list[AppEvent]:
        _seq, buttons, zoom_d, iter_d, jx, jy = packet
        events: list[AppEvent] = []

        if self.prev_buttons is None:
            pressed = 0
        else:
            pressed = buttons & ~self.prev_buttons
        self.prev_buttons = buttons

        for bit, kind in self.BUTTON_EVENT_BITS.items():
            if pressed & (1 << bit):
                events.append(AppEvent(kind, source="controller"))

        if zoom_d:
            events.append(AppEvent(AppEventKind.ZOOM, int(zoom_d), "controller"))
        if iter_d:
            events.append(AppEvent(AppEventKind.ITER, int(iter_d), "controller"))

        pan = self._joystick_to_pan(jx, jy)
        if pan is None:
            # Emit a neutral edge when the stick returns to centre.  The menu uses this to re-arm one-card joystick navigation
            if self.last_pan_direction is not None:
                events.append(AppEvent(AppEventKind.PAN, (0, 0), "controller"))
                self.last_pan_direction = None
                self.last_pan_time = 0.0
        else:
            now = time.monotonic()
            direction_changed = pan != self.last_pan_direction
            if direction_changed or now - self.last_pan_time >= self.pan_repeat_s:
                events.append(AppEvent(AppEventKind.PAN, pan, "controller"))
                self.last_pan_time = now
            self.last_pan_direction = pan
        return events

    def _joystick_to_pan(self, jx: int, jy: int) -> Optional[tuple[int, int]]:
        x = -int(jx) if self.invert_x else int(jx)
        y = -int(jy) if self.invert_y else int(jy)

        dx = 0
        dy = 0
        if x > self.deadzone:
            dx = 1
        elif x < -self.deadzone:
            dx = -1
        if y > self.deadzone:
            dy = 1
        elif y < -self.deadzone:
            dy = -1

        if dx == 0 and dy == 0:
            return None
        return dx, dy

    @staticmethod
    def _crc8_ccitt(data: bytes) -> int:
        crc = 0x00
        for byte in data:
            crc ^= byte
            for _ in range(8):
                if crc & 0x80:
                    crc = ((crc << 1) ^ 0x07) & 0xFF
                else:
                    crc = (crc << 1) & 0xFF
        return crc


# Dynamic loading helpers

def load_module_from_file(path: Path, module_name: str) -> ModuleType:
    spec = importlib.util.spec_from_file_location(module_name, path)
    if spec is None or spec.loader is None:
        raise ImportError(f"Could not load module spec for {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    spec.loader.exec_module(module)
    return module


def script_dir() -> Path:
    return Path(__file__).resolve().parent


# Adapter for existing PS-drawn educational scenes 1-4

class PsEducationalSceneAdapter:
    def __init__(
        self,
        *,
        key: str,
        title: str,
        module: ModuleType,
        state_cls_name: str,
        renderer_cls_name: str,
        scene_number: int,
        width: int,
        height: int,
        swap_rb: bool,
        fade_seconds: float,
        iterations: Optional[int] = None,
    ) -> None:
        self.key = key
        self.title = title
        self.module = module
        self.scene_number = scene_number
        self.transition_request: Optional[str] = None
        self.quit_requested = False

        state_cls = getattr(module, state_cls_name)
        renderer_cls = getattr(module, renderer_cls_name)

        if iterations is None:
            self.state = state_cls()
        else:
            # Scene 1-4 state classes all accept max_iter as a dataclass field.
            self.state = state_cls(max_iter=iterations)

        self.renderer = renderer_cls(width, height, swap_rb=swap_rb, fade_s=fade_seconds)
        self.state.intro_fade_start = time.monotonic()
        self.state.dirty = True

    def on_enter(self) -> None:
        self.transition_request = None
        self.quit_requested = False
        self.state.dirty = True
        if hasattr(self.state, "intro_fade_start"):
            self.state.intro_fade_start = time.monotonic() - getattr(self.renderer, "fade_s", 0.55)

    def clear_transition(self) -> None:
        self.transition_request = None

    def handle_app_event(self, event: AppEvent) -> None:
        before = self._transition_snapshot()
        for scene_event in self._to_scene_events(event):
            running = self.module.handle_event(self.state, scene_event, time.monotonic(), self.renderer.fade_s)
            if not running:
                self.quit_requested = True
                return
        self._detect_transition(event, before)

    def update(self, now: float) -> None:
        self.module.update_scene(self.state, now)

    def wants_redraw(self, now: float) -> bool:
        return bool(getattr(self.state, "dirty", False)) or self.renderer.intro_animating(self.state, now)

    def draw_packed(self, now: float) -> np.ndarray:
        packed = self.renderer.draw(self.state, now)
        self.state.dirty = False
        return packed

    def _transition_snapshot(self) -> dict[str, object]:
        phase_name = getattr(getattr(self.state, "phase", None), "name", None)
        return {
            "phase": phase_name,
            "intro_index": getattr(self.state, "intro_index", None),
            "intro_progress": getattr(self.state, "intro_progress", None),
            "step_index": getattr(self.state, "step_index", None),
            "view_index": getattr(self.state, "view_index", None),
        }

    def _detect_transition(self, event: AppEvent, before: dict[str, object]) -> None:
        if event.kind is AppEventKind.MENU:
            # The menu exists only after the walkthrough has introduced it.  Until
            # then we keep the local scene response rather than jumping there.
            return

        if event.kind is AppEventKind.BACK:
            at_first_intro_item = (
                before.get("phase") == "INTRO"
                and before.get("intro_index") == 0
                and before.get("intro_progress") == 1
            )
            if at_first_intro_item:
                self.transition_request = "back"
            return

        if event.kind is not AppEventKind.NEXT:
            return

        if before.get("phase") != "INTERACTIVE":
            return

        # Scene-specific end conditions
        if self.scene_number == 1:
            if before.get("step_index") == 1:
                self.transition_request = "next"
        elif self.scene_number in (2, 3):
            self.transition_request = "next"
        elif self.scene_number == 4:
            if before.get("view_index") == 2:
                self.transition_request = "next"

    def _to_scene_events(self, event: AppEvent) -> list[object]:
        ek = self.module.EventKind
        ev = self.module.Event

        if event.kind is AppEventKind.QUIT:
            return [ev(ek.QUIT)]
        if event.kind is AppEventKind.NEXT:
            return [ev(ek.NEXT)]
        if event.kind is AppEventKind.BACK:
            return [ev(ek.BACK)]
        if event.kind is AppEventKind.ACTION:
            return [ev(ek.SCENE_ACTION)]
        if event.kind is AppEventKind.MENU:
            return [ev(ek.MENU_TOGGLE)]
        if event.kind is AppEventKind.RESET:
            return [ev(ek.RESET)]
        if event.kind is AppEventKind.PALETTE:
            return [ev(ek.PALETTE_CYCLE)]
        if event.kind is AppEventKind.FUNCTION:
            return [ev(ek.FUNCTION)]
        if event.kind is AppEventKind.ZOOM:
            return [ev(ek.ENC1_DELTA, int(event.value or 0))]
        if event.kind is AppEventKind.ITER:
            return [ev(ek.ENC2_DELTA, int(event.value or 0))]
        if event.kind is AppEventKind.PAN:
            dx, dy = event.value or (0, 0)
            out = []
            if dx < 0:
                out.append(ev(ek.JOY_LEFT))
            elif dx > 0:
                out.append(ev(ek.JOY_RIGHT))
            if dy > 0:
                out.append(ev(ek.JOY_UP))
            elif dy < 0:
                out.append(ev(ek.JOY_DOWN))
            return out
        return []


# Temporary PS placeholder for PL scenes 5-6
class PlaceholderPlSceneAdapter:
    def __init__(self, *, key: str, title: str, summary: str, width: int, height: int, swap_rb: bool) -> None:
        self.key = key
        self.title = title
        self.summary = summary
        self.width = width
        self.height = height
        self.swap_rb = swap_rb
        self.transition_request: Optional[str] = None
        self.quit_requested = False
        self.dirty = True
        self.last_message = "Adapter stub ready"

    def on_enter(self) -> None:
        self.transition_request = None
        self.quit_requested = False
        self.dirty = True

    def clear_transition(self) -> None:
        self.transition_request = None

    def handle_app_event(self, event: AppEvent) -> None:
        if event.kind is AppEventKind.QUIT:
            self.quit_requested = True
        elif event.kind is AppEventKind.NEXT:
            self.transition_request = "next"
        elif event.kind is AppEventKind.BACK:
            self.transition_request = "back"
        elif event.kind is AppEventKind.MENU:
            self.transition_request = "menu"
        elif event.kind is AppEventKind.RESET:
            self.last_message = "Stub reset"
            self.dirty = True
        else:
            self.last_message = "PL adapter will consume this control after integration"
            self.dirty = True

    def update(self, now: float) -> None:
        return None

    def wants_redraw(self, now: float) -> bool:
        return self.dirty

    def draw_packed(self, now: float) -> np.ndarray:
        rgb = draw_placeholder_rgb(self.width, self.height, self.title, self.summary, self.last_message)
        self.dirty = False
        return pack_rgb(rgb, swap_rb=self.swap_rb)



# Adapters for PL-rendered scenes 5-6

class Scene5PlAdapter:
    """Scene-manager adapter for scenes/scene5.py using the shared PL backend."""

    def __init__(self, *, module: ModuleType, backend: PlWalkthroughBackend, fade_seconds: float) -> None:
        self.key = "scene5"
        self.title = "Full Mandelbrot exploration"
        self.module = module
        self.backend = backend
        self.scene = module.Scene5Mandelbrot(fade_s=fade_seconds)
        self.state = self.scene.state
        self.intro_renderer = module.Scene5IntroRenderer(fade_s=fade_seconds)
        self.transition_request: Optional[str] = None
        self.quit_requested = False
        self.refine_queue: list[int] = []
        self.last_input_time = time.time()
        self.was_interactive = self.state.phase is module.AppPhase.INTERACTIVE

    def on_enter(self) -> None:
        self.transition_request = None
        self.quit_requested = False
        self.refine_queue.clear()
        self.last_input_time = time.time()
        self.was_interactive = self.state.phase is self.module.AppPhase.INTERACTIVE
        self.state.transition_request = None
        self.state.dirty = True
        print("Scene 5 uses Scene 6-style intro slides, then the shared PL backend for Mandelbrot rendering.")

    def clear_transition(self) -> None:
        self.transition_request = None
        self.state.transition_request = None

    def handle_app_event(self, event: AppEvent) -> None:
        for scene_event in self._to_scene_events(event):
            self.scene.handle_event(scene_event)
        self.quit_requested = bool(self.state.quit_requested)
        self.transition_request = self.state.transition_request

        if event.kind not in (AppEventKind.QUIT,):
            self.last_input_time = time.time()
            self.refine_queue.clear()

    def update(self, now: float) -> None:
        self.quit_requested = bool(self.state.quit_requested)
        self.transition_request = self.state.transition_request
        if self.transition_request is not None or self.quit_requested:
            return

        is_interactive = self.state.phase is self.module.AppPhase.INTERACTIVE
        just_entered_interactive = is_interactive and not self.was_interactive
        self.was_interactive = is_interactive

        if self.state.phase is self.module.AppPhase.INTRO:
            if self.state.dirty or self.intro_renderer.animating(self.state, now):
                self.backend.show_ps_frame(self.intro_renderer.draw(self.state, now))
                self.state.dirty = False
            return

        if self.state.dirty or just_entered_interactive:
            if just_entered_interactive and not self.backend.args.no_initial_render:
                scales = self.backend.scales
                label = "initial render"
            else:
                scales = self.backend.interaction_scales
                label = "preview"

            self.backend.render_mandelbrot(
                self.state,
                scales=scales,
                draw_overlay=self.state.hud_visible and self.backend.args.hud_during_interaction,
                hud_callback=self.module.draw_hud,
                label=label,
            )
            self.state.dirty = False
            self.refine_queue = [] if scales == self.backend.scales else list(self.backend.refine_scales)
            return

        if self.refine_queue and (time.time() - self.last_input_time) >= self.backend.args.refine_idle_s:
            scale = self.refine_queue.pop(0)
            final_refine_pass = not self.refine_queue
            self.backend.render_mandelbrot(
                self.state,
                scales=(scale,),
                draw_overlay=self.state.hud_visible and final_refine_pass,
                hud_callback=self.module.draw_hud,
                label=f"refine x{scale}",
            )

    def wants_redraw(self, now: float) -> bool:
        # PL scenes commit directly to the shared backend from update().
        return False

    def draw_packed(self, now: float) -> np.ndarray:
        if self.state.phase is self.module.AppPhase.INTRO:
            return self.intro_renderer.draw(self.state, now)
        rgb = draw_placeholder_rgb(WIDTH, HEIGHT, self.title, "PL Mandelbrot scene renders directly through the shared backend.", self.state.last_message)
        return pack_rgb(rgb)

    def _to_scene_events(self, event: AppEvent) -> list[object]:
        ek = self.module.EventKind
        ev = self.module.Event
        if event.kind is AppEventKind.QUIT:
            return [ev(ek.QUIT)]
        if event.kind is AppEventKind.NEXT:
            return [ev(ek.NEXT)]
        if event.kind is AppEventKind.BACK:
            return [ev(ek.BACK)]
        if event.kind is AppEventKind.ACTION:
            return [ev(ek.TOGGLE_HUD)]
        if event.kind is AppEventKind.MENU:
            return [ev(ek.MENU)]
        if event.kind is AppEventKind.RESET:
            return [ev(ek.RESET)]
        if event.kind is AppEventKind.PALETTE:
            return [ev(ek.CYCLE_PALETTE)]
        if event.kind is AppEventKind.FUNCTION:
            return [ev(ek.TOGGLE_FINE)]
        if event.kind is AppEventKind.ZOOM:
            return [ev(ek.ZOOM, int(event.value or 0))]
        if event.kind is AppEventKind.ITER:
            return [ev(ek.ITER, int(event.value or 0))]
        if event.kind is AppEventKind.PAN:
            return [ev(ek.PAN, event.value)]
        return []


class Scene6PlAdapter:
    """Scene-manager adapter for scenes/scene6.py using the shared PL backend."""

    def __init__(self, *, module: ModuleType, backend: PlWalkthroughBackend, fade_seconds: float) -> None:
        self.key = "scene6"
        self.title = "Mandelbrot to Julia link"
        self.module = module
        self.backend = backend
        self.scene = module.SceneJuliaLink(fade_s=fade_seconds)
        self.state = self.scene.state
        self.intro_renderer = module.JuliaIntroRenderer(fade_s=fade_seconds)
        self.transition_request: Optional[str] = None
        self.quit_requested = False
        self.refine_queue: list[int] = []
        self.last_input_time = time.time()
        self.was_interactive = self.state.phase is module.AppPhase.INTERACTIVE

    def on_enter(self) -> None:
        self.transition_request = None
        self.quit_requested = False
        self.refine_queue.clear()
        self.last_input_time = time.time()
        self.was_interactive = self.state.phase is self.module.AppPhase.INTERACTIVE
        self.state.transition_request = None
        self.state.dirty = True
        print("Scene 6 uses the shared PL backend and Scene 6 v3's fixed-display intro/render path.")

    def clear_transition(self) -> None:
        self.transition_request = None
        self.state.transition_request = None

    def handle_app_event(self, event: AppEvent) -> None:
        for scene_event in self._to_scene_events(event):
            self.scene.handle_event(scene_event)
        self.quit_requested = bool(self.state.quit_requested)
        self.transition_request = self.state.transition_request

        if event.kind not in (AppEventKind.QUIT,):
            self.last_input_time = time.time()
            self.refine_queue.clear()

    def update(self, now: float) -> None:
        self.quit_requested = bool(self.state.quit_requested)
        self.transition_request = self.state.transition_request
        if self.transition_request is not None or self.quit_requested:
            return

        is_interactive = self.state.phase is self.module.AppPhase.INTERACTIVE
        just_entered_interactive = is_interactive and not self.was_interactive
        self.was_interactive = is_interactive

        if self.state.phase is self.module.AppPhase.INTRO:
            if self.state.dirty or self.intro_renderer.animating(self.state, now):
                self.backend.show_ps_frame(self.intro_renderer.draw(self.state, now))
                self.state.dirty = False
            return

        if self.state.dirty or just_entered_interactive:
            if just_entered_interactive and not self.backend.args.no_initial_render:
                scales = self.backend.scales
                label = "initial render"
            else:
                scales = self.backend.interaction_scales
                label = "preview"

            self.backend.render_julia_link(
                self.state,
                scales=scales,
                draw_overlay=self.state.hud_visible and self.backend.args.hud_during_interaction,
                hud_callback=self.module.draw_hud,
                label=label,
            )
            self.state.dirty = False
            self.refine_queue = [] if scales == self.backend.scales else list(self.backend.refine_scales)
            return

        if self.refine_queue and (time.time() - self.last_input_time) >= self.backend.args.refine_idle_s:
            scale = self.refine_queue.pop(0)
            final_refine_pass = not self.refine_queue
            self.backend.render_julia_link(
                self.state,
                scales=(scale,),
                draw_overlay=self.state.hud_visible and final_refine_pass,
                hud_callback=self.module.draw_hud,
                label=f"refine x{scale}",
            )

    def wants_redraw(self, now: float) -> bool:
        return False

    def draw_packed(self, now: float) -> np.ndarray:
        if self.state.phase is self.module.AppPhase.INTRO:
            return self.intro_renderer.draw(self.state, now)
        rgb = draw_placeholder_rgb(WIDTH, HEIGHT, self.title, "PL Julia scene renders directly through the shared backend.", self.state.last_message)
        return pack_rgb(rgb)

    def _to_scene_events(self, event: AppEvent) -> list[object]:
        ek = self.module.EventKind
        ev = self.module.Event
        if event.kind is AppEventKind.QUIT:
            return [ev(ek.QUIT)]
        if event.kind is AppEventKind.NEXT:
            return [ev(ek.NEXT)]
        if event.kind is AppEventKind.BACK:
            return [ev(ek.BACK)]
        if event.kind is AppEventKind.ACTION:
            return [ev(ek.TOGGLE_HUD)]
        if event.kind is AppEventKind.MENU:
            return [ev(ek.MENU)]
        if event.kind is AppEventKind.RESET:
            return [ev(ek.RESET)]
        if event.kind is AppEventKind.PALETTE:
            return [ev(ek.CYCLE_PALETTE)]
        if event.kind is AppEventKind.FUNCTION:
            return [ev(ek.TOGGLE_FINE)]
        if event.kind is AppEventKind.ZOOM:
            return [ev(ek.ZOOM, int(event.value or 0))]
        if event.kind is AppEventKind.ITER:
            return [ev(ek.ITER, int(event.value or 0))]
        if event.kind is AppEventKind.PAN:
            return [ev(ek.PAN, event.value)]
        return []


# Adapter for menu-launched free-roam PL fractal scenes

class FreeRoamPlAdapter:
    """Menu-launched PL free-roam adapter for Mandelbrot-family modes."""

    def __init__(
        self,
        *,
        module: ModuleType,
        backend: PlWalkthroughBackend,
        key: str,
        preset_key: str,
    ) -> None:
        self.key = key
        self.module = module
        self.backend = backend
        self.state = module.make_state(preset_key)
        self.scene = module.SceneFreeRoam(self.state, preset_key=preset_key)
        self.title = f"Free roam: {self.state.title}"
        self.transition_request: Optional[str] = None
        self.quit_requested = False
        self.refine_queue: list[int] = []
        self.last_input_time = time.time()
        self.did_initial_render = False

    def on_enter(self) -> None:
        self.transition_request = None
        self.quit_requested = False
        self.refine_queue.clear()
        self.last_input_time = time.time()
        self.state.transition_request = None
        self.state.quit_requested = False
        self.state.dirty = True
        self.did_initial_render = False
        print(f"Free-roam scene launched: {self.state.title}")

    def clear_transition(self) -> None:
        self.transition_request = None
        self.state.transition_request = None

    def handle_app_event(self, event: AppEvent) -> None:
        for scene_event in self._to_scene_events(event):
            self.scene.handle_event(scene_event)
        self.quit_requested = bool(self.state.quit_requested)
        self.transition_request = self.state.transition_request

        if event.kind not in (AppEventKind.QUIT,):
            self.last_input_time = time.time()
            self.refine_queue.clear()

    def update(self, now: float) -> None:
        self.quit_requested = bool(self.state.quit_requested)
        self.transition_request = self.state.transition_request
        if self.transition_request is not None or self.quit_requested:
            return

        if self.state.dirty:
            if not self.did_initial_render and not self.backend.args.no_initial_render:
                scales = self.backend.scales
                label = "initial render"
            else:
                scales = self.backend.interaction_scales
                label = "preview"

            self.backend.render_fractal(
                state=self.state,
                mode=self.state.mode,
                scales=scales,
                draw_overlay=self.state.hud_visible and self.backend.args.hud_during_interaction,
                hud_callback=self.module.draw_hud,
                label=f"{self.state.title} {label}",
            )
            self.state.dirty = False
            self.did_initial_render = True
            self.refine_queue = [] if scales == self.backend.scales else list(self.backend.refine_scales)
            return

        if self.refine_queue and (time.time() - self.last_input_time) >= self.backend.args.refine_idle_s:
            scale = self.refine_queue.pop(0)
            final_refine_pass = not self.refine_queue
            self.backend.render_fractal(
                state=self.state,
                mode=self.state.mode,
                scales=(scale,),
                draw_overlay=self.state.hud_visible and final_refine_pass,
                hud_callback=self.module.draw_hud,
                label=f"{self.state.title} refine x{scale}",
            )

    def wants_redraw(self, now: float) -> bool:
        # Free-roam scenes commit directly to the shared backend from update().
        return False

    def draw_packed(self, now: float) -> np.ndarray:
        rgb = draw_placeholder_rgb(
            WIDTH,
            HEIGHT,
            self.title,
            "This free-roam scene renders directly through the shared PL backend at runtime.",
            self.state.last_message,
        )
        return pack_rgb(rgb)

    def _to_scene_events(self, event: AppEvent) -> list[object]:
        ek = self.module.EventKind
        ev = self.module.Event
        if event.kind is AppEventKind.QUIT:
            return [ev(ek.QUIT)]
        if event.kind is AppEventKind.NEXT:
            return [ev(ek.NEXT)]
        if event.kind is AppEventKind.BACK:
            return [ev(ek.BACK)]
        if event.kind is AppEventKind.ACTION:
            return [ev(ek.ACTION)]
        if event.kind is AppEventKind.MENU:
            return [ev(ek.MENU)]
        if event.kind is AppEventKind.RESET:
            return [ev(ek.RESET)]
        if event.kind is AppEventKind.PALETTE:
            return [ev(ek.PALETTE)]
        if event.kind is AppEventKind.FUNCTION:
            return [ev(ek.FUNCTION)]
        if event.kind is AppEventKind.ZOOM:
            return [ev(ek.ZOOM, int(event.value or 0))]
        if event.kind is AppEventKind.ITER:
            return [ev(ek.ITER, int(event.value or 0))]
        if event.kind is AppEventKind.PAN:
            return [ev(ek.PAN, event.value)]
        return []


# Adapter for menu-launched CPU vs hardware comparison

@dataclass
class CpuHardwareComparison:
    fractal_set: str
    cpu_result: CpuRenderResult
    pl_result: dict[str, int | float]
    pl_elapsed_s: float
    pl_pixels_per_second: float
    throughput_speedup: float
    pl_scales: tuple[int, ...]


class CpuVsHardwareAdapter:
    """Menu-launched comparison between the PS CPU baseline and the PL renderer."""

    SET_ORDER = ("mandelbrot", "julia", "burning_ship", "tricorn")
    SET_LABELS = {
        "mandelbrot": "Mandelbrot",
        "julia": "Julia",
        "burning_ship": "Burning Ship",
        "tricorn": "Tricorn",
    }
    MODE_BY_SET = {
        "mandelbrot": MODE_MANDEL,
        "julia": MODE_JULIA,
        "burning_ship": MODE_BURNING,
        "tricorn": MODE_TRICORN,
    }

    CPU_PREVIEW_HOLD_S = 1.25
    PL_PREVIEW_HOLD_S = 1.50

    def __init__(self, *, backend: PlWalkthroughBackend, args: argparse.Namespace, width: int, height: int, swap_rb: bool) -> None:
        self.key = "cpu_vs_hardware"
        self.title = "CPU vs Hardware"
        self.backend = backend
        self.args = args
        self.width = width
        self.height = height
        self.swap_rb = swap_rb
        self.transition_request: Optional[str] = None
        self.quit_requested = False
        self.dirty = True
        self.pending_run = False
        self.phase = "intro"
        self.message = "Press N to run a CPU baseline and PL comparison."
        self.error_message = ""
        default_set = str(getattr(args, "cpu_set", "mandelbrot")).strip().lower().replace("-", "_")
        self.set_index = self.SET_ORDER.index(default_set) if default_set in self.SET_ORDER else 0
        self.last_comparison: Optional[CpuHardwareComparison] = None
        self.last_cpu_hdmi_rgb: Optional[np.ndarray] = None

    @property
    def current_set(self) -> str:
        return self.SET_ORDER[self.set_index]

    @property
    def current_set_label(self) -> str:
        return self.SET_LABELS[self.current_set]

    def on_enter(self) -> None:
        self.transition_request = None
        self.quit_requested = False
        self.pending_run = False
        self.phase = "intro" if self.last_comparison is None else "done"
        self.message = "Press N to run comparison. F cycles fractal set. B/M returns to menu."
        self.dirty = True
        print("CPU vs Hardware comparison scene ready.")

    def clear_transition(self) -> None:
        self.transition_request = None

    def handle_app_event(self, event: AppEvent) -> None:
        if event.kind is AppEventKind.QUIT:
            self.quit_requested = True
            return
        if event.kind in (AppEventKind.BACK, AppEventKind.MENU):
            self.transition_request = "menu"
            return
        if event.kind in (AppEventKind.NEXT, AppEventKind.ACTION, AppEventKind.RESET):
            self.pending_run = True
            self.phase = "running"
            self.message = f"Running {self.current_set_label} comparison..."
            self.error_message = ""
            self.dirty = True
            return
        if event.kind is AppEventKind.FUNCTION:
            self.set_index = (self.set_index + 1) % len(self.SET_ORDER)
            self.last_comparison = None
            self.last_cpu_hdmi_rgb = None
            self.phase = "intro"
            self.message = f"Selected {self.current_set_label}. Press N to run."
            self.dirty = True
            return
        if event.kind is AppEventKind.ITER:
            delta = int(event.value or 0)
            if delta:
                old_iter = int(getattr(self.args, "cpu_max_iter", 256))
                new_iter = max(32, min(2048, old_iter + 32 * delta))
                setattr(self.args, "cpu_max_iter", new_iter)
                self.last_comparison = None
                self.message = f"CPU/PL max_iter set to {new_iter}. Press N to run."
                self.phase = "intro"
                self.dirty = True
            return
        if event.kind is AppEventKind.ZOOM:
            delta = int(event.value or 0)
            if delta:
                old_width = float(getattr(self.args, "cpu_x_width", 3.5))
                factor = 0.80 if delta > 0 else 1.25
                setattr(self.args, "cpu_x_width", max(1e-6, old_width * factor))
                self.last_comparison = None
                self.message = f"View width set to {float(getattr(self.args, 'cpu_x_width')):.6g}. Press N to run."
                self.phase = "intro"
                self.dirty = True
            return
        if event.kind is AppEventKind.PAN:
            dx, dy = event.value or (0, 0)
            x_width = float(getattr(self.args, "cpu_x_width", 3.5))
            step = 0.08 * x_width
            setattr(self.args, "cpu_center_x", float(getattr(self.args, "cpu_center_x", -0.5)) + float(dx) * step)
            setattr(self.args, "cpu_center_y", float(getattr(self.args, "cpu_center_y", 0.0)) - float(dy) * step)
            self.last_comparison = None
            self.message = (
                f"Centre=({float(getattr(self.args, 'cpu_center_x')):+.4f}, "
                f"{float(getattr(self.args, 'cpu_center_y')):+.4f}). Press N to run."
            )
            self.phase = "intro"
            self.dirty = True
            return

    def update(self, now: float) -> None:
        if not self.pending_run:
            return

        self.pending_run = False
        self.phase = "running"
        self.message = f"Running {self.current_set_label}: CPU first, then PL..."
        self.backend.show_packed_frame(self.draw_packed(now))

        try:
            self._run_comparison()
            self.phase = "done"
            self.message = "Comparison complete. N/R reruns, F cycles set, B/M returns to menu."
        except Exception as exc:
            self.phase = "error"
            self.error_message = str(exc)
            self.message = "Comparison failed. Check terminal output, then press N to retry."
            print(f"CPU vs Hardware comparison failed: {exc}")
        self.dirty = True

    def wants_redraw(self, now: float) -> bool:
        return self.dirty

    def draw_packed(self, now: float) -> np.ndarray:
        rgb = self._draw_rgb(now)
        self.dirty = False
        return pack_rgb(rgb, swap_rb=self.swap_rb)

    def _run_comparison(self) -> None:
        cfg = make_temp_output_config(self._make_cpu_config(), prefix="fractalscope_cpu_menu_")
        cpu_dir = Path(getattr(self.args, "cpu_dir", "./cpu_baseline")).expanduser().resolve()
        binary_arg = str(getattr(self.args, "cpu_binary", ""))
        binary_path = Path(binary_arg).expanduser().resolve() if binary_arg else None

        cpu_result = render_cpu_frame(
            cpu_dir,
            cfg,
            binary_path=binary_path,
            build=not bool(getattr(self.args, "cpu_no_compile", False)),
            force_build=bool(getattr(self.args, "cpu_force_compile", False)),
            verbose=True,
            timeout_s=float(getattr(self.args, "cpu_timeout_s", 120.0)),
        )
        print("CPU comparison result:")
        print("  " + format_cpu_stats(cpu_result))

        self.last_cpu_hdmi_rgb = resize_rgb_nearest(cpu_result.rgb, self.width, self.height)
        cpu_preview = self._draw_cpu_preview_rgb(cpu_result)
        self.backend.show_packed_frame(pack_rgb(cpu_preview, swap_rb=self.swap_rb))
        time.sleep(self.CPU_PREVIEW_HOLD_S)

        pl_state = self._make_pl_state(cfg)
        pl_scales = self._parse_scales(str(getattr(self.args, "cpu_pl_scales", "1")))
        pl_start = time.time()
        pl_result = self.backend.render_fractal(
            state=pl_state,
            mode=self.MODE_BY_SET[self.current_set],
            scales=pl_scales,
            draw_overlay=False,
            hud_callback=None,
            label=f"CPU comparison {self.current_set_label}",
        )
        pl_elapsed = max(time.time() - pl_start, 1e-9)
        time.sleep(self.PL_PREVIEW_HOLD_S)
        pl_pixels = max(0, int(pl_result.get("written", 0)))
        pl_pps = float(pl_pixels) / pl_elapsed if pl_elapsed > 0 else 0.0
        cpu_pps = max(float(cpu_result.pixels_per_second), 0.0)
        speedup = pl_pps / cpu_pps if cpu_pps > 0.0 else 0.0

        self.last_comparison = CpuHardwareComparison(
            fractal_set=self.current_set,
            cpu_result=cpu_result,
            pl_result=pl_result,
            pl_elapsed_s=pl_elapsed,
            pl_pixels_per_second=pl_pps,
            throughput_speedup=speedup,
            pl_scales=pl_scales,
        )

    def _make_cpu_config(self) -> CpuRenderConfig:
        return CpuRenderConfig(
            fractal_set=self.current_set,
            width=int(getattr(self.args, "cpu_width", 320)),
            height=int(getattr(self.args, "cpu_height", 180)),
            max_iter=int(getattr(self.args, "cpu_max_iter", 256)),
            threads=int(getattr(self.args, "cpu_threads", 2)),
            center_x=float(getattr(self.args, "cpu_center_x", -0.5)),
            center_y=float(getattr(self.args, "cpu_center_y", 0.0)),
            x_width=float(getattr(self.args, "cpu_x_width", 3.5)),
            julia_real=float(getattr(self.args, "cpu_julia_real", -0.8)),
            julia_imag=float(getattr(self.args, "cpu_julia_imag", 0.156)),
        )

    def _make_pl_state(self, cfg: CpuRenderConfig) -> object:
        return SimpleNamespace(
            center_r=cfg.center_x,
            center_i=cfg.center_y,
            x_width=cfg.x_width,
            max_iter=cfg.max_iter,
            julia_c_r=cfg.julia_real,
            julia_c_i=cfg.julia_imag,
            palette_index=0,
            hud_visible=False,
            dirty=False,
            render_count=0,
            last_render_s=0.0,
            last_written=0,
            last_errors=0,
        )

    @staticmethod
    def _parse_scales(text: str) -> tuple[int, ...]:
        values = []
        for part in str(text).split(","):
            part = part.strip()
            if not part:
                continue
            value = int(part)
            if value <= 0:
                raise ValueError("PL comparison scales must be positive")
            values.append(value)
        return tuple(values) if values else (1,)

    def _draw_rgb(self, now: float) -> np.ndarray:
        if self.phase == "done" and self.last_comparison is not None:
            return self._draw_done_rgb(self.last_comparison)
        if self.phase == "error":
            return self._draw_status_rgb("CPU vs Hardware", self.message, self.error_message, accent=(255, 120, 90))
        if self.phase == "running":
            return self._draw_status_rgb("CPU vs Hardware", self.message, "This blocks briefly while the CPU and PL renderers run.")
        cfg = self._make_cpu_config()
        details = (
            f"Set: {self.current_set_label}\n"
            f"CPU: {cfg.width}x{cfg.height}, {cfg.threads} thread(s)\n"
            f"PL: 1280x720, scales {getattr(self.args, 'cpu_pl_scales', '1')}\n"
            f"View: centre=({cfg.center_x:+.4f}, {cfg.center_y:+.4f}), width={cfg.x_width:.6g}\n"
            f"Max iter: {cfg.max_iter}"
        )
        return self._draw_status_rgb("CPU vs Hardware", self.message, details)

    def _draw_status_rgb(self, title: str, message: str, details: str, *, accent=(80, 230, 230)) -> np.ndarray:
        from PIL import Image, ImageDraw, ImageFont

        img = Image.new("RGB", (self.width, self.height), (7, 9, 13))
        draw = ImageDraw.Draw(img)
        self._draw_background_grid(draw)
        f_title = self._font(52, bold=True)
        f_body = self._font(28)
        f_small = self._font(21)
        f_tiny = self._font(17)

        self._draw_centred(draw, 78, title, f_title, accent)
        draw.rounded_rectangle((150, 175, self.width - 150, 535), radius=28, fill=(13, 18, 28), outline=(34, 58, 70), width=2)
        self._draw_centred(draw, 220, message, f_body, (242, 244, 247))

        y = 285
        for line in str(details).splitlines():
            self._draw_centred(draw, y, line, f_small, (185, 196, 208))
            y += 34

        self._draw_centred(draw, 645, "N/R run   F cycle set   WASD pan   [ ] zoom   - = iter   B/M menu   Q quit", f_tiny, (166, 174, 184))
        return np.asarray(img, dtype=np.uint8)

    def _draw_cpu_preview_rgb(self, result: CpuRenderResult) -> np.ndarray:
        from PIL import Image, ImageDraw

        bg = Image.fromarray(resize_rgb_nearest(result.rgb, self.width, self.height), mode="RGB").convert("RGB")
        overlay = Image.new("RGBA", (self.width, self.height), (0, 0, 0, 0))
        draw = ImageDraw.Draw(overlay)
        draw.rounded_rectangle((36, 34, self.width - 36, 150), radius=20, fill=(0, 0, 0, 175), outline=(80, 230, 230, 180), width=2)
        draw.text((62, 52), f"CPU baseline rendered: {self.current_set_label}", font=self._font(30, True), fill=(242, 244, 247, 255))
        draw.text(
            (62, 98),
            f"{result.config.width}x{result.config.height}, {result.config.threads} thread(s), "
            f"{result.render_seconds:.4f}s, {result.pixels_per_second/1e6:.2f} Mpix/s. Running PL next...",
            font=self._font(20),
            fill=(190, 205, 215, 255),
        )
        return np.asarray(Image.alpha_composite(bg.convert("RGBA"), overlay).convert("RGB"), dtype=np.uint8)

    def _draw_done_rgb(self, comparison: CpuHardwareComparison) -> np.ndarray:
        from PIL import Image, ImageDraw

        if self.last_cpu_hdmi_rgb is not None:
            img = Image.fromarray(self.last_cpu_hdmi_rgb, mode="RGB").convert("RGBA")
            shade = Image.new("RGBA", (self.width, self.height), (0, 0, 0, 145))
            img = Image.alpha_composite(img, shade)
        else:
            img = Image.new("RGBA", (self.width, self.height), (7, 9, 13, 255))
        draw = ImageDraw.Draw(img)

        f_title = self._font(44, True)
        f_head = self._font(27, True)
        f_body = self._font(22)
        f_small = self._font(17)
        accent = (80, 230, 230, 255)
        white = (242, 244, 247, 255)
        dim = (188, 198, 208, 255)

        draw.rounded_rectangle((44, 34, self.width - 44, 686), radius=26, fill=(8, 12, 18, 218), outline=(44, 80, 92, 255), width=2)
        draw.text((76, 58), "CPU vs Hardware comparison", font=f_title, fill=accent)
        draw.text((78, 115), f"Fractal: {self.SET_LABELS[comparison.fractal_set]}", font=f_body, fill=white)

        cpu = comparison.cpu_result
        cpu_pixels = cpu.config.width * cpu.config.height
        pl_written = int(comparison.pl_result.get("written", 0))

        left = 88
        mid = 665
        top = 180
        panel_h = 260
        draw.rounded_rectangle((left, top, 600, top + panel_h), radius=20, fill=(15, 22, 32, 235), outline=(35, 60, 72, 255), width=2)
        draw.rounded_rectangle((mid, top, self.width - 88, top + panel_h), radius=20, fill=(15, 22, 32, 235), outline=(35, 60, 72, 255), width=2)

        draw.text((left + 28, top + 24), "CPU baseline", font=f_head, fill=white)
        cpu_lines = [
            f"Resolution: {cpu.config.width} x {cpu.config.height}",
            f"Pixels: {cpu_pixels:,}",
            f"Threads: {cpu.config.threads}",
            f"Render time: {cpu.render_seconds:.4f} s",
            f"Throughput: {cpu.pixels_per_second/1e6:.2f} Mpix/s",
        ]
        y = top + 72
        for line in cpu_lines:
            draw.text((left + 28, y), line, font=f_body, fill=dim)
            y += 34

        draw.text((mid + 28, top + 24), "FPGA / PL pipeline", font=f_head, fill=white)
        pl_lines = [
            "Resolution: 1280 x 720 display path",
            f"Pixels written: {pl_written:,}",
            f"Scales: {','.join(str(v) for v in comparison.pl_scales)}",
            f"Render time: {comparison.pl_elapsed_s:.4f} s",
            f"Throughput: {comparison.pl_pixels_per_second/1e6:.2f} Mpix/s",
        ]
        y = top + 72
        for line in pl_lines:
            draw.text((mid + 28, y), line, font=f_body, fill=dim)
            y += 34

        bar_top = 500
        draw.text((90, bar_top - 46), "Normalised throughput speedup", font=f_head, fill=white)
        speedup = max(0.0, comparison.throughput_speedup)
        max_bar_speedup = max(1.0, min(100.0, speedup))
        bar_w = 940
        draw.rounded_rectangle((90, bar_top, 90 + bar_w, bar_top + 34), radius=12, fill=(32, 42, 54, 255))
        fill_w = int(bar_w * min(1.0, max_bar_speedup / max(1.0, max_bar_speedup))) if speedup > 0 else 0
        draw.rounded_rectangle((90, bar_top, 90 + fill_w, bar_top + 34), radius=12, fill=(80, 230, 230, 255))
        draw.text((1060, bar_top - 4), f"{speedup:.2f}x", font=f_head, fill=accent)

        note = "CPU is rendered at lower resolution for live responsiveness; throughput uses pixels/second."
        draw.text((90, 570), note, font=f_small, fill=(176, 186, 196, 255))
        draw.text((90, 640), "N/R rerun   F cycle set   WASD pan   [ ] zoom   - = iter   B/M menu   Q quit", font=f_small, fill=(166, 174, 184, 255))
        return np.asarray(img.convert("RGB"), dtype=np.uint8)

    def _draw_background_grid(self, draw) -> None:
        for x in range(80, self.width, 160):
            draw.line((x, 0, x - 140, self.height), fill=(10, 14, 21), width=1)

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

    def _draw_centred(self, draw, y: int, text: str, font, fill) -> None:
        bbox = draw.textbbox((0, 0), text, font=font)
        draw.text(((self.width - (bbox[2] - bbox[0])) // 2, y), text, font=font, fill=fill)

# Adapter for loading/title screen

class LoadingScreenAdapter:
    def __init__(self, *, module: ModuleType, width: int, height: int, swap_rb: bool) -> None:
        self.key = "loading"
        self.title = "FractalScope loading screen"
        self.module = module
        self.width = width
        self.height = height
        self.swap_rb = swap_rb
        self.state = module.LoadingScreenState()
        self.scene = module.SceneLoadingScreen(self.state)
        self.renderer = module.LoadingScreenRenderer(width, height)
        self.transition_request: Optional[str] = None
        self.quit_requested = False

    def on_enter(self) -> None:
        self.transition_request = None
        self.quit_requested = False
        self.state.transition_request = None
        self.state.dirty = True

    def clear_transition(self) -> None:
        self.transition_request = None
        self.state.transition_request = None

    def handle_app_event(self, event: AppEvent) -> None:
        loading_event = self._to_loading_event(event)
        if loading_event is None:
            return
        self.scene.handle_event(loading_event)
        self.quit_requested = bool(self.state.quit_requested)
        self.transition_request = self.state.transition_request

    def update(self, now: float) -> None:
        return None

    def wants_redraw(self, now: float) -> bool:
        return bool(self.state.dirty)

    def draw_packed(self, now: float) -> np.ndarray:
        packed = self.renderer.draw_packed(self.state, swap_rb=self.swap_rb)
        self.state.dirty = False
        return packed

    def _to_loading_event(self, event: AppEvent) -> Optional[object]:
        ek = self.module.EventKind
        ev = self.module.Event
        if event.kind is AppEventKind.QUIT:
            return ev(ek.QUIT)
        if event.kind is AppEventKind.PAN and event.value in (None, (0, 0)):
            return None
        return ev(ek.START)


# Adapter for walkthrough summary scene

class SummarySceneAdapter:
    def __init__(self, *, module: ModuleType, width: int, height: int, swap_rb: bool) -> None:
        self.key = "summary"
        self.title = "Guided walkthrough summary"
        self.module = module
        self.width = width
        self.height = height
        self.swap_rb = swap_rb
        self.state = module.SummaryState()
        self.scene = module.SceneSummary(self.state)
        self.renderer = module.SummaryRenderer()
        self.transition_request: Optional[str] = None
        self.quit_requested = False

    def on_enter(self) -> None:
        self.transition_request = None
        self.quit_requested = False
        self.state.transition_request = None
        self.state.dirty = True

    def clear_transition(self) -> None:
        self.transition_request = None
        self.state.transition_request = None

    def handle_app_event(self, event: AppEvent) -> None:
        for summary_event in self._to_summary_events(event):
            self.scene.handle_event(summary_event)
        self.quit_requested = bool(self.state.quit_requested)
        self.transition_request = self.state.transition_request

    def update(self, now: float) -> None:
        return None

    def wants_redraw(self, now: float) -> bool:
        return bool(self.state.dirty)

    def draw_packed(self, now: float) -> np.ndarray:
        packed = self.renderer.draw_packed(self.state, swap_rb=self.swap_rb)
        self.state.dirty = False
        return packed

    def _to_summary_events(self, event: AppEvent) -> list[object]:
        ek = self.module.EventKind
        ev = self.module.Event
        if event.kind is AppEventKind.QUIT:
            return [ev(ek.QUIT)]
        if event.kind is AppEventKind.NEXT or event.kind is AppEventKind.ACTION:
            return [ev(ek.NEXT)]
        if event.kind is AppEventKind.BACK:
            return [ev(ek.BACK)]
        if event.kind is AppEventKind.MENU:
            return [ev(ek.MENU)]
        if event.kind is AppEventKind.RESET:
            return [ev(ek.RESET)]
        if event.kind is AppEventKind.PALETTE:
            return [ev(ek.CYCLE_PALETTE)]
        if event.kind is AppEventKind.PAN:
            return [ev(ek.PAN, event.value)]
        return []


# Adapter for menu scene

class MenuSceneAdapter:
    def __init__(self, *, module: ModuleType, width: int, height: int, swap_rb: bool) -> None:
        self.key = "menu"
        self.title = "Global Menu"
        self.module = module
        self.width = width
        self.height = height
        self.swap_rb = swap_rb
        self.state = module.MenuState()
        self.scene = module.SceneMenu(self.state)
        self.renderer = module.MenuRenderer()
        self.transition_request: Optional[str] = None
        self.quit_requested = False
        self._controller_menu_pan_latch: Optional[tuple[int, int]] = None

    def on_enter(self) -> None:
        self.transition_request = None
        self.quit_requested = False
        self._controller_menu_pan_latch = None
        self.state.dirty = True

    def clear_transition(self) -> None:
        self.transition_request = None
        self.state.transition_request = None

    def handle_app_event(self, event: AppEvent) -> None:
        for menu_event in self._to_menu_events(event):
            self.scene.handle_event(menu_event)
        self.quit_requested = bool(self.state.quit_requested)
        self.transition_request = self.state.transition_request

    def update(self, now: float) -> None:
        return None

    def wants_redraw(self, now: float) -> bool:
        return bool(self.state.dirty)

    def draw_packed(self, now: float) -> np.ndarray:
        packed = self.renderer.draw_packed(self.state, swap_rb=self.swap_rb)
        self.state.dirty = False
        return packed

    def _to_menu_events(self, event: AppEvent) -> list[object]:
        ek = self.module.EventKind
        ev = self.module.Event
        if event.kind is AppEventKind.QUIT:
            return [ev(ek.QUIT)]
        if event.kind is AppEventKind.NEXT or event.kind is AppEventKind.ACTION:
            return [ev(ek.NEXT)]
        if event.kind is AppEventKind.BACK:
            return [ev(ek.BACK)]
        if event.kind is AppEventKind.MENU:
            return [ev(ek.MENU)]
        if event.kind is AppEventKind.RESET:
            return [ev(ek.RESET)]
        if event.kind is AppEventKind.PALETTE:
            return [ev(ek.CYCLE_PALETTE)]
        if event.kind is AppEventKind.FUNCTION:
            return [ev(ek.TOGGLE_FINE)]
        if event.kind is AppEventKind.PAN:
            step = self._menu_pan_step(event.value)
            if event.source == "controller":
                if step is None:
                    self._controller_menu_pan_latch = None
                    return []
                if step == self._controller_menu_pan_latch:
                    return []
                self._controller_menu_pan_latch = step
                return [ev(ek.PAN, step)]
            return [ev(ek.PAN, step)] if step is not None else []
        return []

    @staticmethod
    def _menu_pan_step(value: object) -> Optional[tuple[int, int]]:
        try:
            dx_raw, dy_raw = value or (0, 0)
            dx_f = float(dx_raw)
            dy_f = float(dy_raw)
        except Exception:
            return None

        if abs(dx_f) < 1e-9 and abs(dy_f) < 1e-9:
            return None
        if abs(dx_f) >= abs(dy_f):
            return (1 if dx_f > 0 else -1, 0)
        return (0, 1 if dy_f > 0 else -1)


# Simple drawing helpers for placeholder screens

def pack_rgb(rgb: np.ndarray, *, swap_rb: bool = False) -> np.ndarray:
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


def draw_placeholder_rgb(width: int, height: int, title: str, summary: str, message: str) -> np.ndarray:
    from PIL import Image, ImageDraw, ImageFont

    bg = (7, 9, 13)
    panel = (13, 18, 28)
    accent = (80, 230, 230)
    white = (242, 244, 247)
    dim = (166, 174, 184)

    def font(size: int, bold: bool = False):
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

    img = Image.new("RGB", (width, height), bg)
    draw = ImageDraw.Draw(img)
    for x in range(80, width, 160):
        draw.line((x, 0, x - 140, height), fill=(10, 14, 21), width=1)

    f_title = font(48, bold=True)
    f_body = font(28)
    f_small = font(18)
    f_tiny = font(15)

    def centre(y: int, text: str, f, fill) -> None:
        bbox = draw.textbbox((0, 0), text, font=f)
        draw.text(((width - (bbox[2] - bbox[0])) // 2, y), text, font=f, fill=fill)

    centre(80, title, f_title, accent)
    draw.rounded_rectangle((170, 190, width - 170, 500), radius=28, fill=panel, outline=(34, 58, 70), width=2)

    lines = wrap_text(draw, summary, f_body, width - 430)
    y = 240
    for line in lines[:4]:
        centre(y, line, f_body, white)
        y += 42

    centre(430, "This is a temporary scene-manager placeholder.", f_small, dim)
    centre(462, "Next step: plug in the existing PL hardware adapter for this scene.", f_small, dim)
    centre(596, message, f_small, accent)
    centre(655, "N next   B back   M menu   Q quit", f_tiny, dim)
    return np.asarray(img, dtype=np.uint8)


def wrap_text(draw, text: str, font, max_width: int) -> list[str]:
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


# Scene manager

class SceneManager:
    def __init__(self, scenes: list[SceneAdapter], start_key: str = "scene1") -> None:
        if not scenes:
            raise ValueError("At least one scene is required")
        self.scenes = scenes
        self.index_by_key = {scene.key: idx for idx, scene in enumerate(scenes)}
        if start_key not in self.index_by_key:
            raise ValueError(f"Unknown start scene {start_key!r}; choices: {list(self.index_by_key)}")
        self.active_index = self.index_by_key[start_key]
        self.previous_non_menu_index = self.active_index
        self.active_scene.on_enter()

    @property
    def active_scene(self) -> SceneAdapter:
        return self.scenes[self.active_index]

    def handle_event(self, event: AppEvent) -> None:
        # Global quit always wins.
        if event.kind is AppEventKind.QUIT:
            self.active_scene.handle_app_event(event)
            return

        # The loading screen owns all start buttons, including the menu button,
        # so the title screen always enters Scene 1 rather than jumping to menu.
        if self.active_scene.key == "loading":
            self.active_scene.handle_app_event(event)
            self._consume_transition()
            return

        # Menu is global only once the menu scene exists.  Before then the scene
        # can still show a local status message.
        if event.kind is AppEventKind.MENU and self.active_scene.key != "menu":
            self.previous_non_menu_index = self.active_index
            self._go_to_key("menu")
            return

        self.active_scene.handle_app_event(event)
        self._consume_transition()

    def update(self, now: float) -> None:
        self.active_scene.update(now)
        self._consume_transition()

    def wants_redraw(self, now: float) -> bool:
        return self.active_scene.wants_redraw(now)

    def draw_packed(self, now: float) -> np.ndarray:
        return self.active_scene.draw_packed(now)

    @property
    def quit_requested(self) -> bool:
        return self.active_scene.quit_requested

    def _consume_transition(self) -> None:
        request = self.active_scene.transition_request
        if request is None:
            return
        self.active_scene.clear_transition()

        if self.active_scene.key == "menu":
            self._consume_menu_transition(request)
            return

        if request == "next":
            self._go_relative(+1)
        elif request == "back":
            self._go_relative(-1)
        elif request == "menu":
            self.previous_non_menu_index = self.active_index
            self._go_to_key("menu")
        elif request in self.index_by_key:
            self._go_to_key(request)
        else:
            print(f"Unhandled transition request from {self.active_scene.key}: {request}")

    def _consume_menu_transition(self, request: str) -> None:
        # In the guided walkthrough build, the menu is the endpoint.  It should
        # not route back into the walkthrough Scene 5/6 implementations, because
        # menu-launched fractal exploration will become a separate set of free-
        # exploration adapters later.
        menu_scene = self.active_scene

        if request in ("back", "close_menu", "menu"):
            print("Menu is the walkthrough endpoint in this build; staying on the menu.")
            self._mark_menu_dirty("Menu is the walkthrough endpoint. Use Help or Q to quit.")
            return

        menu_routes = {
            "standard_mandelbrot": "free_mandelbrot",
            "burning_ship": "free_burning_ship",
            "tricorn": "free_tricorn",
        }
        if request in menu_routes:
            self._go_to_key(menu_routes[request])
            return

        if request in ("julia_link_map", "julia_full_image"):
            julia_scene = self.scenes[self.index_by_key["free_julia"]]
            state = getattr(julia_scene, "state", None)
            if state is not None:
                state.julia_control_mode = "c" if request == "julia_link_map" else "view"
                state.last_message = (
                    "Choosing c: WASD moves c, F explores image"
                    if state.julia_control_mode == "c"
                    else "Exploring Julia: WASD pans, F chooses c"
                )
                state.dirty = True
            self._go_to_key("free_julia")
            return

        if request == "cpu_vs_hardware":
            self._go_to_key("cpu_vs_hardware")
            return

        if request in self.index_by_key and request != "menu":
            print(f"Menu requested scene key {request!r}, but walkthrough menu launch is disabled in this build.")
            self._mark_menu_dirty("Scene launch is disabled from the walkthrough endpoint menu.")
            return

        if request == "next":
            self._mark_menu_dirty("Select Help for controls, or press Q in the terminal to quit.")
            return

        print(f"Unhandled menu transition request: {request}")

    def _mark_menu_dirty(self, message: str) -> None:
        scene = self.active_scene
        state = getattr(scene, "state", None)
        if state is not None:
            setattr(state, "last_message", message)
            setattr(state, "dirty", True)

    def _go_relative(self, delta: int) -> None:
        new_index = max(0, min(len(self.scenes) - 1, self.active_index + delta))
        self._go_to_index(new_index)

    def _go_to_key(self, key: str) -> None:
        self._go_to_index(self.index_by_key[key])

    def _go_to_index(self, index: int) -> None:
        index = max(0, min(len(self.scenes) - 1, index))
        if self.active_index != index:
            print(f"\nSwitching to: {self.scenes[index].title}")
        self.active_index = index
        self.active_scene.on_enter()


# Build adapters from the current scene/backend files

def build_scenes(args: argparse.Namespace, backend: Optional[PlWalkthroughBackend] = None) -> list[SceneAdapter]:
    base = Path(args.scene_dir).expanduser().resolve()
    backend_base = Path(args.backend_dir).expanduser().resolve()

    loading = load_module_from_file(base / "loading_screen.py", "fractalscope_loading_screen")
    scene1 = load_module_from_file(base / "scene1.py", "fractalscope_scene1")
    scene2 = load_module_from_file(base / "scene2.py", "fractalscope_scene2")
    scene3 = load_module_from_file(base / "scene3.py", "fractalscope_scene3")
    scene4 = load_module_from_file(base / "scene4.py", "fractalscope_scene4")
    scene5 = load_module_from_file(base / "scene5.py", "fractalscope_scene5")
    scene6 = load_module_from_file(base / "scene6.py", "fractalscope_scene6")
    summary = load_module_from_file(base / "summary.py", "fractalscope_summary")
    menu = load_module_from_file(base / "menu.py", "fractalscope_menu")
    free_roam = load_module_from_file(backend_base / "free_roam_fractals.py", "fractalscope_free_roam")

    if backend is None:
        scene5_adapter: SceneAdapter = PlaceholderPlSceneAdapter(
            key="scene5",
            title="Full Mandelbrot exploration",
            summary="Scene 5 will use the shared PL backend at runtime. Self-test uses this placeholder so it can run off-board without PYNQ.",
            width=args.width,
            height=args.height,
            swap_rb=args.swap_rb,
        )
        scene6_adapter: SceneAdapter = PlaceholderPlSceneAdapter(
            key="scene6",
            title="Mandelbrot to Julia link",
            summary="Scene 6 will use the shared PL backend at runtime. Self-test uses this placeholder so it can run off-board without PYNQ.",
            width=args.width,
            height=args.height,
            swap_rb=args.swap_rb,
        )
    else:
        scene5_adapter = Scene5PlAdapter(module=scene5, backend=backend, fade_seconds=args.fade_seconds)
        scene6_adapter = Scene6PlAdapter(module=scene6, backend=backend, fade_seconds=args.fade_seconds)

    if backend is None:
        free_mandelbrot_adapter: SceneAdapter = PlaceholderPlSceneAdapter(
            key="free_mandelbrot",
            title="Free roam: Standard Mandelbrot",
            summary="Menu-launched Mandelbrot free roam uses the shared PL backend at runtime.",
            width=args.width,
            height=args.height,
            swap_rb=args.swap_rb,
        )
        free_julia_adapter: SceneAdapter = PlaceholderPlSceneAdapter(
            key="free_julia",
            title="Free roam: Julia",
            summary="Menu-launched Julia free roam uses the shared PL backend at runtime.",
            width=args.width,
            height=args.height,
            swap_rb=args.swap_rb,
        )
        free_burning_adapter: SceneAdapter = PlaceholderPlSceneAdapter(
            key="free_burning_ship",
            title="Free roam: Burning Ship",
            summary="Menu-launched Burning Ship free roam uses the shared PL backend at runtime.",
            width=args.width,
            height=args.height,
            swap_rb=args.swap_rb,
        )
        free_tricorn_adapter: SceneAdapter = PlaceholderPlSceneAdapter(
            key="free_tricorn",
            title="Free roam: Tricorn",
            summary="Menu-launched Tricorn free roam uses the shared PL backend at runtime.",
            width=args.width,
            height=args.height,
            swap_rb=args.swap_rb,
        )
    else:
        free_mandelbrot_adapter = FreeRoamPlAdapter(
            module=free_roam,
            backend=backend,
            key="free_mandelbrot",
            preset_key="mandelbrot",
        )
        free_julia_adapter = FreeRoamPlAdapter(
            module=free_roam,
            backend=backend,
            key="free_julia",
            preset_key="julia",
        )
        free_burning_adapter = FreeRoamPlAdapter(
            module=free_roam,
            backend=backend,
            key="free_burning_ship",
            preset_key="burning_ship",
        )
        free_tricorn_adapter = FreeRoamPlAdapter(
            module=free_roam,
            backend=backend,
            key="free_tricorn",
            preset_key="tricorn",
        )

    if backend is None:
        cpu_vs_hardware_adapter: SceneAdapter = PlaceholderPlSceneAdapter(
            key="cpu_vs_hardware",
            title="CPU vs Hardware",
            summary="CPU vs Hardware uses the CPU baseline runner and shared PL backend at runtime.",
            width=args.width,
            height=args.height,
            swap_rb=args.swap_rb,
        )
    else:
        cpu_vs_hardware_adapter = CpuVsHardwareAdapter(
            backend=backend,
            args=args,
            width=args.width,
            height=args.height,
            swap_rb=args.swap_rb,
        )

    return [
        LoadingScreenAdapter(
            module=loading,
            width=args.width,
            height=args.height,
            swap_rb=args.swap_rb,
        ),
        PsEducationalSceneAdapter(
            key="scene1",
            title="Opening recurrence",
            module=scene1,
            state_cls_name="Scene1State",
            renderer_cls_name="Scene1Renderer",
            scene_number=1,
            width=args.width,
            height=args.height,
            swap_rb=args.swap_rb,
            fade_seconds=args.fade_seconds,
            iterations=args.iterations,
        ),
        PsEducationalSceneAdapter(
            key="scene2",
            title="Complex-plane recurrence",
            module=scene2,
            state_cls_name="Scene2State",
            renderer_cls_name="Scene2Renderer",
            scene_number=2,
            width=args.width,
            height=args.height,
            swap_rb=args.swap_rb,
            fade_seconds=args.fade_seconds,
            iterations=max(args.iterations, 18),
        ),
        PsEducationalSceneAdapter(
            key="scene3",
            title="Escape radius",
            module=scene3,
            state_cls_name="Scene3State",
            renderer_cls_name="Scene3Renderer",
            scene_number=3,
            width=args.width,
            height=args.height,
            swap_rb=args.swap_rb,
            fade_seconds=args.fade_seconds,
            iterations=max(args.iterations, 24),
        ),
        PsEducationalSceneAdapter(
            key="scene4",
            title="Escape-time colouring",
            module=scene4,
            state_cls_name="Scene4State",
            renderer_cls_name="Scene4Renderer",
            scene_number=4,
            width=args.width,
            height=args.height,
            swap_rb=args.swap_rb,
            fade_seconds=args.fade_seconds,
            iterations=max(args.iterations, 32),
        ),
        scene5_adapter,
        scene6_adapter,
        SummarySceneAdapter(
            module=summary,
            width=args.width,
            height=args.height,
            swap_rb=args.swap_rb,
        ),
        MenuSceneAdapter(
            module=menu,
            width=args.width,
            height=args.height,
            swap_rb=args.swap_rb,
        ),
        free_mandelbrot_adapter,
        free_julia_adapter,
        free_burning_adapter,
        free_tricorn_adapter,
        cpu_vs_hardware_adapter,
    ]

# Main app loop

def run_app(args: argparse.Namespace) -> None:
    if args.width != WIDTH or args.height != HEIGHT:
        raise ValueError("The shared PL backend currently expects 1280x720. Leave --width/--height at their defaults.")

    backend = PlWalkthroughBackend(args)
    scenes = build_scenes(args, backend=backend)
    manager = SceneManager(scenes, start_key=args.start_scene)
    keyboard = KeyboardInput()
    controller = ControllerInput(
        args.controller,
        deadzone=args.controller_deadzone,
        pan_repeat_s=args.controller_pan_repeat_s,
        invert_x=args.controller_invert_x,
        invert_y=args.controller_invert_y,
    )

    print()
    print(f"FractalScope full walkthrough manager running on HDMI. ({SCRIPT_VERSION})")
    print("N continue | B back | Space action | WASD move | [ ] zoom | - = iterations")
    print("R reset | P palette | F function | M menu | Q terminal-only quit")
    print(f"Start scene: {manager.active_scene.title}")

    try:
        with raw_terminal():
            last_draw = 0.0
            while not manager.quit_requested:
                now = time.monotonic()

                for input_backend in (keyboard, controller):
                    for event in input_backend.poll():
                        manager.handle_event(event)

                manager.update(now)

                # PS-drawn scenes return packed frames to the shared backend.
                # PL scenes render directly inside their update() method.
                interval = 1.0 / max(1.0, args.fps)
                if manager.wants_redraw(now) and (now - last_draw >= interval):
                    frame = manager.draw_packed(now)
                    backend.show_packed_frame(frame)
                    last_draw = now

                time.sleep(0.004)
    finally:
        controller.close()
        backend.close()
        print("\nWalkthrough manager stopped.")

# Tests and CLI

def self_test(args: argparse.Namespace) -> None:
    scenes = build_scenes(args)
    manager = SceneManager(scenes, start_key=args.start_scene)

    assert manager.active_scene.key == args.start_scene
    now = time.monotonic()
    packed = manager.draw_packed(now)
    assert packed.shape == (args.height, args.width)
    assert packed.dtype == np.uint32

    # Check the loading, placeholder, summary, and menu render paths too.
    for key in ("loading", "scene5", "scene6", "summary", "menu", "free_mandelbrot", "free_julia", "free_burning_ship", "free_tricorn", "cpu_vs_hardware"):
        manager._go_to_key(key)
        packed = manager.draw_packed(time.monotonic())
        assert packed.shape == (args.height, args.width)
        assert packed.dtype == np.uint32

    sample_payload = "TDT,7,0001,+0,+0,0,0"
    sample_crc = ControllerInput._crc8_ccitt(sample_payload.encode("ascii"))
    controller_parser = ControllerInput("off")
    parsed = controller_parser._parse_line(f"{sample_payload},{sample_crc:02X}".encode("ascii"))
    assert parsed == (7, 1, 0, 0, 0, 0)

    manager._go_to_key("loading")
    manager.handle_event(AppEvent(AppEventKind.MENU, source="controller"))
    assert manager.active_scene.key == "scene1"

    manager._go_to_key("menu")
    menu_adapter = manager.active_scene
    assert getattr(menu_adapter, "state").selected_index == 0
    manager.handle_event(AppEvent(AppEventKind.PAN, (1, 0), "controller"))
    assert getattr(menu_adapter, "state").selected_index == 1
    manager.handle_event(AppEvent(AppEventKind.PAN, (1, 0), "controller"))
    assert getattr(menu_adapter, "state").selected_index == 1
    manager.handle_event(AppEvent(AppEventKind.PAN, (0, 0), "controller"))
    manager.handle_event(AppEvent(AppEventKind.PAN, (1, 0), "controller"))
    assert getattr(menu_adapter, "state").selected_index == 2

    print("Scene manager self-test passed.")


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="FractalScope full walkthrough scene manager with shared PL backend")
    parser.add_argument("--bit", default=DEFAULT_BIT_PATH, help="Path to .bit file or directory containing the newest .bit")
    parser.add_argument("--scene-dir", default=str(script_dir() / "scenes"), help="Directory containing scene Python files")
    parser.add_argument("--backend-dir", default=str(script_dir() / "backend"), help="Directory containing helper backend Python files")
    parser.add_argument("--width", type=int, default=WIDTH)
    parser.add_argument("--height", type=int, default=HEIGHT)
    parser.add_argument("--iterations", type=int, default=12, help="Initial max_iter for early educational scenes")
    parser.add_argument("--fps", type=float, default=12.0, help="Max redraw FPS for PS-drawn scenes")
    parser.add_argument("--fade-seconds", type=float, default=0.55)
    parser.add_argument("--swap-rb", action="store_true", help="Swap red/blue packing if HDMI colour channels are reversed")
    parser.add_argument("--no-download", action="store_true", help="Load overlay metadata without downloading bitstream")

    parser.add_argument("--cpu-dir", default=str(script_dir() / "cpu_baseline"), help="Directory containing render_main.cpp and functions.cpp")
    parser.add_argument("--cpu-binary", default="", help="Optional explicit CPU renderer binary path")
    parser.add_argument("--cpu-force-compile", action="store_true", help="Force recompilation of the CPU renderer")
    parser.add_argument("--cpu-no-compile", action="store_true", help="Do not compile; require the CPU binary to already exist")
    parser.add_argument("--cpu-set", default="mandelbrot", choices=("mandelbrot", "julia", "burning_ship", "tricorn"))
    parser.add_argument("--cpu-width", type=int, default=320)
    parser.add_argument("--cpu-height", type=int, default=180)
    parser.add_argument("--cpu-max-iter", type=int, default=256)
    parser.add_argument("--cpu-threads", type=int, default=2)
    parser.add_argument("--cpu-center-x", type=float, default=-0.5)
    parser.add_argument("--cpu-center-y", type=float, default=0.0)
    parser.add_argument("--cpu-x-width", type=float, default=3.5)
    parser.add_argument("--cpu-julia-real", type=float, default=-0.8)
    parser.add_argument("--cpu-julia-imag", type=float, default=0.156)
    parser.add_argument("--cpu-timeout-s", type=float, default=120.0)
    parser.add_argument("--cpu-pl-scales", default="1", help="PL scales for the CPU-vs-hardware comparison; use 1 for a single full-res pass")

    parser.add_argument("--controller", default="auto", help="Pico controller serial device: auto, off, or /dev/ttyACM0")
    parser.add_argument("--controller-deadzone", type=int, default=450, help="Joystick deadzone in calibrated ADC counts")
    parser.add_argument("--controller-pan-repeat-s", type=float, default=0.075, help="Joystick repeat interval while held off-centre")
    parser.add_argument("--controller-invert-x", action="store_true", help="Flip controller joystick X direction")
    parser.add_argument("--controller-invert-y", action="store_true", help="Flip controller joystick Y direction")

    parser.add_argument(
        "--start-scene",
        default="loading",
        choices=("loading", "scene1", "scene2", "scene3", "scene4", "scene5", "scene6", "summary", "menu", "free_mandelbrot", "free_julia", "free_burning_ship", "free_tricorn", "cpu_vs_hardware"),
    )
    add_backend_args(parser)
    parser.add_argument("--self-test", action="store_true")
    return parser


def main(argv: Optional[Iterable[str]] = None) -> int:
    args = build_arg_parser().parse_args(argv)
    if args.self_test:
        self_test(args)
        return 0
    run_app(args)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
