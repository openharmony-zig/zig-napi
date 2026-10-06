#!/usr/bin/env python3
"""Boot an isolated Linux QEMU guest for the real Node.js addon E2E matrix."""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import shutil
import subprocess
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--image', type=Path, required=True, help='Immutable x86_64 cloud-init qcow2 base')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--ssh-port', type=int, default=22226)
    args = parser.parse_args()
    root = args.output.resolve()
    root.mkdir(parents=True, exist_ok=True)
    if (root / 'qemu.pid').exists():
        parser.error('output has an existing QEMU pid; use a fresh output directory')
    key = root / 'id_ed25519'
    subprocess.run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(key)], check=True)
    seed = root / 'seed'
    seed.mkdir()
    (seed / 'meta-data').write_text('instance-id: zig-napi-' + uuid.uuid4().hex + '\nlocal-hostname: zig-napi-node\n')
    (seed / 'user-data').write_text('#cloud-config\nusers:\n  - name: tester\n    groups: [sudo]\n    shell: /bin/bash\n    sudo: "ALL=(ALL) NOPASSWD:ALL"\n    lock_passwd: true\n    ssh_authorized_keys:\n      - ' + key.with_suffix('.pub').read_text().strip() + '\nssh_pwauth: false\n')
    iso = root / 'seed.iso'
    if platform.system() == 'Darwin':
        subprocess.run(['hdiutil', 'makehybrid', '-iso', '-joliet', '-default-volume-name', 'cidata', '-o', str(iso), str(seed)], check=True)
    else:
        tool = shutil.which('genisoimage') or shutil.which('mkisofs')
        if not tool:
            parser.error('genisoimage or mkisofs required on Linux')
        subprocess.run([tool, '-output', str(iso), '-volid', 'cidata', '-joliet', '-rock', str(seed)], check=True)
    image = root / 'disk.qcow2'
    subprocess.run(['qemu-img', 'create', '-f', 'qcow2', '-F', 'qcow2', '-b', str(args.image.resolve()), str(image), '24G'], check=True)
    command = ['qemu-system-x86_64', '-M', 'q35', '-accel', 'tcg', '-cpu', 'max', '-smp', '4', '-m', '4096', '-drive', 'file=' + str(image) + ',if=virtio,format=qcow2', '-drive', 'file=' + str(iso) + ',media=cdrom,readonly=on', '-netdev', f'user,id=net0,hostfwd=tcp:127.0.0.1:{args.ssh_port}-:22', '-device', 'virtio-net-pci,netdev=net0', '-display', 'none', '-serial', 'file:' + str(root / 'serial.log'), '-qmp', 'unix:' + str(root / 'qmp.sock') + ',server=on,wait=off', '-pidfile', str(root / 'qemu.pid'), '-daemonize']
    subprocess.run(command, check=True)
    digest = hashlib.sha256()
    with args.image.open('rb') as file:
        for block in iter(lambda: file.read(1024 * 1024), b''):
            digest.update(block)
    (root / 'guest.json').write_text(json.dumps({'command': command, 'baseImage': str(args.image.resolve()), 'baseImageSha256': digest.hexdigest(), 'sshPort': args.ssh_port, 'user': 'tester', 'key': str(key), 'architecture': 'x86_64'}, indent=2))
    print(root / 'guest.json')


if __name__ == '__main__':
    main()
