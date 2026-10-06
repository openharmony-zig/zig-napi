#!/usr/bin/env python3
"""Build both products and require real Node and OHOS QEMU E2E results."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--ohos-zig', required=True)
    parser.add_argument('--node-zig', default='zig')
    parser.add_argument('--ndk', type=Path, required=True)
    parser.add_argument('--sdk', type=Path, required=True)
    parser.add_argument('--signer-dist', type=Path, required=True)
    parser.add_argument('--signer-image', default='ohos-qemu-build-env:7.0-release')
    parser.add_argument('--udid', required=True)
    parser.add_argument('--hdc', default='hdc')
    parser.add_argument('--server')
    parser.add_argument('--target', required=True)
    parser.add_argument('--qmp', type=Path, required=True)
    parser.add_argument('--node-guest', type=Path, required=True)
    parser.add_argument('--node-archive', type=Path, required=True)
    parser.add_argument('--node-shasums', type=Path, required=True)
    parser.add_argument('--zig-archive', type=Path, help='Optional local official Zig 0.16 Linux x64 archive for the Node guest')
    parser.add_argument('--repeat', type=int, default=3)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[2]
    output = args.output.resolve()
    # Signing runs in Linux because macOS JDK17 rejects the SDK's ZIP64 output.
    output.relative_to(repo)
    output.mkdir(parents=True, exist_ok=True)
    scripts = repo / 'scripts' / 'qemu'
    commands = []

    def run(name, command, cwd=repo, env=None):
        print(name, flush=True)
        with (output / (name + '.log')).open('w') as log:
            result = subprocess.run([str(x) for x in command], cwd=cwd, env=env, stdout=log, stderr=subprocess.STDOUT)
        commands.append({'name': name, 'command': [str(x) for x in command], 'cwd': str(cwd), 'exitCode': result.returncode})
        (output / 'commands.json').write_text(json.dumps(commands, indent=2))
        if result.returncode:
            raise RuntimeError(f'{name} failed: {output / (name + ".log")}')

    env = dict(os.environ, OHOS_NDK_HOME=str(args.ndk.resolve()))
    suites = ['basic', 'allocator-builtin', 'allocator-custom', 'init', 'memory']
    evidence = {}
    for suite in suites:
        example = repo / 'examples' / suite
        run('build-ohos-' + suite, [args.ohos_zig, 'build', '-Dtarget=aarch64-linux-ohos', '-Doptimize=ReleaseSafe', '--summary', 'all'], example, env)
        library = example / 'zig-out' / 'arm64-v8a' / 'libhello.so'
        run('selfsign-ohos-' + suite, ['node', '-e', 'const s=require(process.argv[1]);s.signFileAtomic(process.argv[2],true);if(!s.checkSelfsign(require("node:fs").readFileSync(process.argv[2])).ok)process.exit(1)', repo / 'packages/zig-napi/bin/ohos-selfsign.cjs', library])
        hap_root = output / ('hap-' + suite)
        run('build-hap-' + suite, [sys.executable, scripts / 'build_hap.py', '--sdk', args.sdk, '--library', library, '--declaration', example / 'index.d.ts', '--suite', suite, '--output', hap_root])
        signed = output / (suite + '-signed.hap')
        unsigned = hap_root / 'entry/build/default/outputs/default/entry-default-unsigned.hap'
        run('sign-hap-' + suite, ['docker', 'run', '--rm', '--name', 'zig-napi-matrix-sign-' + suite, '-v', str(repo) + ':/work', '-v', str(args.signer_dist.resolve()) + ':/signer:ro', args.signer_image, 'python3', '/work/scripts/qemu/sign_hap.py', '--signer-dist', '/signer', '--unsigned', '/work/' + str(unsigned.relative_to(repo)), '--output', '/work/' + str(signed.relative_to(repo)), '--bundle-name', 'org.harmonycontrib.zignapie2e', '--udid', args.udid])
        result = output / ('results-' + suite)
        command = [sys.executable, scripts / 'run_e2e.py', '--hdc', args.hdc, '--target', args.target, '--qmp', args.qmp, '--hap', signed, '--manifest', hap_root / 'e2e-manifest.json', '--output', result, '--repeat', args.repeat]
        if args.server:
            command += ['--server', args.server]
        run('e2e-ohos-' + suite, command)
        evidence[suite] = json.loads((result / 'evidence.json').read_text())

    run('check-declarations', ['node', repo / 'scripts/check_declarations.cjs'])

    node_tests = repo / 'node-test'
    cli = repo / 'packages/zig-napi/bin/zig-napi.js'
    run('build-wasi-threads', ['node', cli, 'build', '--target', 'wasm32-wasi'], node_tests)
    run('build-wasi-single', ['node', cli, 'build', '--target', 'wasm32-wasip1'], node_tests)
    oom = output / 'wasm-oom'
    oom_install = output / 'oom-install'
    run('build-wasi-oom', ['node', cli, 'build', '--target', 'wasm32-wasi', '--output-dir', oom_install / 'node', '--build-output-dir', oom, '--', '--prefix', oom_install, '-Dwasi-max-memory-pages=1024'], node_tests)
    native = output / 'node-linux'
    run('build-node-linux', [args.node_zig, 'build', '-Dtarget=x86_64-linux-gnu', '-Dnapi-version=10', '--prefix', native, '--summary', 'all'], node_tests)
    result = output / 'results-node'
    node_command = [sys.executable, scripts / 'run_node_e2e.py', '--guest', args.node_guest, '--artifacts', native / 'node', '--wasm-oom', oom / 'async_tasks.wasm32-wasi.wasm', '--node-archive', args.node_archive, '--node-shasums', args.node_shasums, '--output', result, '--repeat', args.repeat]
    if args.zig_archive:
        node_command += ['--zig-archive', args.zig_archive]
    run('e2e-node', node_command)
    evidence['node'] = json.loads((result / 'evidence.json').read_text())
    source = {}
    files = subprocess.check_output(['git', 'ls-files', '-m', '-o', '--exclude-standard'], cwd=repo, text=True).splitlines()
    for name in sorted(set(files)):
        path = repo / name
        if path.is_file():
            source[name] = hashlib.sha256(path.read_bytes()).hexdigest()
    (output / 'matrix.json').write_text(json.dumps({'sourceSha256': source, 'evidence': evidence, 'commands': commands}, indent=2))
    print(output / 'matrix.json', flush=True)


if __name__ == '__main__':
    main()
