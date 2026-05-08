#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." &>/dev/null && pwd)"

export ARKVM_TEST_SUITE="${ARKVM_TEST_SUITE:-memory-testing/memory.ts}"
export ARKVM_ENTRY_POINT="${ARKVM_ENTRY_POINT:-memory-testing/memory}"
export ARKVM_RESULT_PREFIX="${ARKVM_RESULT_PREFIX:-__ZIG_NAPI_MEMORY_RESULT__}"
export ARKVM_EXAMPLE_DIR="${ARKVM_EXAMPLE_DIR:-examples/memory}"
export ARKVM_WORK_ROOT="${ARKVM_WORK_ROOT:-${REPO_ROOT}/.tmp_arkvm_memory_runner}"
export ARKVM_WAIT_FOR_EXIT="${ARKVM_WAIT_FOR_EXIT:-1}"
export ARKVM_EXPECT_LOG="${ARKVM_EXPECT_LOG:-^__ZIG_NAPI_FINALIZER_RESULT__ status=ok external=128 class=128$}"
export TEST_TIMEOUT_SEC="${TEST_TIMEOUT_SEC:-180}"

exec "${SCRIPT_DIR}/run_arkvm_tests.sh"
