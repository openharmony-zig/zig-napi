#!/usr/bin/env python3
"""Run the real native Node.js suite in an SSH-accessible Linux QEMU guest."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shlex
import shutil
import socket
import subprocess
import tarfile
import urllib.request
import uuid

ZIG_URL = 'https://ziglang.org/download/0.16.0/zig-x86_64-linux-0.16.0.tar.xz'
ZIG_SHA256 = '70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00'

# Bound TCG inactivity while preserving 32,000 throwing conversion calls.
# Each whole native round still has its independent 900-second deadline.
NATIVE_INACTIVITY_TIMEOUT_SECONDS = 600


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--guest', type=Path, required=True, help='guest.json from boot_node_guest.py')
    parser.add_argument('--artifacts', type=Path, required=True)
    parser.add_argument('--node-archive', type=Path, required=True)
    parser.add_argument('--node-shasums', type=Path, required=True, help='official Node.js SHASUMS256.txt')
    parser.add_argument('--node-archive-name', default='node-v24.14.0-linux-x64.tar.xz')
    parser.add_argument('--zig-archive', type=Path, help='Official Zig 0.16 Linux x64 archive; otherwise download the pinned release')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--wasm-oom', type=Path, required=True, help='small-memory async_tasks.wasm32-wasi.wasm')
    parser.add_argument('--repeat', type=int, default=1)
    args = parser.parse_args()
    if not 1 <= args.repeat <= 20:
        parser.error('--repeat must be between 1 and 20')
    guest = json.loads(args.guest.read_text())
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    repo = Path(__file__).resolve().parents[2]
    expected = next(line.split()[0] for line in args.node_shasums.read_text().splitlines() if line.split()[-1] == args.node_archive_name)
    node_hash = hashlib.sha256(args.node_archive.read_bytes()).hexdigest()
    if expected != node_hash:
        raise RuntimeError('Node.js archive does not match the official SHA256 manifest')
    zig_archive = args.zig_archive or output / 'zig-x86_64-linux-0.16.0.tar.xz'
    if not zig_archive.exists():
        if args.zig_archive:
            raise FileNotFoundError(zig_archive)
        partial = zig_archive.with_suffix('.part')
        with urllib.request.urlopen(ZIG_URL, timeout=60) as response, partial.open('wb') as file:
            shutil.copyfileobj(response, file)
        partial.replace(zig_archive)
    zig_hash = hashlib.sha256(zig_archive.read_bytes()).hexdigest()
    if zig_hash != ZIG_SHA256:
        raise RuntimeError('Zig archive does not match the official Zig 0.16 SHA256')
    qmp_path = args.guest.resolve().parent / 'qmp.sock'
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.settimeout(10)
        sock.connect(str(qmp_path))
        with sock.makefile('r') as reader:
            greeting = json.loads(reader.readline())
            sock.sendall(b'{"execute":"qmp_capabilities"}\n')
            while 'return' not in json.loads(reader.readline()):
                pass
            sock.sendall(b'{"execute":"query-status"}\n')
            while True:
                status = json.loads(reader.readline())
                if 'return' in status:
                    break
    if not status['return']['running']:
        raise RuntimeError('Node QEMU is not running')
    connection = f"{guest['user']}@127.0.0.1"
    options = ['-i', guest['key'], '-o', 'StrictHostKeyChecking=accept-new', '-o', 'UserKnownHostsFile=' + str(args.guest.resolve().parent / 'known_hosts')]
    ssh = ['ssh', *options, '-p', str(guest['sshPort']), connection]
    scp = ['scp', *options, '-P', str(guest['sshPort'])]
    run_id = uuid.uuid4().hex
    remote = 'zig-napi-e2e-' + run_id
    artifacts = sorted(args.artifacts.glob('*.node'))
    if len(artifacts) != 6 or any('linux-x64-gnu' not in p.name for p in artifacts):
        raise RuntimeError('Expected all six Linux x64 GNU native addons')
    archive = output / 'tests.tar.gz'
    with tarfile.open(archive, 'w:gz') as tar:
        tests = repo / 'node-test'
        for file in sorted(tests.rglob('*')):
            if not file.is_file() or any(part in ['node_modules', '.zig-cache', 'zig-out'] for part in file.relative_to(tests).parts) or file.suffix == '.node':
                continue
            tar.add(file, arcname='node-test/' + str(file.relative_to(tests)))
        for directory in ['src', 'examples']:
            for file in sorted((repo / directory).rglob('*')):
                if file.is_file() and file.suffix in ['.zig', '.zon', '.h', '.c'] and not any(part in ['.zig-cache', 'zig-out', 'node_modules'] for part in file.relative_to(repo).parts):
                    tar.add(file, arcname=str(file.relative_to(repo)))
        for name in ['build.zig', 'build.zig.zon', 'LICENSE', 'README.md']:
            tar.add(repo / name, arcname=name)
        tar.add(args.wasm_oom, arcname='node-test/wasm-oom/async_tasks.wasm32-wasi.wasm')
        for file in artifacts:
            tar.add(file, arcname='node-test/' + file.name)
    hashes = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in artifacts}
    subprocess.run([*scp, str(archive), connection + ':' + remote + '.tar.gz'], check=True, timeout=180)
    subprocess.run([*scp, str(args.node_archive), connection + ':' + remote + '.node.tar.xz'], check=True, timeout=180)
    subprocess.run([*scp, str(zig_archive), connection + ':' + remote + '.zig.tar.xz'], check=True, timeout=180)
    bootstrap = f'mkdir -p {remote}/node {remote}/zig && tar -xzf {remote}.tar.gz -C {remote} && tar -xJf {remote}.node.tar.xz -C {remote}/node --strip-components=1 && tar -xJf {remote}.zig.tar.xz -C {remote}/zig --strip-components=1 && cd {remote}/node-test && export PATH="$PWD/../node/bin:$PWD/../zig:$PATH" && zig version && npm install --ignore-scripts --no-audit --no-fund'
    with (output / 'install.log').open('w') as log:
        subprocess.run([*ssh, bootstrap], stdout=log, stderr=subprocess.STDOUT, check=True, timeout=600)
    print('Node.js and native addons installed inside QEMU', flush=True)
    environment = subprocess.run([*ssh, 'cd ' + remote + ' && uname -a && zig/zig version && node/bin/node -p ' + shlex.quote('JSON.stringify({version:process.version,arch:process.arch,platform:process.platform,napi:process.versions.napi})')], capture_output=True, text=True, check=True, timeout=30).stdout
    acceptance = subprocess.run([*ssh, 'cd ' + remote + '/node-test && export PATH="$PWD/../node/bin:$PWD/../zig:$PATH" ZIG_NAPI_TEST_TIMEOUT_MULTIPLIER=5 ZIG_NAPI_WASM_OOM_ARTIFACT_ROOT="$PWD/wasm-oom" && node --test --test-reporter=tap --test-timeout=600000 wasm/abi.test.cjs wasm/concurrency.test.cjs wasm/crash.test.cjs wasm/strings.test.cjs'], capture_output=True, text=True, timeout=900)
    (output / 'wasm-acceptance.log').write_text(acceptance.stdout + acceptance.stderr)
    wasm_passed = re.search(r'^# pass (\d+)$', acceptance.stdout, re.M)
    wasm_skipped = re.search(r'^# skipped (\d+)$', acceptance.stdout, re.M)
    if acceptance.returncode != 0 or not wasm_passed or int(wasm_passed[1]) < 10 or not wasm_skipped or int(wasm_skipped[1]) != 0:
        raise RuntimeError('WASI QEMU acceptance failed; see ' + str(output / 'wasm-acceptance.log'))
    print(f'WASI QEMU acceptance: {wasm_passed[1]} tests passed with zero skips', flush=True)
    results = []
    for index in range(args.repeat):
        script = 'cd ' + remote + '/node-test && export PATH="$PWD/../node/bin:$PWD/../zig:$PATH" ZIG_NAPI_TEST_TIMEOUT_MULTIPLIER=5 && node node_modules/ava/cli.js --serial --timeout=' + str(NATIVE_INACTIVITY_TIMEOUT_SECONDS) + 's'
        log_path = output / f'native-{index + 1}.log'
        with log_path.open('w') as log:
            result = subprocess.run([*ssh, script], stdout=log, stderr=subprocess.STDOUT, timeout=900)
        report = log_path.read_text()
        passed = re.search(r'(\d+) tests passed', report)
        skipped = re.search(r'(\d+) tests skipped', report)
        record = {'runId': run_id, 'exitCode': result.returncode, 'passed': int(passed[1]) if passed else 0, 'skipped': int(skipped[1]) if skipped else 0}
        results.append(record)
        if result.returncode != 0 or record['passed'] < 277 or record['skipped'] != 0:
            raise RuntimeError('Node QEMU E2E failed; see ' + str(output / f'native-{index + 1}.log'))
        print(f"Node QEMU run {index + 1}: {record['passed']} tests passed", flush=True)
    evidence = {'qmp': greeting, 'qemuStatus': status['return'], 'guest': guest, 'environment': environment, 'nodeArchiveSha256': node_hash, 'zigArchiveSha256': zig_hash, 'zigArchiveUrl': ZIG_URL, 'nativeArtifactsSha256': hashes, 'testArchiveSha256': hashlib.sha256(archive.read_bytes()).hexdigest(), 'nativeInactivityTimeoutSeconds': NATIVE_INACTIVITY_TIMEOUT_SECONDS, 'runs': results, 'wasmAcceptanceExitCode': acceptance.returncode, 'wasmPassed': int(wasm_passed[1]), 'wasmSkipped': int(wasm_skipped[1]), 'wasmOomSha256': hashlib.sha256(args.wasm_oom.read_bytes()).hexdigest()}
    (output / 'evidence.json').write_text(json.dumps(evidence, indent=2))
    print(output / 'evidence.json')


if __name__ == '__main__':
    main()
