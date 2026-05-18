# zig-napi ArkVM benchmark

This benchmark compares the current zig-napi wrapper surface with an equivalent
native C N-API addon. It follows the AKI benchmark style: run the same semantic
operation repeatedly on ArkVM and report average call time in microseconds.

Run it with host ArkVM tools:

```bash
ARK_HOST_TOOLS_DIR=/path/to/arkvm/host/tools scripts/arkvm/run_arkvm_benchmarks.sh
```

The zig-napi side is built with Zig and defaults to `-Doptimize=ReleaseFast`.
The native N-API side is built from `benchmark/native-c/napi_benchmark.c` with
an external C compiler, defaulting to `CC` or `cc`. The standalone native C
build script rejects `zig` as the compiler.

The benchmark prints a Markdown table with:

- `native C N-API avg (us)`: average time for the hand-written C N-API path.
- `zig-napi avg (us)`: average time for the current zig-napi wrapper path.
- `diff (us)`: `zig-napi - native C N-API`.
- `ratio`: `zig-napi / native C N-API`.

Most cases run 100000 iterations. Constructors that allocate JS/native objects
run 20000 iterations to keep host ArkVM memory use stable.

## Latest local result

Environment:

- Date: 2026-05-18
- Runner: local Docker `ubuntu:latest` on `linux/amd64`
- Runtime: ArkVM host tools from local `arkvm_static_linux_x64.tar.gz`
- Zig addon: `zig build -Darkvm-test=true -Doptimize=ReleaseFast`
- Native addon: C source compiled in Docker with `gcc`

| module | api content | iterations | native C N-API avg (us) | zig-napi avg (us) | diff (us) | ratio |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| global function | void(*)() | 100000 | 0.159 | 0.159 | 0 | 1.001x |
| primitive | i32(i32, i32) | 100000 | 0.183 | 0.169 | -0.014 | 0.924x |
| primitive | bool(bool) | 100000 | 0.169 | 0.169 | 0 | 1.003x |
| string | len(string) | 100000 | 0.213 | 0.204 | -0.008 | 0.961x |
| object | read properties | 100000 | 0.368 | 0.37 | 0.001 | 1.003x |
| array | sum(number[]) | 100000 | 1.065 | 0.792 | -0.274 | 0.743x |
| function | call callback | 100000 | 0.333 | 0.339 | 0.006 | 1.017x |
| class | constructor | 20000 | 1.517 | 3.091 | 1.574 | 2.037x |
| class | getter | 100000 | 0.264 | 0.266 | 0.002 | 1.009x |
| class | setter | 100000 | 0.458 | 0.472 | 0.014 | 1.03x |
| class | method | 100000 | 0.269 | 0.27 | 0.001 | 1.004x |
| ArrayBuffer | constructor | 20000 | 0.339 | 0.424 | 0.085 | 1.251x |
| ArrayBuffer | byteLength | 100000 | 0.2 | 0.198 | -0.002 | 0.989x |
| Buffer | constructor | 20000 | 0.691 | 0.72 | 0.029 | 1.042x |
| Buffer | length | 100000 | 0.207 | 0.204 | -0.004 | 0.983x |
| TypedArray | Uint8Array constructor | 20000 | 0.548 | 0.647 | 0.099 | 1.18x |
| TypedArray | Uint8Array sum | 100000 | 0.24 | 0.275 | 0.035 | 1.147x |
| DataView | constructor | 20000 | 0.885 | 0.44 | -0.445 | 0.498x |
| DataView | byteLength | 100000 | 0.201 | 0.235 | 0.034 | 1.169x |
