#!/usr/bin/env python3
"""Build a real UIAbility HAP running the shared zig-napi E2E suites."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sdk', type=Path, required=True)
    parser.add_argument('--library', type=Path, required=True)
    parser.add_argument('--declaration', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--arkdown', default='arkdown')
    parser.add_argument('--abi', choices=['arm64-v8a', 'armeabi-v7a', 'x86_64'], default='arm64-v8a')
    parser.add_argument('--run-id', default=uuid.uuid4().hex)
    parser.add_argument('--suite', choices=['basic', 'allocator-builtin', 'allocator-custom', 'init', 'memory'], default='basic')
    args = parser.parse_args()
    if len(args.run_id) != 32 or any(c not in '0123456789abcdef' for c in args.run_id):
        parser.error('--run-id must be 32 lowercase hexadecimal characters')
    root = args.output.resolve()
    root.mkdir(parents=True, exist_ok=True)
    repo = Path(__file__).resolve().parents[2]
    bundle = 'org.harmonycontrib.zignapie2e'

    def write(name, data):
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(data if isinstance(data, str) else json.dumps(data, indent=2) + '\n')

    write('AppScope/app.json5', {'app': {'bundleName': bundle, 'vendor': 'harmony-contrib', 'versionCode': 1, 'versionName': '1.0.0', 'icon': '$media:icon', 'label': '$string:app_name'}})
    write('AppScope/resources/base/element/string.json', {'string': [{'name': 'app_name', 'value': 'zig-napi E2E'}]})
    write('AppScope/resources/base/media/icon.svg', '<svg xmlns="http://www.w3.org/2000/svg" width="128" height="128"><rect width="128" height="128" fill="#315dad"/></svg>')
    write('build-profile.json5', {'app': {'products': [{'name': 'default', 'targetSdkVersion': '7.0.0(26)', 'compatibleSdkVersion': '5.0.5(17)', 'runtimeOS': 'HarmonyOS'}], 'buildModeSet': [{'name': 'debug'}, {'name': 'release'}]}, 'modules': [{'name': 'entry', 'srcPath': './entry', 'targets': [{'name': 'default', 'applyToProducts': ['default']}]}]})
    write('oh-package.json5', {'modelVersion': '6.0.0', 'name': 'zig-napi-e2e', 'version': '1.0.0', 'dependencies': {}})
    write('entry/oh-package.json5', {'modelVersion': '6.0.0', 'name': 'entry', 'version': '1.0.0', 'dependencies': {'libhello.so': 'file:./src/main/cpp/types/libhello'}})
    write('entry/src/main/cpp/types/libhello/oh-package.json5', {'name': 'libhello.so', 'version': '1.0.0', 'types': './index.d.ts'})
    shutil.copy2(args.declaration, root / 'entry/src/main/cpp/types/libhello/index.d.ts')
    write('entry/build-profile.json5', {'apiType': 'stageMode', 'buildOption': {'externalNativeOptions': {'abiFilters': [args.abi]}}, 'targets': [{'name': 'default'}]})
    write('entry/src/main/module.json5', {'module': {'name': 'entry', 'type': 'entry', 'mainElement': 'EntryAbility', 'deviceTypes': ['phone', '2in1'], 'deliveryWithInstall': True, 'installationFree': False, 'pages': '$profile:main_pages', 'abilities': [{'name': 'EntryAbility', 'srcEntry': './ets/entryability/EntryAbility.ets', 'exported': True, 'label': '$string:app_name', 'icon': '$media:icon', 'startWindowIcon': '$media:icon', 'startWindowBackground': '$color:background'}]}})
    write('entry/src/main/resources/base/element/color.json', {'color': [{'name': 'background', 'value': '#ffffff'}]})
    write('entry/src/main/resources/base/profile/main_pages.json', {'src': ['pages/Index']})
    write('entry/src/main/ets/pages/Index.ets', '@Entry\n@Component\nstruct Index { build() { Column() { Text("zig-napi E2E") } } }\n')
    write('entry/src/main/ets/entryability/EntryAbility.ets', '''import { UIAbility } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { startTests } from '../test/runner';
export default class EntryAbility extends UIAbility {
  onCreate(): void { startTests(this.context.filesDir); }
  onWindowStageCreate(stage: window.WindowStage): void { stage.loadContent('pages/Index'); }
}
''')
    test_dir = root / 'entry/src/main/ets/test'
    test_dir.mkdir(parents=True, exist_ok=True)
    for file in (repo / 'test').glob('*.spec.ts'):
        shutil.copy2(file, test_dir / file.name)
    for name in ['assert.ts', 'suite.ts']:
        shutil.copy2(repo / 'test' / name, test_dir / name)
    if args.suite == 'basic':
        groups = ['primitives', 'objects-arrays', 'binary', 'functions-classes', 'external', 'async', 'unions-enums', 'errors-tsfn', 'parity', 'parity-protocols', 'parity-lifetimes', 'parity-streams']
    elif args.suite == 'memory':
        for name in ['assert.ts', 'support.ts', 'sync.ts', 'binary.ts', 'async.ts', 'finalizers.ts', 'tracker.ts']:
            shutil.copy2(repo / 'memory-testing' / name, test_dir / name)
        write('entry/src/main/ets/test/native.ts', 'export { delay, settleFinalizers, withLeakTracking } from "./support";\n')
        write('entry/src/main/ets/test/suite.ts', '''import { exerciseAsyncWrappers, exerciseThreadSafeFunctionWrapper } from './async';
import { exerciseBinaryWrappers } from './binary';
import { exerciseFinalizerWrappers } from './finalizers';
import { withLeakTracking, settleFinalizers } from './support';
import { exerciseSyncWrappers } from './sync';
import { exerciseLeakTrackerLifecycle } from './tracker';
import { assertEqual } from './assert';
export async function runBasicSuite(native: ESObject, _: string, report: (name: string) => void) {
  await exerciseLeakTrackerLifecycle(native); report('memory-tracker');
  await withLeakTracking(native, 'sync', () => { exerciseSyncWrappers(native); exerciseBinaryWrappers(native); }); report('memory-sync-binary');
  exerciseFinalizerWrappers(native);
  const deadline = Date.now() + 30000;
  while (!native.finalizer_stats().complete && Date.now() < deadline) await settleFinalizers(1);
  assertEqual(native.finalizer_stats().external, 128, 'external finalizers');
  assertEqual(native.finalizer_stats().classes, 96, 'class finalizers');
  report('memory-finalizers');
  await withLeakTracking(native, 'async', () => exerciseAsyncWrappers(native)); report('memory-async');
  await exerciseThreadSafeFunctionWrapper(native); report('memory-tsfn');
}
''')
        groups = ['memory-tracker', 'memory-sync-binary', 'memory-finalizers', 'memory-async', 'memory-tsfn']
    else:
        source = (repo / 'test' / (args.suite + '.ts')).read_text()
        imports = source[:source.index('runSuite(')].replace('import { runSuite } from "./native";\n', '')
        body = source[source.index('=> {') + 4:source.rindex('});')]
        write('entry/src/main/ets/test/suite.ts', imports + '\nexport async function runBasicSuite(native: ESObject, _: string, report: (name: string) => void) {\n' + body + '\nreport(' + json.dumps(args.suite) + ');\n}\n')
        groups = [args.suite]
    write('entry/src/main/ets/test/runner.ts', '''import * as native from 'libhello.so';
import fs from '@ohos.file.fs';
import { runBasicSuite } from './suite';
export function startTests(directory: string) {
  const groups: string[] = [];
  let finished = false;
  let timer: number;
  const resultPath = directory + '/zig-napi-results.json';
  function complete(status: string, error: string) {
    if (finished) return;
    finished = true;
    clearTimeout(timer);
    const result = { runId: RUN_ID, status, error, groups, groupCount: groups.length };
    const file = fs.openSync(resultPath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    fs.writeSync(file.fd, JSON.stringify(result));
    fs.closeSync(file);
    console.info('__ZIG_NAPI_QEMU_RESULT__ ' + JSON.stringify(result));
  }
  timer = setTimeout(() => complete('fail', 'E2E timed out'), 120000);
  try {
    const fixtures = directory + '/fixtures';
    if (!fs.accessSync(fixtures)) fs.mkdirSync(fixtures);
    for (const pair of [['first.txt', 'alpha\\n'], ['second.txt', 'bravo\\n']]) {
      const file = fs.openSync(fixtures + '/' + pair[0], fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, pair[1]); fs.closeSync(file);
    }
    runBasicSuite(native, fixtures, (name: string) => {
      groups.push(name);
      console.info('__ZIG_NAPI_QEMU_GROUP__ ' + name);
    }).then(() => complete('ok', ''), (err) => complete('fail', String(err && (err.message || err)) + " | " + String(err && err.stack || "")));
  } catch (err) { complete('fail', String(err && (err.message || err)) + " | " + String(err && err.stack || "")); }
}
'''.replace('RUN_ID', json.dumps(args.run_id)))
    libs = root / 'entry/libs' / args.abi
    libs.mkdir(parents=True, exist_ok=True)
    shutil.copy2(args.library, libs / 'libhello.so')
    manifest = {'runId': args.run_id, 'bundle': bundle, 'abi': args.abi, 'suite': args.suite, 'library': str(args.library.resolve()), 'groups': groups}
    write('e2e-manifest.json', manifest)
    subprocess.run([args.arkdown, 'build', '--project', str(root), '--target', 'hap', '--mode', 'debug', '--skip-checker'], cwd=root, env=dict(os.environ, OHOS_SDK_HOME=str(args.sdk.resolve())), check=True)
    print(root / 'entry/build/default/outputs/default/entry-default-unsigned.hap')


if __name__ == '__main__':
    main()
