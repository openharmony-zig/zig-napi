#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." &>/dev/null && pwd)"

RESULT_MD="${BENCHMARK_RESULT_MD:-${REPO_ROOT}/.tmp_arkvm_runner/benchmark-result.md}"
MARKER="<!-- zig-napi-arkvm-benchmark -->"

if [[ "${GITHUB_EVENT_NAME:-}" != "pull_request" && "${GITHUB_EVENT_NAME:-}" != "pull_request_target" ]]; then
  echo "Not a pull request event; skip benchmark PR comment."
  exit 0
fi

if [[ -z "${GITHUB_REPOSITORY:-}" ]]; then
  echo "GITHUB_REPOSITORY is required to comment benchmark results." >&2
  exit 1
fi

if [[ ! -f "${RESULT_MD}" ]]; then
  echo "Benchmark result markdown not found: ${RESULT_MD}" >&2
  exit 1
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "GitHub CLI is required to comment benchmark results." >&2
  exit 1
fi

if [[ -z "${GH_TOKEN:-${GITHUB_TOKEN:-}}" ]]; then
  echo "GH_TOKEN or GITHUB_TOKEN is required to comment benchmark results." >&2
  exit 1
fi

PR_NUMBER="${PR_NUMBER:-}"
if [[ -z "${PR_NUMBER}" && "${GITHUB_REF:-}" =~ refs/pull/([0-9]+)/ ]]; then
  PR_NUMBER="${BASH_REMATCH[1]}"
fi
if [[ -z "${PR_NUMBER}" && "${GITHUB_REF_NAME:-}" =~ ^([0-9]+)/ ]]; then
  PR_NUMBER="${BASH_REMATCH[1]}"
fi
if [[ -z "${PR_NUMBER}" ]]; then
  echo "Unable to determine pull request number." >&2
  exit 1
fi

COMMENT_BODY="$(
  printf '%s\n\n' "${MARKER}"
  cat "${RESULT_MD}"
)"

COMMENT_ID="$(
  gh api "repos/${GITHUB_REPOSITORY}/issues/${PR_NUMBER}/comments" --paginate \
    --jq '.[] | select(.body | contains("<!-- zig-napi-arkvm-benchmark -->")) | .id' \
    | tail -n 1
)"

if [[ -n "${COMMENT_ID}" ]]; then
  gh api -X PATCH "repos/${GITHUB_REPOSITORY}/issues/comments/${COMMENT_ID}" -f body="${COMMENT_BODY}" >/dev/null
  echo "Updated benchmark comment on PR #${PR_NUMBER}."
else
  gh api -X POST "repos/${GITHUB_REPOSITORY}/issues/${PR_NUMBER}/comments" -f body="${COMMENT_BODY}" >/dev/null
  echo "Created benchmark comment on PR #${PR_NUMBER}."
fi
