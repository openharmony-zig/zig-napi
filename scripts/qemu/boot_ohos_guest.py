#!/usr/bin/env python3
"""Boot a verified harmony-contrib/ohos-qemu release and wait for HAP readiness."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import signal
import shutil
import socket
import subprocess
import tarfile
import time
import uuid

RELEASE = 'v20260919'
RELEASE_URL = 'https://github.com/harmony-contrib/ohos-qemu/releases/download/' + RELEASE
IMAGES = {
    'x86_64': ('openharmony-qemu-x86_64-x86_64_virt-phone.tar.gz',
               '08d35399119ec9b87d564cd8bf024e8a189921f5bacf09da889b7b223848a488'),
    'arm64': ('openharmony-qemu-arm64-arm64_virt-phone.tar.gz',
              'eda208b8ae5375e42af0f1ad6756d9e3ba57dd6ee9b13c2c7917c46b4ab14710'),
}


def verify_archive(path, expected):
    digest = hashlib.sha256()
    with path.open('rb') as file:
        for block in iter(lambda: file.read(1024 * 1024), b''):
            digest.update(block)
    actual = digest.hexdigest()
    if actual != expected:
        raise RuntimeError(f'QEMU release SHA256 mismatch: {actual} != {expected}')
    return actual


def account_ready(text):
    if not re.search(r'^bootevent\.account\.ready=(?:true|"true")\s*$', text, re.M):
        return False
    accounts = re.findall(r'^\s*ID:\s*(\d+)\b(.*?)(?=^\s*ID:|\Z)', text, re.M | re.S)
    return any(identifier == '100' and re.search(r'isForeground:\s*(?:1|true)\b', details)
               for identifier, details in accounts)


def qmp_command(path, command):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.settimeout(10)
        sock.connect(str(path))
        with sock.makefile('r') as reader:
            greeting = json.loads(reader.readline())
            if 'QMP' not in greeting:
                raise RuntimeError('Not a QEMU QMP socket')
            for request in ('qmp_capabilities', command):
                sock.sendall((json.dumps({'execute': request}) + '\n').encode())
                while True:
                    line = reader.readline()
                    if not line:
                        raise RuntimeError('QMP disconnected before replying')
                    response = json.loads(line)
                    if 'error' in response:
                        raise RuntimeError('QMP failed: ' + json.dumps(response))
                    if 'return' in response:
                        break
            return greeting, response['return']


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--arch', choices=IMAGES, default='x86_64')
    parser.add_argument('--archive', type=Path, help='Use a local archive, with the same pinned SHA256 check')
    parser.add_argument('--hdc', default='hdc')
    parser.add_argument('--server', default='18711', help='Isolated HDC server port')
    parser.add_argument('--hdc-port', type=int, default=5556)
    parser.add_argument('--accel', choices=['kvm', 'hvf'], default='kvm')
    parser.add_argument('--timeout', type=int, default=900)
    args = parser.parse_args()
    if args.timeout <= 0:
        parser.error('--timeout must be positive')
    host = platform.system()
    if (host, args.arch, args.accel) not in (('Linux', 'x86_64', 'kvm'), ('Darwin', 'arm64', 'hvf')):
        parser.error('Use Linux x86_64/KVM or macOS arm64/HVF for the full OHOS system')
    if args.accel == 'kvm' and not (Path('/dev/kvm').is_char_device() and os.access('/dev/kvm', os.R_OK | os.W_OK)):
        parser.error('Readable/writable /dev/kvm is required')
    root = args.output.resolve()
    root.mkdir(parents=True, exist_ok=False)
    asset, expected = IMAGES[args.arch]
    archive = args.archive.resolve() if args.archive else root / asset
    if not args.archive:
        subprocess.run(['curl', '-fL', '--connect-timeout', '30', '--max-time', '900',
                        '--retry', '3', '--retry-delay', '2', '--retry-all-errors',
                        '--output', str(archive), RELEASE_URL + '/' + asset], check=True)
    digest = verify_archive(archive, expected)
    package_root = root / 'image'
    package_root.mkdir()
    with tarfile.open(archive, 'r:gz') as tar:
        tar.extractall(package_root, filter='data')
    launchers = list(package_root.glob('*/launch/' + ('linux.sh' if host == 'Linux' else 'macos.command')))
    if len(launchers) != 1:
        raise RuntimeError('Expected exactly one release launcher')
    launcher = launchers[0]
    qmp = Path('/tmp') / ('zig-napi-ohos-' + uuid.uuid4().hex[:12] + '.sock')
    target = f'127.0.0.1:{args.hdc_port}'
    command = ['bash', str(launcher), '--headless', '--a11y', '--qmp-socket', str(qmp),
               '--hdc-port', str(args.hdc_port), '--accel', args.accel, '-m', '4096', '-s', '4']
    state = {'release': RELEASE, 'archiveUrl': RELEASE_URL + '/' + asset, 'archiveSha256': digest,
             'architecture': args.arch, 'accelerator': args.accel, 'command': command,
             'qmp': str(qmp), 'hdc': args.hdc, 'server': args.server, 'target': target}
    state_path = root / 'guest.json'
    state_path.write_text(json.dumps(state, indent=2))
    hdc = [args.hdc, '-s', args.server]
    hdc_path = shutil.which(args.hdc)
    if not hdc_path:
        raise RuntimeError('HDC executable not found: ' + args.hdc)
    # HDC starts its server by executable name. Use this SDK's hdc even when
    # another version is already on PATH (or the SDK toolchains are not).
    hdc_env = dict(os.environ, PATH=str(Path(hdc_path).resolve().parent) + os.pathsep + os.environ.get('PATH', ''))
    with (root / 'qemu.log').open('w') as log:
        process = subprocess.Popen(command, cwd=launcher.parent.parent, stdin=subprocess.DEVNULL,
                                   stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    state['pid'] = process.pid
    state_path.write_text(json.dumps(state, indent=2))
    deadline = time.monotonic() + args.timeout

    def run(arguments):
        result = subprocess.run([*hdc, *arguments], env=hdc_env, capture_output=True, text=True, timeout=20)
        with (root / 'boot.log').open('a') as log:
            log.write(json.dumps({'arguments': arguments, 'exitCode': result.returncode,
                                  'output': result.stdout + result.stderr}) + '\n')
        return result.stdout if result.returncode == 0 else ''

    try:
        run(['start'])
        while time.monotonic() < deadline:
            if process.poll() is not None:
                raise RuntimeError('OHOS QEMU exited: ' + str(root / 'qemu.log'))
            try:
                run(['tconn', target])
                ready = run(['-t', target, 'shell', 'echo "bootevent.account.ready=$(param get bootevent.account.ready)"; hidumper -s AccountMgr -a "-os_account_infos"'])
                if account_ready(ready):
                    raw = run(['-t', target, 'shell', 'bm get --udid'])
                    udid = re.search(r'^\s*([0-9a-fA-F]{64})\s*$', raw, re.M)
                    uname = run(['-t', target, 'shell', 'uname -a'])
                    machine = 'x86_64' if args.arch == 'x86_64' else 'aarch64'
                    if udid and 'Toybox' in uname and machine in uname:
                        greeting, status = qmp_command(qmp, 'query-status')
                        if not status.get('running'):
                            raise RuntimeError('OHOS QEMU is not running')
                        if args.accel == 'kvm':
                            _, kvm = qmp_command(qmp, 'query-kvm')
                            if not kvm.get('enabled'):
                                raise RuntimeError('QEMU did not enable KVM')
                            state['kvm'] = kvm
                        state.update(udid=udid[1], uname=uname, qemu=greeting, qemuStatus=status,
                                     accountState=ready)
                        state_path.write_text(json.dumps(state, indent=2))
                        print(state_path, flush=True)
                        return
            except subprocess.TimeoutExpired:
                pass
            time.sleep(3)
        raise RuntimeError('OHOS HDC/account/UDID readiness timed out: ' + str(root / 'boot.log'))
    except BaseException:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
            process.wait(timeout=20)
        raise


if __name__ == '__main__':
    main()
