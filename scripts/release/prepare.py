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
ZIG_PATHS = ["src", "build", "build.zig", str(ZON)]
VERSION = r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)"
ZON_VERSION = re.compile(r'^(    \.version = ")([^"]+)(",)', re.MULTILINE)


def git(*args):
    return subprocess.check_output(["git", *args], text=True).strip()


def numbers(version):
    if not re.fullmatch(VERSION, version):
        raise ValueError(f"Expected a stable release version, got {version!r}")
    return tuple(map(int, version.split(".")))


def latest_zig_tag():
    tags = git("tag", "--merged", "HEAD").splitlines()
    return max((tag for tag in tags if re.fullmatch(VERSION, tag)), key=numbers)


def next_version(version, base, paths):
    major, minor, patch = numbers(version.split("-")[0])
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
    previous = latest_zig_tag()
    result = {"previous": previous, "version": previous, "changed": "false"}
    if not git("diff", "--name-only", previous, "HEAD", "--", *ZIG_PATHS):
        return result
    source = ZON.read_text()
    match = ZON_VERSION.search(source)
    if not match:
        raise ValueError(f"Cannot find the package version in {ZON}")
    declared = match[2]
    if numbers(declared) < numbers(previous):
        raise ValueError(f"{ZON} version {declared} is behind tag {previous}")
    version = declared
    if declared == previous:
        version = next_version(previous, previous, ZIG_PATHS)
        ZON.write_text(ZON_VERSION.sub(lambda m: m[1] + version + m[3], source, count=1))
    return {"previous": previous, "version": version, "changed": "true"}


def cli_version_commit(version):
    # Follow actual manifest versions, including squash, rebase and merge commits.
    # The resulting commit is the snapshot included in the last CLI version.
    base = None
    for sha in git("log", "--first-parent", "--format=%H", "--", str(MANIFEST)).splitlines():
        if json.loads(git("show", f"{sha}:{MANIFEST}"))["version"] != version:
            break
        base = sha
    if base is None:
        raise ValueError(f"No committed CLI manifest for {version}")
    return base


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")


def prepare_cli(zig_version):
    manifest = json.loads(MANIFEST.read_text())
    pin = json.loads(PIN.read_text())
    base = cli_version_commit(manifest["version"])
    paths = [str(MANIFEST), *(str(CLI / name) for name in manifest["files"])]
    released, pinned = numbers(zig_version), numbers(pin["version"])
    if released < pinned:
        raise ValueError(f"Refusing to downgrade Zig template pin to {zig_version}")
    if released == pinned and not git("diff", "--name-only", base, "HEAD", "--", *paths):
        return {}
    if released > pinned:
        url = f"https://github.com/openharmony-zig/zig-napi/archive/refs/tags/{zig_version}.tar.gz"
        package_hash = subprocess.check_output(["zig", "fetch", url], text=True).strip()
        if not re.fullmatch(rf"zig_napi-{re.escape(zig_version)}-[A-Za-z0-9_-]+", package_hash):
            raise ValueError(f"Unexpected Zig package hash for {url}: {package_hash!r}")
        write_json(PIN, {"version": zig_version, "hash": package_hash})
    manifest["version"] = next_version(manifest["version"], base, paths)
    write_json(MANIFEST, manifest)
    return {"version": manifest["version"]}


if __name__ == "__main__":
    if sys.argv[1:] == ["zig"]:
        outputs = prepare_zig()
    elif len(sys.argv) == 3 and sys.argv[1] == "cli":
        outputs = prepare_cli(sys.argv[2])
    else:
        sys.exit("Usage: prepare.py zig | cli ZIG_VERSION")
    with open(os.environ.get("GITHUB_OUTPUT", os.devnull), "a") as output:
        for key, value in outputs.items():
            print(f"{key}={value}", file=output)
            print(f"{key}={value}")
