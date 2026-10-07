#!/bin/bash
# Run ONE L1 triage through the production invocation (the claude adapter's l1-argv, via bench/l1-prod.sh).
# Usage: run-one-l1.sh MODEL EFFORT FINDINGS_OUT TRANSCRIPT STATS CLI_JSON_OUT
# The claude CLI runs with --output-format json; its stdout goes to CLI_JSON_OUT so the
# runner can read the served model and usage. stderr passes through to the caller.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
model="$1"; effort="$2"; out="$3"; transcript="$4"; stats="$5"; cli_json="$6"
CLAUDE_BIN="${CLAUDE_BIN:-$HOME/.local/bin/claude}"
export CLAUDE_BIN
# Same token-minimal footprint run.sh exports for its workers.
export CLAUDE_CODE_DISABLE_CLAUDE_MDS=1 DISABLE_TELEMETRY=1 DISABLE_ERROR_REPORTING=1
. "$HERE/l1-prod.sh"
# Isolated cwd, like run.sh's worker dir, so any AI-title stub never lands in a real bucket.
workdir=$(mktemp -d "${TMPDIR:-/tmp}/bench-l1.XXXXXX") || exit 70
trap 'rm -rf "$workdir"' EXIT
cd "$workdir" || exit 70
l1_build_prompt "$transcript" "$out" "$REPO/prompts/SESSION_TRIAGE.md" "$stats" \
  | l1_invoke_claude "$model" "$effort" json > "$cli_json"
