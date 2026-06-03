import numpy as np
from PIL import Image
from ui_renderer import UIRenderer

class FakeState:
    center_r     = -0.5        # slightly left of origin, typical full Mandelbrot view
    center_i     =  0.0        # centred vertically
    zoom         =  1.0        # fully zoomed out, whole set visible
    max_iter     =  100
    actual_iter  =  100        # no clamping at low zoom
    palette_name = "Cyan"      # matches the cyan background
    fractal_mode = "Mandelbrot"
    julia_c_r    =  0.0
    julia_c_i    =  0.0
    overflow     =  False
    connected    =  True
    joy_x        =  0.0
    joy_y        =  0.0

# --- Load a local image as background ---
bg = Image.open("/Users/junjiangwu/Desktop/test2.jpg").resize((1280, 720)).convert("RGB")
framebuffer = np.array(bg)

# --- Draw overlay ---
renderer = UIRenderer(width=1280, height=720)
renderer.draw(framebuffer, FakeState())

# --- Save result ---
Image.fromarray(framebuffer).save("/Users/junjiangwu/Desktop/overlay_test.png")
print("Done — check overlay_test.png on your Desktop")