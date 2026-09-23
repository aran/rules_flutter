"""Start the pymobiledevice3 tunnel daemon.

This must run as root (sudo) because creating a TUN interface requires
elevated privileges. The daemon exposes an HTTP API on 127.0.0.1:49151
that screenshot.py uses to reach devices.

Usage:
    sudo python3 tunneld.py
"""
import os
import sys

# Run as root from inside a Bazel runfiles tree, cached bytecode would land
# there owned by root, and Bazel could no longer rebuild that tree. The dev
# tool's ios-tunnel also sets PYTHONDONTWRITEBYTECODE, which covers the
# interpreter's own startup; this covers a direct `sudo` run of this binary.
sys.dont_write_bytecode = True


def main():
    if os.getuid() != 0:
        print('This command requires root privileges.', file=sys.stderr)
        print('Run with sudo.', file=sys.stderr)
        sys.exit(1)

    # Invoke pymobiledevice3's tunneld via its CLI.
    sys.argv = ['pymobiledevice3', 'tunneld']
    from pymobiledevice3.cli.remote import cli
    cli()


if __name__ == '__main__':
    main()
