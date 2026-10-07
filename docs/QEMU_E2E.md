# Node.js and OHOS QEMU E2E

`pnpm test:e2e:qemu -- ...` builds and validates both products in real QEMU guests. OHOS validation installs a signed HAP, launches `EntryAbility` through `aa`, and runs the shared tests in the application's actual native host. A standalone ArkVM runner is not part of this pipeline. `arkdown build` is used only to compile/package the HAP.

## Runner prerequisites

- Zig 0.16 for Node/WASI and an OHOS-patched Zig 0.16 for `aarch64-linux-ohos` or `x86_64-linux-ohos`.
- OHOS NDK, a complete API 26 SDK with native/ETS/toolchains components, `arkdown` on PATH, HDC, a running ARM64 or x86_64 OHOS QEMU with a QMP socket and a reachable HDC target.
- JDK 11 and official OpenHarmony development signing tools. `scripts/qemu/prepare_signer.py --output .tmp_qemu_e2e/signer` downloads the public test credentials and signer JAR at a pinned source revision and verifies every SHA256. Signing runs directly on Linux; `--signer-image IMAGE` optionally runs the same signer in a Linux Docker image containing Python 3 and JDK 11 when using macOS. JDK 17 rejects the signer's ZIP64 intermediate during native code signing; CI uses JDK 11.
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
  --signer-image Linux_Python3_JDK11_IMAGE \
  --udid DEVICE_UDID \
  --hdc /absolute/path/hdc --server HDC_SERVER_PORT \
  --target 127.0.0.1:5682 --qmp /absolute/path/ohos-qmp.sock \
  --node-guest .tmp_qemu_e2e/node-guest/guest.json \
  --node-archive /absolute/path/node-v24.14.0-linux-x64.tar.xz \
  --node-shasums /absolute/path/SHASUMS256.txt --repeat 3
```

When using `--signer-image`, the output directory must be inside the checkout for the Docker bind mount. `--server` can be omitted if HDC uses its default server. The OHOS guest must allow development HAP installation and have an ordinary unlocked/swipe-lock screen. On launch error 10106102, the runner captures a QMP screenshot, derives the screen dimensions and performs a normal upward swipe before one retry. It never supplies credentials or disables screen security.

## What must pass

1. Build `basic`, `allocator-builtin`, `allocator-custom`, `init` and `memory` for the OHOS guest ABI (`--ohos-arch arm64|x86_64`, ARM64 by default) into isolated output directories. Code-sign the HAP and its native libraries with the official OpenHarmony HAP signer (`-signCode 1`), and verify code-sign, digest and permission signatures. Install each HAP and run it three times. OHOS build/signing runs outside the Node CLI.
2. Require a fresh UUID challenge, exact ordered groups, exact group count and `status: ok` from each guest run. Basic has 12 groups; allocator/init each have one; memory has five. Memory includes exact counts of 128 external and 96 class finalizers.
3. Compile the real generated OHOS declarations and consumer contracts with TypeScript 6, strict checking and `skipLibCheck: false`.
4. Build both normal WASI flavors and a separate small-memory threaded OOM artifact. Cross-build all six Linux x64 GNU native addons at Node-API 10.
5. Stage those actual artifacts, compiler, sources and tests in the Linux QEMU guest. Require raw WASM ABI, build-option validation, allocator/concurrency/OOM, worker-crash and string-codec acceptance with zero skips, followed by the full native Node regression three times with zero skips. A timeout or skipped acceptance case fails the matrix.

TCG guests use a bounded timeout multiplier of 5. Assertions and expected counts are unchanged. Timeout-sensitive lifecycle tests wait for actual completion rather than assuming a wall-clock sleep completes native work.

The native AVA runner permits at most 600 seconds of inactivity and 900 seconds overall per round. This covers the synchronous conversion rollback stress case's 32,000 throwing calls under TCG; every iteration and exact allocation assertion remains required.

## Evidence

The matrix writes command logs and `commands.json` for each phase. Each OHOS suite records QMP identity/status, guest `uname`, signed HAP SHA256, manifest, fresh result JSON and filtered hilog. Node evidence includes QMP status, base image SHA256, guest environment, official Node and Zig archive hashes, all native artifact hashes, staged test archive hash, pass/skip counts and WASM OOM artifact hash. `matrix.json` combines this evidence with SHA256 hashes of changed source files.

`.tmp_qemu_e2e/` is ignored because it contains local products, logs, guest overlays and SSH keys. Preserve `matrix.json`, result JSON and logs as CI artifacts; do not upload the guest's private key or disk image. This pipeline verifies the configured guests; it does not establish runtime support for untested CPU architectures or every historical SDK.

The first GitHub-hosted run and the downloaded ARM64 release regression are recorded in [`hosted-qemu-e2e-results.json`](hosted-qemu-e2e-results.json), including artifact checksums, actual KVM status, suite results and tested revisions.

## CI

`.github/workflows/ci.yml` runs two independent jobs on GitHub-hosted `ubuntu-24.04` runners:

- `ohos-qemu-e2e` downloads the [harmony-contrib/ohos-qemu v20260919 release](https://github.com/harmony-contrib/ohos-qemu/releases/tag/v20260919), checks the pinned SHA256 of its x86_64 phone image, and invokes the package's own launcher with KVM and QMP. It installs the full OpenHarmony 7.0 `native;ets;toolchains` SDK, OHOS Zig 0.16, ArkDown 0.0.2 and official development signing tools. HDC, AccountMgr user 100/foreground readiness, device UDID, guest architecture and active KVM are required before the five signed HAP suites run three times each.
- `node-qemu-e2e` verifies and boots an Ubuntu Noble x86_64 cloud image with KVM, waits for SSH/cloud-init, then builds the native Node/WASI products and runs their full QEMU acceptance and three native regression rounds.

Both jobs create their own guests, stop them through QMP on completion or failure, and upload result JSON and logs with `always()`. The OHOS job requires no preconfigured guest, private Docker image, repository variable or self-hosted runner. Missing KVM, SDK, device readiness, an installation/signature failure, skipped acceptance or failed assertion fails the job. SSH private keys, signing credentials and disk images are excluded from artifacts. `workflow_dispatch` allows a manual regression run on a branch.

The same OHOS release can be booted locally on Linux x86_64/KVM:

```sh
python3 scripts/qemu/boot_ohos_guest.py \
  --output .tmp_qemu_e2e/ohos-guest --hdc /absolute/path/sdk/toolchains/hdc
python3 scripts/qemu/prepare_signer.py --output .tmp_qemu_e2e/signer
python3 scripts/qemu/run_matrix.py --product ohos --repeat 3 \
  --output .tmp_qemu_e2e/ohos \
  --ohos-guest .tmp_qemu_e2e/ohos-guest/guest.json \
  --ohos-zig /absolute/path/patched-zig --ndk /absolute/path/sdk \
  --sdk /absolute/path/sdk --signer-dist .tmp_qemu_e2e/signer
python3 scripts/qemu/stop_guest.py --guest .tmp_qemu_e2e/ohos-guest/guest.json
```

For an Apple Silicon development machine, add `--arch arm64 --accel hvf` to the boot command. `--archive FILE` accepts a local release archive but still requires its pinned checksum. `--server PORT` can select an existing HDC server on machines that already run other guests. The generated `guest.json` supplies the live device connection, UDID and architecture to `--ohos-guest`.

The default `--product both` retains the combined local matrix; `--product node` needs only the Node guest/archive arguments. The separate Node addon workflow retains its runtime/target matrix, actual WASM crash acceptance and isolated OOM build. Running the local matrix does not run the hosted CI workflow.
