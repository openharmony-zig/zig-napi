#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." &>/dev/null && pwd)"

ARK_HOST_TOOLS_DIR="${ARK_HOST_TOOLS_DIR:-${ARK_HOST_BUNDLE_DIR:-}}"
if [[ -z "${ARK_HOST_TOOLS_DIR}" ]]; then
  echo "ARK_HOST_TOOLS_DIR is required" >&2
  exit 1
fi

ARK_ES2ABC="${ARK_ES2ABC:-${ARK_HOST_TOOLS_DIR}/es2abc}"
ARK_JS_NAPI_CLI="${ARK_JS_NAPI_CLI:-${ARK_HOST_TOOLS_DIR}/ark_js_napi_cli}"
TEST_TIMEOUT_SEC="${TEST_TIMEOUT_SEC:-90}"
KEEP_WORKDIR="${KEEP_WORKDIR:-0}"
WORK_ROOT="${ARKVM_WORK_ROOT:-${REPO_ROOT}/.tmp_arkvm_runner}"
WORKSPACE_DIR="${WORK_ROOT}/workspace"
LOG_FILE="${WORK_ROOT}/arkvm.log"

require_host_bundle() {
  [[ -x "${ARK_ES2ABC}" ]] || { echo "Missing binary: ${ARK_ES2ABC}" >&2; exit 1; }
  [[ -x "${ARK_JS_NAPI_CLI}" ]] || { echo "Missing binary: ${ARK_JS_NAPI_CLI}" >&2; exit 1; }
  [[ -f "${ARK_HOST_TOOLS_DIR}/libace_napi.so" ]] || { echo "Missing shared lib: ${ARK_HOST_TOOLS_DIR}/libace_napi.so" >&2; exit 1; }
}

build_host_addon() {
  (
    cd "${REPO_ROOT}/examples/basic"
    zig build -Darkvm-test=true -Doptimize=ReleaseSafe
  )
}

prepare_workspace() {
  rm -rf "${WORK_ROOT}"
  mkdir -p "${WORKSPACE_DIR}/module" "${WORK_ROOT}"

  cp "${REPO_ROOT}/examples/basic/zig-out/arkvm-host/libhello.so" "${WORKSPACE_DIR}/module/"
  cp "${REPO_ROOT}/examples/basic/zig-out/arkvm-host/libhello.so" "${WORKSPACE_DIR}/"
  cp "${ARK_HOST_TOOLS_DIR}/libace_napi.so" "${WORKSPACE_DIR}/module/"
  cp "${ARK_HOST_TOOLS_DIR}/libace_napi.so" "${WORKSPACE_DIR}/"

  if [[ -f "${ARK_HOST_TOOLS_DIR}/libets_interop_js_napi.so" ]]; then
    cp "${ARK_HOST_TOOLS_DIR}/libets_interop_js_napi.so" "${WORKSPACE_DIR}/module/"
  fi
}

compile_suite() {
  local suite_src="${REPO_ROOT}/test/ohos/suites/basic.ts"
  local suite_out="${WORKSPACE_DIR}/basic.abc"

  "${ARK_ES2ABC}" --merge-abc --extension=ts --module --output "${suite_out}" "${suite_src}"
}

run_suite() {
  : > "${LOG_FILE}"
  (
    cd "${WORKSPACE_DIR}"
    export LD_LIBRARY_PATH="${WORKSPACE_DIR}:${WORKSPACE_DIR}/module:${ARK_HOST_TOOLS_DIR}:${LD_LIBRARY_PATH:-}"
    "${ARK_JS_NAPI_CLI}" --entry-point basic basic.abc
  ) >"${LOG_FILE}" 2>&1 &

  local suite_pid=$!
  local deadline=$((SECONDS + TEST_TIMEOUT_SEC))

  while kill -0 "${suite_pid}" 2>/dev/null; do
    if grep -q '^__ZIG_NAPI_TEST_RESULT__' "${LOG_FILE}" 2>/dev/null; then
      kill -TERM "${suite_pid}" 2>/dev/null || true
      wait "${suite_pid}" >/dev/null 2>&1 || true
      break
    fi
    if (( SECONDS >= deadline )); then
      kill -TERM "${suite_pid}" 2>/dev/null || true
      sleep 1
      kill -KILL "${suite_pid}" 2>/dev/null || true
      wait "${suite_pid}" >/dev/null 2>&1 || true
      echo "ArkVM suite timed out after ${TEST_TIMEOUT_SEC}s" >&2
      cat "${LOG_FILE}" >&2
      exit 124
    fi
    sleep 0.2
  done

  cat "${LOG_FILE}"
  grep -q '^__ZIG_NAPI_TEST_RESULT__ status=ok' "${LOG_FILE}"
}

cleanup() {
  if [[ "${KEEP_WORKDIR}" != "1" ]]; then
    rm -rf "${WORK_ROOT}"
  fi
}

require_host_bundle
build_host_addon
prepare_workspace
compile_suite
run_suite
cleanup
