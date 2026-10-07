# OHOS QEMU E2E and Node.js host regression

Only OHOS validation uses QEMU. `pnpm test:e2e:qemu` builds the five OHOS HAP suites, installs each signed HAP, launches `EntryAbility` through `aa`, and runs the shared tests in the application's actual native host. `arkdown build` compiles/packages the HAP; validation runs in the full OHOS system.

Node.js native addons and WASI products run directly on the host with `pnpm test:e2e:node --output zig-out/e2e-node`. They require Node.js, zig-patch 0.17.0 and the workspace dependencies. The existing Node addon workflow also tests the supported Node versions on Linux, Windows and macOS.

## OHOS runner prerequisites

- An OHOS-patched Zig 0.17.0 for `aarch64-linux-ohos` or `x86_64-linux-ohos`.
- OHOS NDK, a complete API 26 SDK with native/ETS/toolchains components, `arkdown` on PATH, HDC, and an ARM64 or x86_64 OHOS QEMU with a QMP socket and a reachable HDC target.
- JDK 11 and official OpenHarmony development signing tools. `scripts/qemu/prepare_signer.py --output .tmp_qemu_e2e/signer` downloads the public test credentials and signer JAR at a pinned source revision and verifies every SHA256. Signing runs directly on Linux; `--signer-image IMAGE` optionally runs the same signer in a Linux Docker image containing Python 3 and JDK 11 when using macOS. JDK 17 rejects the signer's ZIP64 intermediate during native code signing; CI uses JDK 11.
- Node.js and `pnpm install --config.lockfile=true --frozen-lockfile` in this checkout for HAP building and declaration checking. Use one OHOS matrix at a time because all five HAP suites use the owned bundle `org.harmonycontrib.zignapie2e`.

Boot the [harmony-contrib/ohos-qemu v20260919 release](https://github.com/harmony-contrib/ohos-qemu/releases/tag/v20260919) locally on Linux x86_64/KVM, prepare the signer, and run all OHOS suites:

```sh
python3 scripts/qemu/boot_ohos_guest.py \
  --output .tmp_qemu_e2e/ohos-guest --hdc /absolute/path/sdk/toolchains/hdc
python3 scripts/qemu/prepare_signer.py --output .tmp_qemu_e2e/signer
pnpm test:e2e:qemu --repeat 3 \
  --output .tmp_qemu_e2e/ohos \
  --ohos-guest .tmp_qemu_e2e/ohos-guest/guest.json \
  --ohos-zig /absolute/path/patched-zig --ndk /absolute/path/sdk \
  --sdk /absolute/path/sdk --signer-dist .tmp_qemu_e2e/signer
python3 scripts/qemu/stop_guest.py --guest .tmp_qemu_e2e/ohos-guest/guest.json
```

For an Apple Silicon development machine, add `--arch arm64 --accel hvf` to the boot command. `--archive FILE` accepts a local release archive but still requires its pinned checksum. `--server PORT` can select an existing HDC server on machines that already run other guests. The generated `guest.json` supplies the live device connection, UDID and architecture to `--ohos-guest`.

To use an already running OHOS guest, supply its connection explicitly:

```sh
pnpm test:e2e:qemu --repeat 3 \
  --output .tmp_qemu_e2e/ohos \
  --ohos-zig /absolute/path/patched-zig \
  --ndk /absolute/path/ohos-ndk --sdk /absolute/path/provider-sdk/26.0.0 \
  --signer-dist /absolute/path/hapsigner/dist \
  --udid DEVICE_UDID --hdc /absolute/path/hdc --server HDC_SERVER_PORT \
  --target 127.0.0.1:5682 --qmp /absolute/path/ohos-qmp.sock
```

When using `--signer-image`, the output directory must be inside the checkout for the Docker bind mount. `--server` can be omitted if HDC uses its default server. The OHOS guest must allow development HAP installation and have an ordinary unlocked/swipe-lock screen. On launch error 10106102, the runner captures a QMP screenshot, derives the screen dimensions and performs a normal upward swipe before one retry. It never supplies credentials or disables screen security.

## What OHOS must pass

1. Build `basic`, `allocator-builtin`, `allocator-custom`, `init` and `memory` for the OHOS guest ABI (`--ohos-arch arm64|x86_64`, ARM64 by default) into isolated output directories. Code-sign the HAP and its native libraries with the official OpenHarmony HAP signer (`-signCode 1`), and verify code-sign, digest and permission signatures. Install each HAP and run it three times. OHOS build/signing runs outside the Node CLI.
2. Require a fresh UUID challenge, exact ordered groups, exact group count and `status: ok` from each guest run. Basic has 12 groups; allocator/init each have one; memory has five. Memory includes exact counts of 128 external and 96 class finalizers.
3. Compile the real generated OHOS declarations and consumer contracts with TypeScript 6, strict checking and `skipLibCheck: false`.

## Node.js host E2E

```sh
pnpm test:e2e:node --output zig-out/e2e-node --repeat 3
```

`scripts/run_node_e2e.py` builds both normal WASI flavors through the Node CLI, creates a separate small-memory threaded OOM artifact, and builds all six native addons for the current host at Node-API 10. It runs raw WASM ABI, build-option validation, allocator/concurrency/OOM, worker-crash and string-codec acceptance, then the full native Node regression three times. The acceptance gates require at least 10 WASM tests and 277 tests per full regression round, with zero skips. Both WASI artifacts must be present, so their lifecycle cases cannot silently disappear from the native regression.

The runner uses the ordinary host timeout budgets, with at most 120 seconds of AVA inactivity and 900 seconds overall per round. It needs no guest image, SSH connection or compiler/runtime archive download. The separate Node addon workflow retains the older Node runtime matrix, both WASI flavors, ReleaseSafe/ReleaseFast acceptance, CLI/npm-pack tests and worker OOM checks.

## Evidence

Each runner writes command logs and `commands.json`. Each OHOS suite records QMP identity/status, guest `uname`, signed HAP SHA256, manifest, fresh result JSON and filtered hilog. OHOS `matrix.json` combines these results with the tested Git revision and hashes of changed files, including regenerated declarations. Node `evidence.json` records direct host execution, Node/Zig versions, architecture, built artifact hashes and exact pass/skip counts.

`.tmp_qemu_e2e/` is ignored because it contains local OHOS products, logs and extracted guest images. Node evidence defaults in CI to `zig-out/e2e-node`. Preserve result JSON and logs as CI artifacts; signing credentials and disk images are excluded. These results cover the tested runtimes, architectures and SDKs.

The historical combined QEMU runs are retained in [`qemu-e2e-results.json`](qemu-e2e-results.json), [`cli-refactor-e2e-results.json`](cli-refactor-e2e-results.json) and [`hosted-qemu-e2e-results.json`](hosted-qemu-e2e-results.json). Their Node guest results describe earlier runs; current Node validation executes directly on the runner.

## CI

`.github/workflows/ci.yml` runs two independent E2E jobs on GitHub-hosted `ubuntu-24.04` runners:

- `ohos-qemu-e2e` downloads the pinned OHOS phone image, verifies its SHA256, and invokes the release's launcher with KVM and QMP. It installs the full OpenHarmony 7.0 `native;ets;toolchains` SDK, OHOS Zig 0.17.0, ArkDown 0.0.2 and official development signing tools. HDC, AccountMgr user 100/foreground readiness, device UDID, guest architecture and active KVM are required before the five signed HAP suites run three times each. The job stops its owned QEMU through QMP on completion or failure.
- `node-e2e` uses the runner's Node.js 24.14.0 and zig-patch 0.17.0 to build and execute Node/WASI acceptance and three full regression rounds directly on the runner.

Both jobs upload result JSON and logs with `always()`. The OHOS job requires no preconfigured guest, private Docker image, repository variable or self-hosted runner. Missing KVM, SDK, device readiness, an installation/signature failure, skipped acceptance or failed assertion fails the appropriate job. `workflow_dispatch` allows a manual regression run on a branch.
