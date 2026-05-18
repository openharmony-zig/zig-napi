#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." &>/dev/null && pwd)"

: "${ARK_HOST_TOOLS_DIR:?ARK_HOST_TOOLS_DIR is required}"

ARK_ES2ABC="${ARK_HOST_TOOLS_DIR}/es2abc"
ARK_JS_NAPI_CLI="${ARK_HOST_TOOLS_DIR}/ark_js_napi_cli"
TEST_TIMEOUT_SEC="${TEST_TIMEOUT_SEC:-180}"
KEEP_WORKDIR="${KEEP_WORKDIR:-0}"
WORK_ROOT="${ARKVM_WORK_ROOT:-${REPO_ROOT}/.tmp_arkvm_runner}"
WORKSPACE="${WORK_ROOT}/benchmark_performance"
ABC="${WORKSPACE}/suite.abc"
FILES_INFO="${WORKSPACE}/filesInfo.txt"
LOG_FILE="${WORKSPACE}/arkvm.log"
RESULT_PREFIX="__ZIG_NAPI_BENCHMARK_RESULT__"
ZIG_BUILD_ARGS="${ARKVM_BUILD_ARGS:--Darkvm-test=true -Doptimize=ReleaseFast}"
RESULT_MD="${BENCHMARK_RESULT_MD:-${WORK_ROOT}/benchmark-result.md}"

[[ -x "${ARK_ES2ABC}" ]] || { echo "Missing binary: ${ARK_ES2ABC}" >&2; exit 1; }
[[ -x "${ARK_JS_NAPI_CLI}" ]] || { echo "Missing binary: ${ARK_JS_NAPI_CLI}" >&2; exit 1; }
[[ -f "${ARK_HOST_TOOLS_DIR}/libace_napi.so" ]] || { echo "Missing shared lib: ${ARK_HOST_TOOLS_DIR}/libace_napi.so" >&2; exit 1; }
[[ -f "${ARK_HOST_TOOLS_DIR}/libets_interop_js_napi.so" ]] || { echo "Missing shared lib: ${ARK_HOST_TOOLS_DIR}/libets_interop_js_napi.so" >&2; exit 1; }
[[ -f "${ARK_HOST_TOOLS_DIR}/etsstdlib.abc" ]] || { echo "Missing ArkTS stdlib: ${ARK_HOST_TOOLS_DIR}/etsstdlib.abc" >&2; exit 1; }
[[ -f "${ARK_HOST_TOOLS_DIR}/hello.abc" ]] || { echo "Missing ArkVM fixture abc: ${ARK_HOST_TOOLS_DIR}/hello.abc" >&2; exit 1; }

add_file_info() {
  local source_file="$1"
  local rel_path="${source_file#${REPO_ROOT}/}"
  local record_name="${rel_path%.*}"
  printf '%s;%s;esm;%s;%s;false\n' "${source_file}" "${record_name}" "${rel_path}" "${record_name}" >> "${FILES_INFO}"
}

write_benchmark_results() {
  {
    echo "# zig-napi ArkVM benchmark"
    echo
    echo "- Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "- Status: $(grep "^${RESULT_PREFIX}" "${LOG_FILE}" | tail -n 1 || true)"
    echo
    awk '
      /^__ZIG_NAPI_BENCHMARK_TABLE__/ { in_table = 1; next }
      in_table && /^\|/ { print; seen = 1; next }
      in_table && seen { exit }
    ' "${LOG_FILE}"
    if ! grep -q '^|' "${LOG_FILE}"; then
      echo "No benchmark table was emitted. See full log."
    fi
  } > "${RESULT_MD}"

  echo "Benchmark result markdown: ${RESULT_MD}"
}

rm -rf "${WORKSPACE}"
mkdir -p "${WORKSPACE}/module" "${WORKSPACE}/native-c"

echo "==> examples/benchmark: zig-napi addon"
if [[ "${ARKVM_SKIP_BUILD:-0}" != "1" ]]; then
  (cd "${REPO_ROOT}/examples/benchmark" && zig build ${ZIG_BUILD_ARGS})
fi
cp "${REPO_ROOT}/examples/benchmark/zig-out/arkvm-host/libzig_benchmark.so" "${WORKSPACE}/module/"

echo "==> benchmark/native-c: native C N-API addon"
if [[ "${ARKVM_SKIP_BUILD:-0}" != "1" ]]; then
  "${REPO_ROOT}/benchmark/native-c/build.sh" "${WORKSPACE}/native-c"
fi
cp "${WORKSPACE}/native-c/libnapi_benchmark.so" "${WORKSPACE}/module/"

ln -sf "${ARK_HOST_TOOLS_DIR}/libets_interop_js_napi.so" "${WORKSPACE}/module/libets_interop_js_napi.so"
cp "${ARK_HOST_TOOLS_DIR}/etsstdlib.abc" "${WORKSPACE}/"
cp "${ARK_HOST_TOOLS_DIR}/hello.abc" "${WORKSPACE}/"

: > "${FILES_INFO}"
add_file_info "${REPO_ROOT}/benchmark/performance.ts"
"${ARK_ES2ABC}" --merge-abc --extension=ts --module --output "${ABC}" "@${FILES_INFO}"

: > "${LOG_FILE}"
(
  cd "${WORKSPACE}"
  export LD_LIBRARY_PATH="${WORKSPACE}:${WORKSPACE}/module:${ARK_HOST_TOOLS_DIR}:${LD_LIBRARY_PATH:-}"
  "${ARK_JS_NAPI_CLI}" --entry-point "benchmark/performance" "${ABC}"
) >"${LOG_FILE}" 2>&1 &

pid=$!
deadline=$((SECONDS + TEST_TIMEOUT_SEC))
exit_status=0
while kill -0 "${pid}" 2>/dev/null; do
  if (( SECONDS >= deadline )); then
    kill -TERM "${pid}" 2>/dev/null || true
    sleep 1
    kill -KILL "${pid}" 2>/dev/null || true
    wait "${pid}" >/dev/null 2>&1 || true
    echo "ArkVM benchmark timed out after ${TEST_TIMEOUT_SEC}s" >&2
    cat "${LOG_FILE}" >&2
    write_benchmark_results
    exit 124
  fi
  sleep 0.2
done
wait "${pid}" >/dev/null 2>&1 || exit_status=$?

cat "${LOG_FILE}"
write_benchmark_results
if [[ "${exit_status}" != "0" ]]; then
  echo "ArkVM benchmark exited with status ${exit_status}" >&2
  exit "${exit_status}"
fi
if grep -Eq 'error\(DebugAllocator\)|Segmentation fault|SIGSEGV|panic:|Cannot execute panda file|load native module failed' "${LOG_FILE}"; then
  echo "ArkVM benchmark emitted a fatal runtime diagnostic" >&2
  exit 1
fi
grep -q "^${RESULT_PREFIX} status=ok" "${LOG_FILE}"

[[ "${KEEP_WORKDIR}" == "1" ]] || rm -rf "${WORKSPACE}"
