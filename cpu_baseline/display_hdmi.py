"""
Run this script ONLY. It will:
  1. Check g++ is installed
  2. Compile the C++ fractal code
  3. Run the compiled program (you enter parameters as normal)
  4. Detect which PNG was saved from the C++ output
  5. Display it on screen

Works on macOS and Windows.

Requirements:
    pip install pygame

Usage:
    python3 run_and_display.py           Normal mode: fullscreen on external HDMI display
    python3 run_and_display.py --test    Test mode: resizable window on your primary screen

Before running in normal mode:
    - Connect HDMI cable from laptop to external display
    - macOS: System Settings > Displays > set to Extended (not Mirror)
    - Windows: Win+P > Extend
"""

import subprocess
import sys
import os
import shutil
import platform
import time

# ── Step 0: Parse arguments

TEST_MODE = "--test" in sys.argv

if TEST_MODE:
    print("Running in TEST MODE — window on primary screen, no external display needed.")

# ── Step 0b: Check pygame

try:
    import pygame
except ImportError:
    print("Error: pygame is not installed.")
    print("Fix: pip install pygame")
    sys.exit(1)

# ── Step 1: Check g++ is available

print("=" * 50)
print("FractalScope CPU Baseline")
print("=" * 50)

if shutil.which("g++") is None:
    print("\nError: g++ not found.")
    if platform.system() == "Darwin":
        print("Fix: xcode-select --install")
    elif platform.system() == "Windows":
        print("Fix: Install MinGW-w64 and add it to your PATH.")
        print("     https://www.mingw-w64.org/")
    sys.exit(1)

print("\n[1/4] g++ found.")

# ── Step 2: Compile

print("[2/4] Compiling C++ code...")

# Detect source file directory (same folder as this script)
script_dir = os.path.dirname(os.path.abspath(__file__))
main_cpp   = os.path.join(script_dir, "main.cpp")
funcs_cpp  = os.path.join(script_dir, "functions.cpp")
output_bin = os.path.join(script_dir, "fractal_cpu")

# Windows: compiled binary needs .exe extension
if platform.system() == "Windows":
    output_bin += ".exe"

# Check source files exist
for f in [main_cpp, funcs_cpp]:
    if not os.path.exists(f):
        print(f"Error: Source file not found: {f}")
        print("Make sure run_and_display.py is in the same folder as main.cpp and functions.cpp")
        sys.exit(1)

compile_cmd = [
    "g++",
    main_cpp,
    funcs_cpp,
    "-o", output_bin,
    "-O2",          # optimise for speed
    "-lpthread",    # threading support
    "-std=c++11",
]

result = subprocess.run(compile_cmd, capture_output=True, text=True)

if result.returncode != 0:
    print("Compilation failed:\n")
    print(result.stderr)
    sys.exit(1)

print("      Compilation successful.")

# ── Step 3: Run the C++ program 
# We stream its stdout live so the user sees the prompts and can type, and simultaneously capture each line so we can detect the PNG filename.

print("[3/4] Running fractal renderer...\n")
print("-" * 50)

# The C++ program prints "<SetName> set chosen..." and saves a file named "<SetName>.png"
# We watch for that line to know which PNG was created.

SET_NAMES = ["Mandelbrot", "Julia", "Burning Ship", "Tricorn"]
detected_png = None
threaded_time = None
png_time = None

proc = subprocess.Popen(
    [output_bin],
    stdout=subprocess.PIPE,
    stderr=subprocess.STDOUT,
    stdin=sys.stdin,        # pass keyboard input straight through
    text=True,
    bufsize=1,              # line-buffered
    cwd=script_dir,         # save PNG in the same folder as the source
)

for line in proc.stdout:
    print(line, end="", flush=True)

    # Detect which set was chosen from the C++ output line:
    # e.g. "Mandelbrot set chosen..."
    for name in SET_NAMES:
        if name in line and "set chosen" in line:
            detected_png = os.path.join(script_dir, name + ".png")
    
    if "Average time" in line:
        threaded_time = os.path.join(script_dir)

proc.wait()
e2e_start_0 = time.time()
print("-" * 50)

if proc.returncode != 0:
    print(f"\nError: C++ program exited with code {proc.returncode}")
    sys.exit(1)

# ── Step 4: Find the PNG
if detected_png is None or not os.path.exists(detected_png):
    # Fallback: find the most recently modified PNG in the folder
    pngs = [
        os.path.join(script_dir, f)
        for f in os.listdir(script_dir)
        if f.endswith(".png")
    ]
    if not pngs:
        print("\nError: No PNG file found. The C++ program may have failed to save it.")
        sys.exit(1)
    detected_png = max(pngs, key=os.path.getmtime)
    print(f"\nNote: Auto-detected PNG: {os.path.basename(detected_png)}")
else:
    print(f"\n[4/4] PNG detected: {os.path.basename(detected_png)}")

# ── Step 5: Display

print("\nOpening display...")
print("Press Q or Escape to close the display window.\n")

pygame.init()

if TEST_MODE:
    # ── Test mode: plain resizable window on primary screen
    print("Test mode: opening window on primary screen.")

    # Open at 1280x720 (matches the fractal render resolution exactly)
    screen = pygame.display.set_mode((1280, 720), pygame.RESIZABLE)
    pygame.display.set_caption("FractalScope — TEST MODE")

    screen_w, screen_h = screen.get_size()

else:
    # ── Normal mode: fullscreen on external HDMI display
    num_displays = 1
    if hasattr(pygame.display, "get_num_displays"):
        num_displays = pygame.display.get_num_displays()

    print(f"Displays detected: {num_displays}")

    display_index = 1 if num_displays > 1 else 0

    if display_index == 0:
        print("Warning: Only one display detected.")
        print("If an external monitor is connected, make sure it is set to")
        print("Extended mode (not Mirror/Duplicate) and restart this script.")
        print("Tip: run with --test flag to test without an external display.")
    else:
        print(f"Using external display (index {display_index}).")

    os.environ["SDL_VIDEO_FULLSCREEN_DISPLAY"] = str(display_index)

    try:
        screen = pygame.display.set_mode(
            (0, 0),
            pygame.FULLSCREEN | pygame.NOFRAME,
            display=display_index,
        )
    except TypeError:
        # Older pygame versions don't support display= argument
        screen = pygame.display.set_mode((0, 0), pygame.FULLSCREEN | pygame.NOFRAME)

    pygame.display.set_caption("FractalScope")
    screen_w, screen_h = screen.get_size()

print(f"Display resolution: {screen_w}x{screen_h}")

# Load the PNG
try:
    image = pygame.image.load(detected_png)
except pygame.error as e:
    print(f"Error loading image: {e}")
    pygame.quit()
    sys.exit(1)

# Scale to fit the window/screen, preserving aspect ratio
img_w, img_h = image.get_size()
scale = min(screen_w / img_w, screen_h / img_h)
new_w = int(img_w * scale)
new_h = int(img_h * scale)
image = pygame.transform.smoothscale(image, (new_w, new_h))

# Centre on screen
x_off = (screen_w - new_w) // 2
y_off = (screen_h - new_h) // 2

screen.fill((0, 0, 0))
screen.blit(image, (x_off, y_off))
pygame.display.flip()

e2e_end_0 = time.time()
print("Image displayed. Press Q or Escape to close.")

# Event loop — keep window open until user closes it
running = True
while running:
    for event in pygame.event.get():
        if event.type == pygame.QUIT:
            running = False
        elif event.type == pygame.KEYDOWN:
            if event.key in (pygame.K_q, pygame.K_ESCAPE):
                running = False
        elif event.type == pygame.VIDEORESIZE and TEST_MODE:
            # Allow window resizing in test mode
            screen = pygame.display.set_mode(event.size, pygame.RESIZABLE)
            screen_w, screen_h = screen.get_size()
            scale = min(screen_w / img_w, screen_h / img_h)
            new_w = int(img_w * scale)
            new_h = int(img_h * scale)
            resized = pygame.transform.smoothscale(
                pygame.image.load(detected_png), (new_w, new_h)
            )
            x_off = (screen_w - new_w) // 2
            y_off = (screen_h - new_h) // 2
            screen.fill((0, 0, 0))
            screen.blit(resized, (x_off, y_off))
            pygame.display.flip()

pygame.quit()
print("Display closed.")
e2e_time = (e2e_end_0 - e2e_start_0)

print(f"End of C++ -> HDMI time: {e2e_time} seconds")
print(threaded_time)
