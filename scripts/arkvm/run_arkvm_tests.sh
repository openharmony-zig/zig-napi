#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." &>/dev/null && pwd)"

: "${ARK_HOST_TOOLS_DIR:?ARK_HOST_TOOLS_DIR is required}"

ARK_ES2ABC="${ARK_HOST_TOOLS_DIR}/es2abc"
ARK_JS_NAPI_CLI="${ARK_HOST_TOOLS_DIR}/ark_js_napi_cli"
TEST_TIMEOUT_SEC="${TEST_TIMEOUT_SEC:-90}"
RESULT_GRACE_SEC="${RESULT_GRACE_SEC:-2}"
KEEP_WORKDIR="${KEEP_WORKDIR:-0}"
WORK_ROOT="${ARKVM_WORK_ROOT:-${REPO_ROOT}/.tmp_arkvm_runner}"
WAIT_FOR_EXIT="${ARKVM_WAIT_FOR_EXIT:-0}"
EXPECT_LOG="${ARKVM_EXPECT_LOG:-}"

[[ -x "${ARK_ES2ABC}" ]] || { echo "Missing binary: ${ARK_ES2ABC}" >&2; exit 1; }
[[ -x "${ARK_JS_NAPI_CLI}" ]] || { echo "Missing binary: ${ARK_JS_NAPI_CLI}" >&2; exit 1; }
[[ -f "${ARK_HOST_TOOLS_DIR}/libace_napi.so" ]] || { echo "Missing shared lib: ${ARK_HOST_TOOLS_DIR}/libace_napi.so" >&2; exit 1; }
[[ -f "${ARK_HOST_TOOLS_DIR}/libets_interop_js_napi.so" ]] || { echo "Missing shared lib: ${ARK_HOST_TOOLS_DIR}/libets_interop_js_napi.so" >&2; exit 1; }
[[ -f "${ARK_HOST_TOOLS_DIR}/etsstdlib.abc" ]] || { echo "Missing ArkTS stdlib: ${ARK_HOST_TOOLS_DIR}/etsstdlib.abc" >&2; exit 1; }
[[ -f "${ARK_HOST_TOOLS_DIR}/hello.abc" ]] || { echo "Missing ArkVM fixture abc: ${ARK_HOST_TOOLS_DIR}/hello.abc" >&2; exit 1; }

add_file_info() {
  local source_file="$1"
  local files_info="$2"
  local rel_path="${source_file#${REPO_ROOT}/}"
  local record_name="${rel_path%.*}"
  printf '%s;%s;esm;%s;%s;false\n' "${source_file}" "${record_name}" "${rel_path}" "${record_name}" >> "${files_info}"
}

run_case() {
  local example_dir="$1"
  local suite="$2"
  local result_prefix="$3"
  local entry_point="$4"
  local build_args="$5"
  local addon_subdir="$6"
  local workspace="${WORK_ROOT}/${entry_point//\//_}"
  local abc="${workspace}/suite.abc"
  local files_info="${workspace}/filesInfo.txt"
  local log_file="${workspace}/arkvm.log"

  echo "==> ${example_dir}: ${suite}"
  if [[ "${ARKVM_SKIP_BUILD:-0}" != "1" ]]; then
    (cd "${REPO_ROOT}/${example_dir}" && zig build ${build_args})
  fi

  rm -rf "${workspace}"
  mkdir -p "${workspace}/module" "${workspace}/fixtures"
  cp "${REPO_ROOT}/${example_dir}/zig-out/${addon_subdir}/libhello.so" "${workspace}/module/"
  ln -sf "${ARK_HOST_TOOLS_DIR}/libets_interop_js_napi.so" "${workspace}/module/libets_interop_js_napi.so"
  cp "${ARK_HOST_TOOLS_DIR}/etsstdlib.abc" "${workspace}/"
  cp "${ARK_HOST_TOOLS_DIR}/hello.abc" "${workspace}/"
  printf 'alpha\n' > "${workspace}/fixtures/first.txt"
  printf 'bravo\n' > "${workspace}/fixtures/second.txt"

  : > "${files_info}"
  if [[ "${suite}" == test/* ]]; then
    while IFS= read -r source_file; do
      add_file_info "${source_file}" "${files_info}"
    done < <(find "${REPO_ROOT}/test" -maxdepth 1 -name '*.ts' | sort)
  elif [[ "${suite}" == memory-testing/* ]]; then
    while IFS= read -r source_file; do
      add_file_info "${source_file}" "${files_info}"
    done < <(find "${REPO_ROOT}/memory-testing" -maxdepth 1 -name '*.ts' | sort)
  else
    add_file_info "${REPO_ROOT}/${suite}" "${files_info}"
  fi
  "${ARK_ES2ABC}" --merge-abc --extension=ts --module --output "${abc}" "@${files_info}"

  : > "${log_file}"
  (
    cd "${workspace}"
    export LD_LIBRARY_PATH="${workspace}:${workspace}/module:${ARK_HOST_TOOLS_DIR}:${LD_LIBRARY_PATH:-}"
    "${ARK_JS_NAPI_CLI}" --entry-point "${entry_point}" "${abc}"
  ) >"${log_file}" 2>&1 &

  local pid=$!
  local deadline=$((SECONDS + TEST_TIMEOUT_SEC))
  local result_deadline=0
  local reaped=0
  local exit_status=0
  while kill -0 "${pid}" 2>/dev/null; do
    if [[ "${WAIT_FOR_EXIT}" != "1" ]] && (( result_deadline == 0 )) && grep -q "^${result_prefix}" "${log_file}" 2>/dev/null; then
      result_deadline=$((SECONDS + RESULT_GRACE_SEC))
    fi
    if (( result_deadline != 0 && SECONDS >= result_deadline )); then
      kill -TERM "${pid}" 2>/dev/null || true
      wait "${pid}" >/dev/null 2>&1 || true
      reaped=1
      break
    fi
    if (( SECONDS >= deadline )); then
      kill -TERM "${pid}" 2>/dev/null || true
      sleep 1
      kill -KILL "${pid}" 2>/dev/null || true
      wait "${pid}" >/dev/null 2>&1 || true
      reaped=1
      echo "ArkVM suite timed out after ${TEST_TIMEOUT_SEC}s" >&2
      cat "${log_file}" >&2
      exit 124
    fi
    sleep 0.2
  done
  if (( reaped == 0 )); then
    wait "${pid}" >/dev/null 2>&1 || exit_status=$?
  fi

  cat "${log_file}"
  if grep -Eq 'error\(DebugAllocator\)|Segmentation fault|SIGSEGV|panic:|Cannot execute panda file|load native module failed' "${log_file}"; then
    echo "ArkVM suite emitted a fatal runtime or leak diagnostic" >&2
    exit 1
  fi
  if [[ "${WAIT_FOR_EXIT}" == "1" && "${exit_status}" != "0" ]]; then
    echo "ArkVM suite exited with status ${exit_status}" >&2
    exit "${exit_status}"
  fi
  grep -q "^${result_prefix} status=ok" "${log_file}"
  if [[ -n "${EXPECT_LOG}" ]]; then
    grep -Eq "${EXPECT_LOG}" "${log_file}"
  fi
}

rm -rf "${WORK_ROOT}"
mkdir -p "${WORK_ROOT}"

if [[ -n "${ARKVM_TEST_SUITE:-}" ]]; then
  run_case "${ARKVM_EXAMPLE_DIR:-examples/basic}" "${ARKVM_TEST_SUITE}" "${ARKVM_RESULT_PREFIX:-__ZIG_NAPI_TEST_RESULT__}" "${ARKVM_ENTRY_POINT:-${ARKVM_TEST_SUITE%.*}}" "${ARKVM_BUILD_ARGS:--Darkvm-test=true -Doptimize=ReleaseSafe}" "${ARKVM_ADDON_SUBDIR:-arkvm-host}"
else
  run_case "examples/basic" "test/basic.ts" "__ZIG_NAPI_TEST_RESULT__" "test/basic" "-Darkvm-test=true -Doptimize=ReleaseSafe" "arkvm-host"
  run_case "examples/init" "test/init.ts" "__ZIG_NAPI_INIT_TEST_RESULT__" "test/init" "-Darkvm-test=true -Doptimize=ReleaseSafe" "arkvm-host"
fi

[[ "${KEEP_WORKDIR}" == "1" ]] || rm -rf "${WORK_ROOT}"
