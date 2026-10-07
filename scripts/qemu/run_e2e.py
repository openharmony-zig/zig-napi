#!/usr/bin/env python3
"""Install/start the E2E HAP inside a running OHOS QEMU and verify fresh results."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import socket
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--hdc', default='hdc')
    parser.add_argument('--server', help='Existing HDC server port/address')
    parser.add_argument('--target', required=True)
    parser.add_argument('--qmp', type=Path, required=True, help='QMP socket of the running OHOS QEMU')
    parser.add_argument('--hap', type=Path, required=True)
    parser.add_argument('--manifest', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--repeat', type=int, default=3)
    args = parser.parse_args()
    if not 1 <= args.repeat <= 20:
        parser.error('--repeat must be between 1 and 20')
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    manifest = json.loads(args.manifest.read_text())
    bundle = manifest['bundle']
    if not re.fullmatch(r'[A-Za-z][A-Za-z0-9_.]+', bundle):
        parser.error('invalid manifest bundle name')
    hdc = [args.hdc]
    if args.server:
        hdc += ['-s', args.server]
    hdc += ['-t', args.target]
    commands = []

    def unlock_screen():
        # Only handle the ordinary swipe lock screen. Credentials are never
        # supplied and a remaining lock remains a hard launch failure.
        screen = output / 'locked-screen.ppm'
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            sock.settimeout(10)
            sock.connect(str(args.qmp))
            reader = sock.makefile('r')
            reader.readline()
            for command in [{'execute': 'qmp_capabilities'}, {'execute': 'screendump', 'arguments': {'filename': str(screen)}}]:
                sock.sendall((json.dumps(command) + '\n').encode())
                while True:
                    response = json.loads(reader.readline())
                    if 'error' in response:
                        raise RuntimeError('QEMU screenshot failed: ' + json.dumps(response))
                    if 'return' in response:
                        break
            reader.close()
        with screen.open('rb') as image:
            if image.readline().strip() != b'P6':
                raise RuntimeError('Unexpected QEMU screenshot format')
            dimensions = image.readline()
            while dimensions.startswith(b'#'):
                dimensions = image.readline()
            width, height = map(int, dimensions.split())
        run(['shell', f'uinput -T -m {width // 2} {height * 92 // 100} {width // 2} {height * 16 // 100} 500'])
        time.sleep(1)

    def run(arguments, timeout=30):
        command = hdc + arguments
        result = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
        commands.append({'command': command, 'exitCode': result.returncode, 'output': result.stdout})
        (output / 'commands.json').write_text(json.dumps(commands, indent=2))
        if result.returncode != 0:
            raise RuntimeError(result.stdout)
        return result.stdout

    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.settimeout(10)
        sock.connect(str(args.qmp))
        reader = sock.makefile('r')
        greeting = json.loads(reader.readline())
        sock.sendall(b'{"execute":"qmp_capabilities"}\n')
        while 'return' not in json.loads(reader.readline()):
            pass
        sock.sendall(b'{"execute":"query-status"}\n')
        while True:
            status = json.loads(reader.readline())
            if 'return' in status:
                break
        reader.close()
        if not status['return']['running']:
            raise RuntimeError('OHOS QEMU is not running')
    guest = run(['shell', 'uname -a'])
    if 'Linux' not in guest or 'Toybox' not in guest:
        raise RuntimeError('HDC target is not an OpenHarmony guest')
    machine = {'arm64-v8a': 'aarch64', 'armeabi-v7a': 'armv7l', 'x86_64': 'x86_64'}[manifest['abi']]
    if not re.search(r'\b' + machine + r'\b', guest):
        raise RuntimeError('OHOS guest architecture does not match the HAP ABI: ' + manifest['abi'])
    installed = run(['install', '-r', str(args.hap.resolve())], timeout=90)
    (output / 'install.log').write_text(installed)
    if not re.search(r'success', installed, re.I) or re.search(r'\[Fail\]|failed', installed, re.I):
        raise RuntimeError('HAP install did not succeed: ' + installed)
    result_path = '/data/app/el2/100/base/' + bundle + '/haps/entry/files/zig-napi-results.json'
    runs = []
    for index in range(args.repeat):
        run(['shell', f'aa force-stop {bundle}'])
        run(['shell', f'rm -f {result_path}'])
        run(['shell', 'power-shell wakeup'])
        launched = run(['shell', f'aa start -a EntryAbility -b {bundle}'])
        if '10106102' in launched:
            unlock_screen()
            launched = run(['shell', f'aa start -a EntryAbility -b {bundle}'])
        if 'success' not in launched.lower():
            raise RuntimeError('Ability did not start: ' + launched)
        deadline = time.monotonic() + 150
        result = None
        while time.monotonic() < deadline:
            raw = run(['shell', f'cat {result_path}'])
            try:
                result = json.loads(raw.strip())
                break
            except json.JSONDecodeError:
                time.sleep(1)
        if result is None:
            raise RuntimeError('QEMU E2E did not publish a result within 150 seconds')
        (output / f'result-{index + 1}.json').write_text(json.dumps(result, indent=2))
        runs.append(result)
        if result.get('runId') != manifest['runId'] or result.get('status') != 'ok' or result.get('groups') != manifest['groups'] or result.get('groupCount') != len(manifest['groups']):
            raise RuntimeError('QEMU E2E failed: ' + json.dumps(result))
        print(f"QEMU E2E run {index + 1}: {result['groupCount']} groups passed", flush=True)
    evidence = {'qmp': greeting, 'qemuStatus': status['return'], 'guest': guest.strip(), 'hapSha256': hashlib.sha256(args.hap.read_bytes()).hexdigest(), 'manifest': manifest, 'runs': runs}
    (output / 'evidence.json').write_text(json.dumps(evidence, indent=2))
    log = run(['shell', 'hilog -x'], timeout=30)
    (output / 'hilog.log').write_text('\n'.join(line for line in log.splitlines() if '__ZIG_NAPI_QEMU_' in line or bundle in line))
    print(output / 'evidence.json')


if __name__ == '__main__':
    main()
