#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." &>/dev/null && pwd)"
OUT_DIR="${1:-${SCRIPT_DIR}/out}"

read -r -a CC_CMD <<< "${NAPI_BENCHMARK_CC:-${CC:-cc}}"
COMPILER_NAME="$(basename -- "${CC_CMD[0]}")"
if [[ "${COMPILER_NAME}" == "zig" ]]; then
  echo "NAPI_BENCHMARK_CC/CC must be a native C compiler, not zig." >&2
  exit 2
fi

read -r -a EXTRA_CFLAGS <<< "${NAPI_BENCHMARK_CFLAGS:-}"
read -r -a EXTRA_LDFLAGS <<< "${NAPI_BENCHMARK_LDFLAGS:-}"

mkdir -p "${OUT_DIR}"
"${CC_CMD[@]}" \
  -std=c11 \
  -O3 \
  -fPIC \
  -shared \
  -I"${REPO_ROOT}/src/sys/ohos" \
  "${EXTRA_CFLAGS[@]}" \
  "${SCRIPT_DIR}/napi_benchmark.c" \
  -o "${OUT_DIR}/libnapi_benchmark.so" \
  "${EXTRA_LDFLAGS[@]}"
