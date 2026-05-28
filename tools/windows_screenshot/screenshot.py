"""DXGI Desktop Duplication screenshot.

Usage: screenshot <output_png>

Captures the Windows desktop via DXGI (correctly captures D3D/Flutter
surfaces, unlike GDI CopyFromScreen which returns black for D3D content).
"""
import sys
import dxcam
from PIL import Image


def main():
    if len(sys.argv) < 2:
        print("Usage: screenshot <output_png>", file=sys.stderr)
        sys.exit(1)
    output = sys.argv[1]
    camera = dxcam.create()
    frame = camera.grab()
    if frame is None:
        print("DXGI grab() returned None — no desktop compositor?", file=sys.stderr)
        sys.exit(1)
    Image.fromarray(frame).save(output)


if __name__ == "__main__":
    main()
