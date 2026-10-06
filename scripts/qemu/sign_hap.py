#!/usr/bin/env python3
"""Sign a local audit HAP with OpenHarmony's test keys and code-sign block.

Only for QEMU development images. The inputs under --signer-dist are the
public test credentials shipped with developtools/hapsigner, not release keys.
"""

import argparse
import json
from pathlib import Path
import subprocess
import tempfile
import time
import uuid
import zipfile


def verify_signed_hap(jar: str, signed: Path, directory: Path) -> None:
    # The pinned signer accepts .cer, not .pem, for this output. Require the
    # actual verification markers as well as exit status and extracted files.
    chain, profile = directory / "verified-chain.cer", directory / "verified-profile.p7b"
    completed = subprocess.run([
        "java", "-jar", jar, "verify-app", "-inFile", str(signed),
        "-outCertChain", str(chain), "-outProfile", str(profile),
    ], capture_output=True, text=True)
    log = completed.stdout + completed.stderr
    print(log, end="")
    required = ("verify codesign success", "Digest verify result: true", "verify permission sign success",
                "verify-app success")
    if (completed.returncode != 0 or any(marker not in log for marker in required) or
            not chain.is_file() or not chain.stat().st_size or not profile.is_file() or not profile.stat().st_size):
        raise RuntimeError("actual signed HAP code-sign/digest/permission verification did not pass")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--signer-dist", type=Path, required=True)
    parser.add_argument("--jar", type=Path, help="Override the OpenHarmony signing tool JAR")
    parser.add_argument("--unsigned", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--bundle-name", required=True)
    parser.add_argument("--udid", required=True)
    parser.add_argument("--sign-code", choices=("0", "1"), default="1")
    args = parser.parse_args()

    dist = args.signer_dist.resolve()
    profile = json.loads((dist / "UnsgnedDebugProfileTemplate.json").read_text())
    now = int(time.time())
    profile["uuid"] = str(uuid.uuid4())
    profile["validity"] = {"not-before": now - 86400, "not-after": now + 10 * 365 * 86400}
    profile["bundle-info"]["bundle-name"] = args.bundle_name
    profile["bundle-info"]["apl"] = "normal"
    profile["bundle-info"]["app-feature"] = "hos_normal_app"
    profile["debug-info"]["device-ids"] = [args.udid]
    profile["acls"]["allowed-acls"] = []
    profile["permissions"]["restricted-permissions"] = []

    jar = str((args.jar or dist / "hap-sign-tool.jar").resolve())
    keystore = str(dist / "OpenHarmony.p12")
    with tempfile.TemporaryDirectory(prefix="ohos-web-probe-sign-") as temp:
        temp_dir = Path(temp)
        profile_json = temp_dir / "profile.json"
        profile_signed = temp_dir / "profile.p7b"
        normalized_hap = temp_dir / "unsigned-normalized.hap"
        profile_json.write_text(json.dumps(profile, indent=2) + "\n")
        # The local ArkDown ZIP writer emits a ZIP64 CEN extra field rejected
        # by the pinned OpenHarmony signCode parser. Normalize before signing.
        with zipfile.ZipFile(args.unsigned.resolve()) as original, zipfile.ZipFile(
            normalized_hap, "w", allowZip64=False
        ) as normalized:
            for member in original.infolist():
                content = original.read(member)
                member.extra = b""
                normalized.writestr(member, content)
        subprocess.run([
            "java", "-jar", jar, "sign-profile",
            "-keyAlias", "openharmony application profile debug",
            "-signAlg", "SHA256withECDSA", "-mode", "localSign",
            "-profileCertFile", str(dist / "OpenHarmonyProfileDebug.pem"),
            "-inFile", str(profile_json), "-keystoreFile", keystore,
            "-outFile", str(profile_signed), "-keyPwd", "123456",
            "-keystorePwd", "123456",
        ], check=True)
        subprocess.run([
            "java", "-jar", jar, "sign-app",
            "-keyAlias", "openharmony application release",
            "-signAlg", "SHA256withECDSA", "-mode", "localSign",
            "-appCertFile", str(dist / "OpenHarmonyApplication.pem"),
            "-profileFile", str(profile_signed), "-inFile", str(normalized_hap),
            "-keystoreFile", keystore, "-outFile", str(args.output.resolve()),
            "-keyPwd", "123456", "-keystorePwd", "123456", "-signCode", args.sign_code,
        ], check=True)
        verify_signed_hap(jar, args.output.resolve(), temp_dir)
    print(args.output.resolve())


if __name__ == "__main__":
    main()
