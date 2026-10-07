#!/usr/bin/env python3
"""Stop an OHOS guest created by boot_ohos_guest.py through QMP."""
import argparse
import json
from pathlib import Path

from boot_ohos_guest import qmp_command


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--guest', type=Path, required=True)
    args = parser.parse_args()
    if not args.guest.is_file():
        return
    guest = json.loads(args.guest.read_text())
    qmp = Path(guest['qmp'])
    if qmp.exists():
        try:
            qmp_command(qmp, 'quit')
        except (FileNotFoundError, ConnectionRefusedError):
            # A failed boot may already have stopped QEMU and left a socket.
            pass


if __name__ == '__main__':
    main()
