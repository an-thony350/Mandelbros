#!/usr/bin/env python3
"""
reusable CPU baseline helper 
basically does the following:
    1. Compiling render_main.cpp + functions.cpp when needed.
    2. Running the non-interactive CPU renderer.
    3. Loading the raw RGB888 output.
    4. Resizing RGB frames for HDMI/display use.
    5. Packing RGB888 into the uint32 framebuffer format used by the walkthrough.
"""

from __future__ import annotations

import json
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Tuple

import numpy as np

SCRIPT_VERSION = "2026-06-12-v1-cpu-baseline-runner"

VALID_SETS = ("mandelbrot", "julia", "burning_ship", "tricorn")


@dataclass
class CpuRenderConfig:
    """Configuration passed to render_main.cpp."""

    fractal_set: str = "mandelbrot"
    width: int = 320
    height: int = 180
    max_iter: int = 256
    threads: int = 2

    center_x: float = -0.5
    center_y: float = 0.0
    x_width: float = 3.5

    julia_real: float = -0.8
    julia_imag: float = 0.156

    out_rgb: str = "/tmp/fractalscope_cpu.rgb"
    out_json: str = "/tmp/fractalscope_cpu.json"


@dataclass
class CpuRenderResult:
    """Result returned after a CPU render has completed."""

    config: CpuRenderConfig
    stats: Dict[str, object]
    rgb: np.ndarray
    rgb_path: Path
    json_path: Path
    binary_path: Path
    stdout: str
    stderr: str

    @property
    def render_seconds(self) -> float:
        return float(self.stats.get("render_seconds", 0.0))

    @property
    def rgb_write_seconds(self) -> float:
        return float(self.stats.get("rgb_write_seconds", 0.0))

    @property
    def pixels_per_second(self) -> float:
        return float(self.stats.get("pixels_per_second", 0.0))


class CpuBaselineError(RuntimeError):
    """Raised when the CPU baseline build or render fails."""


def normalise_set_name(fractal_set: str) -> str:
    value = str(fractal_set).strip().lower().replace("-", "_")
    if value == "burningship":
        value = "burning_ship"
    if value not in VALID_SETS:
        raise ValueError(f"Invalid fractal set {fractal_set!r}. Expected one of: {', '.join(VALID_SETS)}")
    return value


def validate_config(cfg: CpuRenderConfig) -> CpuRenderConfig:
    cfg.fractal_set = normalise_set_name(cfg.fractal_set)

    if int(cfg.width) <= 0:
        raise ValueError("CPU render width must be positive")
    if int(cfg.height) <= 0:
        raise ValueError("CPU render height must be positive")
    if int(cfg.max_iter) <= 0:
        raise ValueError("CPU max_iter must be positive")
    if int(cfg.threads) <= 0:
        raise ValueError("CPU thread count must be positive")
    if float(cfg.x_width) <= 0.0:
        raise ValueError("x_width must be positive")

    cfg.width = int(cfg.width)
    cfg.height = int(cfg.height)
    cfg.max_iter = int(cfg.max_iter)
    cfg.threads = int(cfg.threads)
    cfg.center_x = float(cfg.center_x)
    cfg.center_y = float(cfg.center_y)
    cfg.x_width = float(cfg.x_width)
    cfg.julia_real = float(cfg.julia_real)
    cfg.julia_imag = float(cfg.julia_imag)

    return cfg


def default_binary_path(cpu_dir: Path) -> Path:
    return cpu_dir / "fractal_cpu_render"


def required_source_paths(cpu_dir: Path) -> Tuple[Path, Path]:
    return cpu_dir / "render_main.cpp", cpu_dir / "functions.cpp"


def newest_mtime(paths: Iterable[Path]) -> float:
    return max(path.stat().st_mtime for path in paths)


def build_cpu_renderer(
    cpu_dir: Path,
    binary_path: Optional[Path] = None,
    *,
    force: bool = False,
    verbose: bool = True,
) -> Path:
    """Compile render_main.cpp + functions.cpp if the binary is missing or stale."""

    cpu_dir = Path(cpu_dir).expanduser().resolve()
    binary = Path(binary_path).expanduser().resolve() if binary_path else default_binary_path(cpu_dir)

    render_main, functions_cpp = required_source_paths(cpu_dir)
    missing = [str(path) for path in (render_main, functions_cpp) if not path.exists()]
    if missing:
        raise FileNotFoundError("Missing CPU source file(s): " + ", ".join(missing))

    needs_build = force or not binary.exists()
    if not needs_build:
        needs_build = binary.stat().st_mtime < newest_mtime((render_main, functions_cpp))

    if not needs_build:
        if verbose:
            print(f"CPU renderer is up to date: {binary}")
        return binary

    binary.parent.mkdir(parents=True, exist_ok=True)
    cmd = [
        "g++",
        str(render_main),
        str(functions_cpp),
        "-O3",
        "-pthread",
        "-std=c++11",
        "-Wno-psabi",
        "-o",
        str(binary),
    ]

    if verbose:
        print("Compiling CPU renderer:")
        print("  " + " ".join(cmd))

    result = subprocess.run(cmd, cwd=str(cpu_dir), text=True, capture_output=True)
    if result.returncode != 0:
        raise CpuBaselineError(
            "CPU renderer compilation failed with code "
            f"{result.returncode}\nSTDOUT:\n{result.stdout}\nSTDERR:\n{result.stderr}"
        )

    if verbose:
        if result.stdout.strip():
            print(result.stdout.strip())
        if result.stderr.strip():
            print(result.stderr.strip())
        print("CPU renderer compiled successfully.")

    return binary


def cpu_render_command(binary_path: Path, cfg: CpuRenderConfig) -> List[str]:
    cfg = validate_config(cfg)
    return [
        str(Path(binary_path).expanduser().resolve()),
        "--set",
        cfg.fractal_set,
        "--width",
        str(cfg.width),
        "--height",
        str(cfg.height),
        "--max-iter",
        str(cfg.max_iter),
        "--threads",
        str(cfg.threads),
        "--center-x",
        str(cfg.center_x),
        "--center-y",
        str(cfg.center_y),
        "--x-width",
        str(cfg.x_width),
        "--julia-real",
        str(cfg.julia_real),
        "--julia-imag",
        str(cfg.julia_imag),
        "--out-rgb",
        str(Path(cfg.out_rgb).expanduser()),
        "--out-json",
        str(Path(cfg.out_json).expanduser()),
    ]


def run_cpu_renderer(
    binary_path: Path,
    cfg: CpuRenderConfig,
    *,
    verbose: bool = True,
    timeout_s: Optional[float] = None,
) -> Tuple[Dict[str, object], str, str]:
    """Run the CPU renderer and return JSON stats plus stdout/stderr."""

    cfg = validate_config(cfg)
    binary = Path(binary_path).expanduser().resolve()
    out_rgb = Path(cfg.out_rgb).expanduser().resolve()
    out_json = Path(cfg.out_json).expanduser().resolve()

    out_rgb.parent.mkdir(parents=True, exist_ok=True)
    out_json.parent.mkdir(parents=True, exist_ok=True)

    cmd = cpu_render_command(binary, cfg)
    if verbose:
        print("Running CPU renderer:")
        print("  " + " ".join(cmd))

    result = subprocess.run(cmd, text=True, capture_output=True, timeout=timeout_s)
    if result.returncode != 0:
        raise CpuBaselineError(
            "CPU renderer failed with code "
            f"{result.returncode}\nSTDOUT:\n{result.stdout}\nSTDERR:\n{result.stderr}"
        )

    if verbose and result.stdout.strip():
        print(result.stdout.strip())
    if verbose and result.stderr.strip():
        print(result.stderr.strip())

    if not out_rgb.exists():
        raise FileNotFoundError(f"CPU renderer did not produce raw RGB file: {out_rgb}")
    if not out_json.exists():
        raise FileNotFoundError(f"CPU renderer did not produce JSON file: {out_json}")

    with out_json.open("r", encoding="utf-8") as f:
        stats = json.load(f)

    return stats, result.stdout, result.stderr


def load_raw_rgb(path: Path, width: int, height: int) -> np.ndarray:
    """Load raw RGB888 data as an array with shape (height, width, 3)."""

    path = Path(path).expanduser().resolve()
    expected = int(width) * int(height) * 3
    data = np.fromfile(str(path), dtype=np.uint8)
    if data.size != expected:
        raise ValueError(f"Expected {expected} RGB bytes from {path}, got {data.size}")
    return data.reshape((int(height), int(width), 3))


def resize_rgb_nearest(rgb: np.ndarray, target_width: int, target_height: int) -> np.ndarray:
    """
    Resize RGB888 data using nearest-neighbour scaling.
    Exact integer scaling is done with NumPy repeats. Non-integer scaling uses Pillow
    """

    if rgb.ndim != 3 or rgb.shape[2] != 3:
        raise ValueError(f"Expected RGB image with shape (H, W, 3), got {rgb.shape}")
    if rgb.dtype != np.uint8:
        rgb = rgb.astype(np.uint8)

    src_h, src_w, _ = rgb.shape
    target_width = int(target_width)
    target_height = int(target_height)

    if src_w == target_width and src_h == target_height:
        return rgb

    if target_width % src_w == 0 and target_height % src_h == 0:
        x_rep = target_width // src_w
        y_rep = target_height // src_h
        return np.repeat(np.repeat(rgb, y_rep, axis=0), x_rep, axis=1)

    try:
        from PIL import Image
    except ImportError as exc:
        raise RuntimeError(
            f"Cannot resize {src_w}x{src_h} to {target_width}x{target_height} without Pillow. "
            "Use an exact integer scale size such as 320x180 or 640x360 for 1280x720."
        ) from exc

    img = Image.fromarray(rgb, mode="RGB")
    img = img.resize((target_width, target_height), resample=Image.NEAREST)
    return np.asarray(img, dtype=np.uint8)


def pack_rgb888(rgb: np.ndarray, *, swap_rb: bool = False) -> np.ndarray:
    """
    Pack RGB888 into uint32 words: 0x00RRGGBB by default.
    """

    if rgb.ndim != 3 or rgb.shape[2] != 3:
        raise ValueError(f"Expected RGB image with shape (H, W, 3), got {rgb.shape}")
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


def render_cpu_frame(
    cpu_dir: Path,
    cfg: CpuRenderConfig,
    *,
    binary_path: Optional[Path] = None,
    build: bool = True,
    force_build: bool = False,
    verbose: bool = True,
    timeout_s: Optional[float] = None,
) -> CpuRenderResult:
    """Build if needed, run the CPU renderer, and load the raw RGB frame."""

    cfg = validate_config(cfg)
    cpu_dir = Path(cpu_dir).expanduser().resolve()

    if build:
        binary = build_cpu_renderer(cpu_dir, binary_path, force=force_build, verbose=verbose)
    else:
        binary = Path(binary_path).expanduser().resolve() if binary_path else default_binary_path(cpu_dir)
        if not binary.exists():
            raise FileNotFoundError(f"CPU binary does not exist: {binary}")

    stats, stdout, stderr = run_cpu_renderer(binary, cfg, verbose=verbose, timeout_s=timeout_s)
    rgb_path = Path(cfg.out_rgb).expanduser().resolve()
    json_path = Path(cfg.out_json).expanduser().resolve()
    rgb = load_raw_rgb(rgb_path, cfg.width, cfg.height)

    return CpuRenderResult(
        config=cfg,
        stats=stats,
        rgb=rgb,
        rgb_path=rgb_path,
        json_path=json_path,
        binary_path=binary,
        stdout=stdout,
        stderr=stderr,
    )


def make_temp_output_config(cfg: CpuRenderConfig, prefix: str = "fractalscope_cpu_") -> CpuRenderConfig:
    tmp_dir = Path(tempfile.gettempdir())
    stem = next(tempfile._get_candidate_names())  # kept simple; paths are still under /tmp
    return CpuRenderConfig(
        fractal_set=cfg.fractal_set,
        width=cfg.width,
        height=cfg.height,
        max_iter=cfg.max_iter,
        threads=cfg.threads,
        center_x=cfg.center_x,
        center_y=cfg.center_y,
        x_width=cfg.x_width,
        julia_real=cfg.julia_real,
        julia_imag=cfg.julia_imag,
        out_rgb=str(tmp_dir / f"{prefix}{stem}.rgb"),
        out_json=str(tmp_dir / f"{prefix}{stem}.json"),
    )


def format_cpu_stats(result: CpuRenderResult) -> str:
    stats = result.stats
    return (
        f"set={stats.get('set', result.config.fractal_set)} "
        f"resolution={stats.get('width', result.config.width)}x{stats.get('height', result.config.height)} "
        f"max_iter={stats.get('max_iter', result.config.max_iter)} "
        f"threads={stats.get('threads', result.config.threads)} "
        f"render_seconds={result.render_seconds:.6f} "
        f"pixels_per_second={result.pixels_per_second:.3f}"
    )


__all__ = [
    "SCRIPT_VERSION",
    "VALID_SETS",
    "CpuBaselineError",
    "CpuRenderConfig",
    "CpuRenderResult",
    "build_cpu_renderer",
    "cpu_render_command",
    "default_binary_path",
    "format_cpu_stats",
    "load_raw_rgb",
    "make_temp_output_config",
    "normalise_set_name",
    "pack_rgb888",
    "render_cpu_frame",
    "resize_rgb_nearest",
    "run_cpu_renderer",
    "validate_config",
]
