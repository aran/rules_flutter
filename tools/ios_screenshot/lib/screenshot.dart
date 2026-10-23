/// iOS device screenshot helper (Dart entrypoint).
///
/// The screenshot itself is taken through `pymobiledevice3`'s DVT service —
/// `_flutter.screenshot` cannot capture on iOS because the Impeller renderer
/// does not implement compressed image capture. Reimplementing the DVT
/// protocol in Dart is out of scope, so this entrypoint is a thin driver:
/// it resolves a host `python3` (a documented host prerequisite, like the
/// Android SDK or Xcode) and runs the screenshot program below through it.
///
/// Keeping the program here as a `dart_binary` instead of a `py_binary`
/// removes `rules_python` and the `pip` hub from every consumer's module
/// graph: the helper needs no Bazel-built Python toolchain or wheels, only
/// the host interpreter and an installed `pymobiledevice3`
/// (`python3 -m pip install pymobiledevice3`).
///
/// Usage (same as before): `screenshot <output_path> --udid <device_udid>`.
/// Requires the tunnel daemon (`tunneld`, this same package) running as root.
import 'dart:io';

import 'python_host.dart';

/// The screenshot program, run by the host interpreter (stdin, so no
/// source file is staged next to the binary).
const String _screenshotProgram = r'''
"""Capture a screenshot from an iOS device via pymobiledevice3 DVT service.

Requires a running tunnel daemon (started via tunneld.py or
`sudo flutter_bazel ios-tunnel`).

Usage:
    screenshot.py <output_path> --udid <device_udid>
"""
import argparse
import asyncio
import sys

from pymobiledevice3.exceptions import TunneldConnectionError
from pymobiledevice3.services.dvt.instruments.dvt_provider import DvtProvider
from pymobiledevice3.services.dvt.instruments.screenshot import Screenshot
from pymobiledevice3.tunneld.api import get_tunneld_devices


async def _take_screenshot(udid: str, output: str) -> None:
    try:
        devices = await get_tunneld_devices()
    except TunneldConnectionError:
        print('Unable to connect to Tunneld — no devices found.', file=sys.stderr)
        print('Start the tunnel daemon first: sudo flutter_bazel ios-tunnel', file=sys.stderr)
        sys.exit(1)

    if not devices:
        print('No devices found via tunneld.', file=sys.stderr)
        sys.exit(1)

    rsd = None
    for device in devices:
        if udid in str(device.udid):
            rsd = device
            break

    if rsd is None:
        available = [str(d.udid) for d in devices]
        print(f'Device {udid} not found. Available: {available}', file=sys.stderr)
        sys.exit(1)

    async with rsd:
        async with DvtProvider(rsd) as dvt:
            async with Screenshot(dvt) as screenshot_service:
                image_data = await screenshot_service.get_screenshot()

    with open(output, 'wb') as f:
        f.write(image_data)

    print(f'Screenshot saved to {output}')


def main():
    parser = argparse.ArgumentParser(description='iOS device screenshot via DVT')
    parser.add_argument('output', help='Output file path (PNG)')
    parser.add_argument('--udid', required=True, help='Device UDID')
    args = parser.parse_args()

    asyncio.run(_take_screenshot(args.udid, args.output))


if __name__ == '__main__':
    main()
''';

Future<void> main(List<String> args) async {
  final python = findHostPython();
  if (python == null) {
    stderr.writeln(missingPythonMessage(purpose: 'iOS device screenshots'));
    exit(2);
  }
  final exitCode = await runPythonProgram(
    python,
    _screenshotProgram,
    args,
  );
  if (exitCode != 0) {
    exit(exitCode);
  }
}
