# Node.js and OHOS QEMU E2E

`pnpm test:e2e:qemu -- ...` builds and validates both products in real QEMU guests. OHOS validation installs a signed HAP, launches `EntryAbility` through `aa`, and runs the shared tests in the application's actual native host. A standalone ArkVM runner is not part of this pipeline. `arkdown build` is used only to compile/package the HAP.

## Runner prerequisites

- Zig 0.16 for Node/WASI and an OHOS-patched Zig 0.16 for `aarch64-linux-ohos`.
- OHOS NDK, a complete API 26 provider SDK, `arkdown` on PATH, HDC, a running ARM64 OHOS QEMU with a QMP socket and a reachable HDC target.
- Official OpenHarmony `developtools/hapsigner/dist`, a development device UDID, and a Linux Docker image containing Python 3 and JDK 17. The default image name is `ohos-qemu-build-env:7.0-release`; override `--signer-image` if needed. Linux signing avoids the macOS JDK's rejection of the compiler's ZIP64 HAP.
- A running x86_64 Linux QEMU guest with SSH/cloud-init support. `scripts/qemu/boot_node_guest.py` creates an isolated qcow2 overlay, SSH key and seed ISO; it never writes the base image.
- The official `node-v24.14.0-linux-x64.tar.xz` archive and corresponding `SHASUMS256.txt`. The runner verifies their SHA256 before installing Node in a unique guest directory. Guest outbound npm access is required.
- The Node runner also installs the actual Zig 0.16 Linux x64 compiler and stages the Zig build sources for the memory-option validation test. It downloads the pinned [official release](https://ziglang.org/download/index.json) and checks its SHA256; supply `--zig-archive /path/zig-x86_64-linux-0.16.0.tar.xz` to use a local archive. Missing Zig must not turn the QEMU acceptance test into a skip.
- `pnpm install --config.lockfile=true --frozen-lockfile` in this checkout. Use a runner exclusively for one matrix at a time because all five HAP suites use the owned bundle `org.harmonycontrib.zignapie2e`.

For example, boot the Node guest:

```sh
python3 scripts/qemu/boot_node_guest.py \
  --image /absolute/path/noble-server-cloudimg-amd64.img \
  --output .tmp_qemu_e2e/node-guest --ssh-port 22226
```

Wait until cloud-init has installed the generated SSH key. Then run the complete matrix with the local paths and live device connection:

```sh
pnpm test:e2e:qemu -- \
  --output .tmp_qemu_e2e/final \
  --ohos-zig /absolute/path/patched-zig \
  --node-zig /absolute/path/zig \
  --ndk /absolute/path/ohos-ndk \
  --sdk /absolute/path/provider-sdk/26.0.0 \
  --signer-dist /absolute/path/hapsigner/dist \
  --udid DEVICE_UDID \
  --hdc /absolute/path/hdc --server HDC_SERVER_PORT \
  --target 127.0.0.1:5682 --qmp /absolute/path/ohos-qmp.sock \
  --node-guest .tmp_qemu_e2e/node-guest/guest.json \
  --node-archive /absolute/path/node-v24.14.0-linux-x64.tar.xz \
  --node-shasums /absolute/path/SHASUMS256.txt --repeat 3
```

The output directory must be inside the checkout for Docker signing. `--server` can be omitted if HDC uses its default server. The OHOS guest must allow development HAP installation and have an ordinary unlocked/swipe-lock screen. On launch error 10106102, the runner captures a QMP screenshot, derives the screen dimensions and performs a normal upward swipe before one retry. It never supplies credentials or disables screen security.

## What must pass

1. Build `basic`, `allocator-builtin`, `allocator-custom`, `init` and `memory` for OHOS ARM64 into isolated output directories. Code-sign the HAP and its native libraries with the official OpenHarmony HAP signer (`-signCode 1`), and verify code-sign, digest and permission signatures. Install each HAP and run it three times. OHOS build/signing runs outside the Node CLI.
2. Require a fresh UUID challenge, exact ordered groups, exact group count and `status: ok` from each guest run. Basic has 12 groups; allocator/init each have one; memory has five. Memory includes exact counts of 128 external and 96 class finalizers.
3. Compile the real generated OHOS declarations and consumer contracts with TypeScript 6, strict checking and `skipLibCheck: false`.
4. Build both normal WASI flavors and a separate small-memory threaded OOM artifact. Cross-build all six Linux x64 GNU native addons at Node-API 10.
5. Stage those actual artifacts, compiler, sources and tests in the Linux QEMU guest. Require raw WASM ABI, build-option validation, allocator/concurrency/OOM, worker-crash and string-codec acceptance with zero skips, followed by the full native Node regression three times with zero skips. A timeout or skipped acceptance case fails the matrix.

TCG guests use a bounded timeout multiplier of 5. Assertions and expected counts are unchanged. Timeout-sensitive lifecycle tests wait for actual completion rather than assuming a wall-clock sleep completes native work.

The native AVA runner permits at most 600 seconds of inactivity and 900 seconds overall per round. This covers the synchronous conversion rollback stress case's 32,000 throwing calls under TCG; every iteration and exact allocation assertion remains required.

## Evidence

The matrix writes command logs and `commands.json` for each phase. Each OHOS suite records QMP identity/status, guest `uname`, signed HAP SHA256, manifest, fresh result JSON and filtered hilog. Node evidence includes QMP status, base image SHA256, guest environment, official Node and Zig archive hashes, all native artifact hashes, staged test archive hash, pass/skip counts and WASM OOM artifact hash. `matrix.json` combines this evidence with SHA256 hashes of changed source files.

`.tmp_qemu_e2e/` is ignored because it contains local products, logs, guest overlays and SSH keys. Preserve `matrix.json`, result JSON and logs as CI artifacts; do not upload the guest's private key or disk image. This pipeline verifies the configured guests; it does not establish runtime support for untested CPU architectures or every historical SDK.

## CI

`.github/workflows/ci.yml` requires the `qemu-e2e` job on a self-hosted runner labeled `zig-napi-qemu`. Configure repository variable `QEMU_E2E_ARGUMENTS` as a JSON string array containing the arguments above, excluding `--output` and `--repeat`, which CI supplies. The runner must already expose both guest connections and prerequisites. A missing variable, SDK, device or failing E2E produces a failed job; there is no alternate standalone-runtime fallback. Evidence JSON/logs upload even on failure.

The separate Node addon workflow retains its runtime/target matrix and now includes actual WASM crash acceptance and the isolated OOM build. Running the local matrix does not run the hosted CI workflow.
