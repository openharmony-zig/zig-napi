"""Prepare release changes in a full checkout of main. Only the workflow publishes them."""

import json
import os
import re
import subprocess
import sys
from pathlib import Path

ZON = Path("build.zig.zon")
CLI = Path("packages/zig-napi")
MANIFEST = CLI / "package.json"
PIN = CLI / "lib/zig-release.json"
ZIG_VERSION = Path(".github/releases/zig-version")
CLI_VERSION = Path(".github/releases/cli-version")
ZIG_PATHS = ["src", "build", "build.zig", str(ZON)]
VERSION = r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)"
ZON_VERSION = re.compile(r'^(    \.version = ")([^"]+)(",)', re.MULTILINE)


def git(*args):
    return subprocess.check_output(["git", *args], text=True).strip()


def numbers(version):
    if not re.fullmatch(VERSION, version):
        raise ValueError(f"Expected a stable release version, got {version!r}")
    return tuple(map(int, version.split(".")))


def cli_version_key(version):
    # npm also accepts prereleases. Numeric identifiers sort before text, and
    # a stable version sorts after every prerelease of the same core version.
    identifier = r"[0-9A-Za-z-]+"
    suffix = rf"{identifier}(?:\.{identifier})*"
    match = re.fullmatch(rf"({VERSION})(?:-({suffix}))?(?:\+{suffix})?", version)
    if not match:
        raise ValueError(f"Invalid CLI version {version!r}")
    prerelease = match[2].split(".") if match[2] else []
    if any(part.isdigit() and part.startswith("0") and len(part) > 1 for part in prerelease):
        raise ValueError(f"Invalid CLI prerelease {version!r}")
    identifiers = tuple(
        (0, int(part)) if part.isdigit() else (1, part) for part in prerelease
    )
    return numbers(match[1]), not prerelease, identifiers


def zig_version(source):
    match = ZON_VERSION.search(source)
    if not match:
        raise ValueError(f"Cannot find the package version in {ZON}")
    return match[2]


def next_version(version, base, paths):
    major, minor, patch = numbers(re.split(r"[-+]", version, maxsplit=1)[0])
    messages = git("log", "--format=%s%n%b%x00", f"{base}..HEAD", "--", *paths).split("\0")
    titles = [message.strip().split("\n")[0] for message in messages]
    if any(re.match(r"\w+(\([^)]*\))?!:", title) for title in titles) or any(
        re.search(r"^BREAKING[ -]CHANGE:", message, re.MULTILINE) for message in messages
    ):
        return f"{major + 1}.0.0"
    if any(re.match(r"feat(\([^)]*\))?:", title) for title in titles):
        return f"{major}.{minor + 1}.0"
    return f"{major}.{minor}.{patch + 1}"


def prepare_zig():
    previous = ZIG_VERSION.read_text().strip()
    result = {"previous": previous, "version": previous, "changed": "false"}
    # The previous release PR may have just merged. Its publisher reruns
    # planning after it creates the tag at the approved merge commit.
    if previous not in git("tag", "--merged", "HEAD").splitlines():
        return result
    if not git("diff", "--name-only", previous, "HEAD", "--", *ZIG_PATHS):
        return result
    source = ZON.read_text()
    declared = zig_version(source)
    if numbers(declared) < numbers(previous):
        raise ValueError(f"{ZON} version {declared} is behind tag {previous}")
    version = declared
    if declared == previous:
        version = next_version(previous, previous, ZIG_PATHS)
        ZON.write_text(ZON_VERSION.sub(lambda m: m[1] + version + m[3], source, count=1))
    ZIG_VERSION.write_text(version + "\n")
    return {"previous": previous, "version": version, "changed": "true"}


def cli_version_commit(version):
    approved = git("log", "-1", "--first-parent", "--diff-filter=M", "--format=%H", "--", str(CLI_VERSION))
    if approved:
        return approved
    # Bootstrap from the last CLI version shipped before release PRs existed.
    base = None
    for sha in git("log", "--first-parent", "--format=%H", "--", str(MANIFEST)).splitlines():
        if json.loads(git("show", f"{sha}:{MANIFEST}"))["version"] == version:
            base = sha
        elif base:
            break
    if base is None:
        raise ValueError(f"No committed CLI manifest for {version}")
    return base


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")


def prepare_cli(zig_version):
    manifest = json.loads(MANIFEST.read_text())
    pin = json.loads(PIN.read_text())
    approved = CLI_VERSION.read_text().strip()
    base = cli_version_commit(approved)
    paths = [str(MANIFEST), *(str(CLI / name) for name in manifest["files"])]
    released, pinned = numbers(zig_version), numbers(pin["version"])
    if released < pinned:
        raise ValueError(f"Refusing to downgrade Zig template pin to {zig_version}")
    if released == pinned and not git("diff", "--name-only", base, "HEAD", "--", *paths):
        return {}
    declared = manifest["version"]
    if cli_version_key(declared) < cli_version_key(approved):
        raise ValueError(f"CLI manifest version {declared} is behind approved version {approved}")
    if released > pinned:
        url = f"https://github.com/openharmony-zig/zig-napi/archive/refs/tags/{zig_version}.tar.gz"
        package_hash = subprocess.check_output(["zig", "fetch", url], text=True).strip()
        if not re.fullmatch(rf"zig_napi-{re.escape(zig_version)}-[A-Za-z0-9_-]+", package_hash):
            raise ValueError(f"Unexpected Zig package hash for {url}: {package_hash!r}")
        write_json(PIN, {"version": zig_version, "hash": package_hash})
    manifest["version"] = next_version(approved, base, paths) if declared == approved else declared
    write_json(MANIFEST, manifest)
    CLI_VERSION.write_text(manifest["version"] + "\n")
    return {"version": manifest["version"]}


def merged_version(component):
    record = ZIG_VERSION if component == "zig" else CLI_VERSION
    version = record.read_text().strip()
    if component == "zig":
        declared, order = zig_version(ZON.read_text()), numbers
    else:
        declared, order = json.loads(MANIFEST.read_text())["version"], cli_version_key
    if declared != version:
        raise ValueError(f"The {component} manifest version {declared} differs from {record}")
    # The publisher's PR path filter requires a change to this record. With
    # rebase merges the version bump may precede the last commit of the PR.
    change = git("log", "-1", "--first-parent", "--format=%H", "--", str(record))
    previous = git("show", f"{change}^1:{record}")
    if order(version) <= order(previous):
        raise ValueError(f"The merged {component} release PR must advance {record} to the manifest version")
    return {"previous": previous, "version": version}


if __name__ == "__main__":
    if sys.argv[1:] == ["zig"]:
        outputs = prepare_zig()
    elif len(sys.argv) == 3 and sys.argv[1] == "cli":
        outputs = prepare_cli(sys.argv[2])
    elif len(sys.argv) == 3 and sys.argv[1] == "merged" and sys.argv[2] in ("zig", "cli"):
        outputs = merged_version(sys.argv[2])
    else:
        sys.exit("Usage: prepare.py zig | cli ZIG_VERSION | merged {zig,cli}")
    with open(os.environ.get("GITHUB_OUTPUT", os.devnull), "a") as output:
        for key, value in outputs.items():
            print(f"{key}={value}", file=output)
            print(f"{key}={value}")
