"""DXGI Desktop Duplication screenshot for Windows Flutter app verification.

Usage: python dxgi_screenshot.py <app_exe_path> <output_png> [wait_seconds]

Launches the app, waits for it to render, captures the desktop via DXGI
(which correctly captures D3D/Flutter surfaces unlike GDI CopyFromScreen),
saves the screenshot, and kills the app.

Requires: pip install dxcam numpy Pillow opencv-python-headless
Must run in an interactive desktop session (PsExec -i <session_id>).
"""

import subprocess
import sys
import time
import os

import dxcam
from PIL import Image


def main():
    if len(sys.argv) < 3:
        print("Usage: python dxgi_screenshot.py <app_exe> <output_png> [wait_seconds]")
        sys.exit(1)

    app_path = sys.argv[1]
    output_path = sys.argv[2]
    wait_seconds = int(sys.argv[3]) if len(sys.argv) > 3 else 10

    app_dir = os.path.dirname(app_path)

    # Launch app
    print(f"Launching: {app_path}")
    proc = subprocess.Popen([app_path], cwd=app_dir)
    time.sleep(wait_seconds)

    if proc.poll() is not None:
        print(f"FAIL: App exited with code {proc.returncode}")
        sys.exit(1)

    print(f"App running (PID {proc.pid})")

    # DXGI capture
    print("Capturing via DXGI Desktop Duplication...")
    camera = dxcam.create()
    frame = camera.grab()
    if frame is not None:
        img = Image.fromarray(frame)
        img.save(output_path)
        print(f"Screenshot saved: {output_path} ({img.size[0]}x{img.size[1]})")
    else:
        print("FAIL: dxcam.grab() returned None - no desktop compositor?")
        proc.terminate()
        sys.exit(1)

    # Cleanup
    proc.terminate()
    print("PASS")


if __name__ == "__main__":
    main()
