#!/usr/bin/env python3
"""Build the selected products and require real Node/OHOS QEMU E2E results."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--product', choices=['both', 'node', 'ohos'], default='both')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--ohos-zig')
    parser.add_argument('--ohos-arch', choices=['arm64', 'x86_64'])
    parser.add_argument('--ohos-guest', type=Path, help='guest.json from boot_ohos_guest.py supplies the live QEMU connection')
    parser.add_argument('--node-zig', default='zig')
    parser.add_argument('--ndk', type=Path)
    parser.add_argument('--sdk', type=Path)
    parser.add_argument('--signer-dist', type=Path)
    parser.add_argument('--signer-image', help='Optional Linux Docker image for signing on macOS; Linux CI signs directly with Java')
    parser.add_argument('--udid')
    parser.add_argument('--hdc', default='hdc')
    parser.add_argument('--server')
    parser.add_argument('--target')
    parser.add_argument('--qmp', type=Path)
    parser.add_argument('--node-guest', type=Path)
    parser.add_argument('--node-archive', type=Path)
    parser.add_argument('--node-shasums', type=Path)
    parser.add_argument('--zig-archive', type=Path, help='Optional local official Zig 0.16 Linux x64 archive for the Node guest')
    parser.add_argument('--repeat', type=int, default=3)
    args = parser.parse_args()
    ohos_guest = None
    if args.ohos_guest:
        ohos_guest = json.loads(args.ohos_guest.read_text())
        if args.ohos_arch and args.ohos_arch != ohos_guest['architecture']:
            parser.error('--ohos-arch does not match the booted guest')
        args.ohos_arch = ohos_guest['architecture']
        for name in ['hdc', 'server', 'target', 'udid']:
            setattr(args, name, ohos_guest[name])
        args.qmp = Path(ohos_guest['qmp'])
    args.ohos_arch = args.ohos_arch or 'arm64'
    required = []
    if args.product in ('both', 'ohos'):
        required += ['ohos_zig', 'ndk', 'sdk', 'signer_dist', 'udid', 'target', 'qmp']
    if args.product in ('both', 'node'):
        required += ['node_guest', 'node_archive', 'node_shasums']
    for name in required:
        if getattr(args, name) is None:
            parser.error('--' + name.replace('_', '-') + ' is required for ' + args.product)
    if not 1 <= args.repeat <= 20:
        parser.error('--repeat must be between 1 and 20')
    repo = Path(__file__).resolve().parents[2]
    output = args.output.resolve()
    if args.signer_image:
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

    suites = ['basic', 'allocator-builtin', 'allocator-custom', 'init', 'memory'] if args.product in ('both', 'ohos') else []
    evidence = {}
    target, abi = {'arm64': ('aarch64-linux-ohos', 'arm64-v8a'), 'x86_64': ('x86_64-linux-ohos', 'x86_64')}[args.ohos_arch]
    for suite in suites:
        env = dict(os.environ, OHOS_NDK_HOME=str(args.ndk.resolve()))
        example = repo / 'examples' / suite
        install = output / ('ohos-' + suite)
        run('build-ohos-' + suite, [args.ohos_zig, 'build', '-Dtarget=' + target, '-Doptimize=ReleaseSafe', '--prefix', install, '--summary', 'all'], example, env)
        library = install / abi / 'libhello.so'
        # OHOS native libraries are code-signed by the official HAP signer
        # below (-signCode 1); the Node CLI has no OHOS signing dependency.
        hap_root = output / ('hap-' + suite)
        run('build-hap-' + suite, [sys.executable, scripts / 'build_hap.py', '--sdk', args.sdk, '--library', library, '--declaration', example / 'index.d.ts', '--suite', suite, '--abi', abi, '--output', hap_root])
        signed = output / (suite + '-signed.hap')
        unsigned = hap_root / 'entry/build/default/outputs/default/entry-default-unsigned.hap'
        if args.signer_image:
            sign = ['docker', 'run', '--rm', '--name', 'zig-napi-matrix-sign-' + suite, '-v', str(repo) + ':/work', '-v', str(args.signer_dist.resolve()) + ':/signer:ro', args.signer_image, 'python3', '/work/scripts/qemu/sign_hap.py', '--signer-dist', '/signer', '--unsigned', '/work/' + str(unsigned.relative_to(repo)), '--output', '/work/' + str(signed.relative_to(repo))]
        else:
            sign = [sys.executable, scripts / 'sign_hap.py', '--signer-dist', args.signer_dist, '--unsigned', unsigned, '--output', signed]
        run('sign-hap-' + suite, [*sign, '--bundle-name', 'org.harmonycontrib.zignapie2e', '--udid', args.udid])
        result = output / ('results-' + suite)
        command = [sys.executable, scripts / 'run_e2e.py', '--hdc', args.hdc, '--target', args.target, '--qmp', args.qmp, '--hap', signed, '--manifest', hap_root / 'e2e-manifest.json', '--output', result, '--repeat', args.repeat]
        if args.server:
            command += ['--server', args.server]
        run('e2e-ohos-' + suite, command)
        evidence[suite] = json.loads((result / 'evidence.json').read_text())

    run('check-declarations', ['node', repo / 'scripts/check_declarations.cjs'])

    if args.product in ('both', 'node'):
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
    revision = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=repo, text=True).strip()
    (output / 'matrix.json').write_text(json.dumps({'revision': revision, 'product': args.product, 'ohosGuest': ohos_guest, 'sourceSha256': source, 'evidence': evidence, 'commands': commands}, indent=2))
    print(output / 'matrix.json', flush=True)


if __name__ == '__main__':
    main()
