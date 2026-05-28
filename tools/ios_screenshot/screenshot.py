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
