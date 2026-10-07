#!/usr/bin/env python3
"""Download the pinned official OpenHarmony QEMU development signing tools."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

REVISION = '013eae8637d5e853276e57ebc8921dbd8262ce34'
BASE_URL = 'https://raw.githubusercontent.com/openharmony/developtools_hapsigner/' + REVISION + '/dist/'
FILES = {
    'OpenHarmony.p12': '7a5efc3ea9245596d157f6ccbbdc5b8ae7cd714e7086c3c1645986c9d495d071',
    'OpenHarmonyApplication.pem': 'b5c1d6254faa91eab645a32fc3ce136128c94d88a739a0e956e6a49b331387e5',
    'OpenHarmonyProfileDebug.pem': 'a7232bdad96a24bf8c5ac3460cd8163b4af605e38ce8a14d9381572ce1ea0344',
    'UnsgnedDebugProfileTemplate.json': 'e7793d8501b56137b625e66ae8ff832adbbaf95b6e7c8440282c9423d174d16f',
    'hap-sign-tool.jar': 'a434b6747e6c5d0b14e73837a46b39f4816ab25b42d1833d6f767bf867cf616d',
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    for name, expected in FILES.items():
        path = args.output / name
        if path.is_file() and hashlib.sha256(path.read_bytes()).hexdigest() == expected:
            continue
        subprocess.run(['curl', '-fL', '--connect-timeout', '30', '--max-time', '180',
                        '--retry', '3', '--retry-delay', '2', '--retry-all-errors',
                        '--output', str(path), BASE_URL + name], check=True)
        if hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            raise RuntimeError('OpenHarmony signer SHA256 mismatch: ' + name)
    (args.output / 'signer.json').write_text(json.dumps({'revision': REVISION, 'baseUrl': BASE_URL,
                                                       'sha256': FILES}, indent=2))


if __name__ == '__main__':
    main()
