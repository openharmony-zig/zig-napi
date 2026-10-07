#!/usr/bin/env python3
"""Build and test Node.js native/WASI products directly on the current host."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--repeat', type=int, default=3)
    args = parser.parse_args()
    if not 1 <= args.repeat <= 20:
        parser.error('--repeat must be between 1 and 20')
    repo = Path(__file__).resolve().parents[1]
    tests = repo / 'node-test'
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    commands = []

    def run(name, command, cwd=tests, env=None, timeout=900):
        print(name, flush=True)
        log_path = output / (name + '.log')
        with log_path.open('w') as log:
            result = subprocess.run([str(x) for x in command], cwd=cwd, env=env,
                                    stdout=log, stderr=subprocess.STDOUT, timeout=timeout)
        commands.append({'name': name, 'command': [str(x) for x in command],
                         'cwd': str(cwd), 'exitCode': result.returncode})
        (output / 'commands.json').write_text(json.dumps(commands, indent=2))
        if result.returncode:
            raise RuntimeError(f'{name} failed: {log_path}')
        return log_path.read_text()

    cli = repo / 'packages/zig-napi/bin/zig-napi.js'
    run('build-wasi-threads', ['node', cli, 'build', '--target', 'wasm32-wasip1-threads'])
    run('build-wasi-single', ['node', cli, 'build', '--target', 'wasm32-wasip1'])
    oom = output / 'wasm-oom'
    install = output / 'oom-install'
    run('build-wasi-oom', ['node', cli, 'build', '--target', 'wasm32-wasip1-threads',
                         '--output-dir', install / 'node', '--build-output-dir', oom,
                         '--', '--prefix', install, '-Dwasi-max-memory-pages=1024'])
    run('build-node-native', ['zig', 'build', '-Dnapi-version=10', '--summary', 'all'])
    run('check-declarations', ['node', repo / 'scripts/check_declarations.cjs'], cwd=repo)

    # Native tests must load the host addons; WASI lifecycle cases load their
    # two actual artifacts explicitly. Use the ordinary host timeout budgets.
    env = dict(os.environ)
    for name in ['NAPI_RS_FORCE_WASI', 'NAPI_RS_WASI_FLAVOR', 'ZIG_NAPI_WASI_FLAVOR',
                 'ZIG_NAPI_WASM_ARTIFACT_ROOT', 'ZIG_NAPI_TEST_TIMEOUT_MULTIPLIER']:
        env.pop(name, None)
    env['ZIG_NAPI_WASM_OOM_ARTIFACT_ROOT'] = str(oom)
    report = run('wasm-acceptance', ['node', '--test', '--test-reporter=tap',
                                   '--test-timeout=300000', 'wasm/abi.test.cjs',
                                   'wasm/concurrency.test.cjs', 'wasm/crash.test.cjs',
                                   'wasm/strings.test.cjs'], env=env)
    passed = re.search(r'^# pass (\d+)$', report, re.M)
    skipped = re.search(r'^# skipped (\d+)$', report, re.M)
    if not passed or int(passed[1]) < 10 or not skipped or int(skipped[1]) != 0:
        raise RuntimeError('WASI acceptance was incomplete: ' + str(output / 'wasm-acceptance.log'))
    runs = []
    for index in range(args.repeat):
        report = run(f'native-{index + 1}', ['node', 'node_modules/ava/cli.js',
                                           '--serial', '--timeout=120s'], env=env)
        native_passed = re.search(r'(\d+) tests? passed', report)
        native_skipped = re.search(r'(\d+) tests? skipped', report)
        record = {'exitCode': 0, 'passed': int(native_passed[1]) if native_passed else 0,
                  'skipped': int(native_skipped[1]) if native_skipped else 0}
        runs.append(record)
        if record['passed'] < 277 or record['skipped'] != 0:
            raise RuntimeError('Node acceptance was incomplete: ' + str(output / f'native-{index + 1}.log'))
        print(f"Node host run {index + 1}: {record['passed']} tests passed with zero skips", flush=True)

    environment = json.loads(subprocess.check_output([
        'node', '-p', 'JSON.stringify({version:process.version,arch:process.arch,platform:process.platform,napi:process.versions.napi})'
    ], text=True))
    artifacts = sorted(tests.glob('*.node')) + sorted(tests.glob('*.wasm')) + [oom / 'async_tasks.wasm32-wasi.wasm']
    evidence = {
        'revision': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=repo, text=True).strip(),
        'execution': 'host', 'environment': environment,
        'zigVersion': subprocess.check_output(['zig', 'version'], text=True).strip(),
        'artifactsSha256': {str(p.relative_to(repo)) if p.is_relative_to(repo) else str(p):
                            hashlib.sha256(p.read_bytes()).hexdigest() for p in artifacts},
        'runs': runs, 'wasmPassed': int(passed[1]), 'wasmSkipped': int(skipped[1]), 'commands': commands,
    }
    (output / 'evidence.json').write_text(json.dumps(evidence, indent=2))
    print(output / 'evidence.json')


if __name__ == '__main__':
    main()
