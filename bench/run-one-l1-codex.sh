#!/bin/bash
# Run ONE L1 triage through `codex exec` (same prompt as production, different harness).
# Usage: run-one-l1-codex.sh MODEL EFFORT FINDINGS_OUT TRANSCRIPT STATS CLI_JSON_OUT
# codex writes inside its workspace only, so the findings file is written under a scratch
# workdir and copied to FINDINGS_OUT afterwards. `codex exec --json` events go to
# CLI_JSON_OUT (token usage; codex reports no served model). stderr passes through.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
model="$1"; effort="$2"; out="$3"; transcript="$4"; stats="$5"; cli_json="$6"
CODEX_BIN="${CODEX_BIN:-codex}"
. "$REPO/bin/l1-invoke.sh"
workdir=$(mktemp -d "${TMPDIR:-/tmp}/bench-l1-codex.XXXXXX") || exit 70
trap 'rm -rf "$workdir"' EXIT
cd "$workdir" || exit 70
args=(exec --ephemeral --skip-git-repo-check --json -m "$model")
[ -n "$effort" ] && args+=(-c "model_reasoning_effort=$effort")
args+=(-s workspace-write -C "$workdir" -)
# Harness preamble: the same worker instructions production gives claude via --append-system-prompt,
# plus one sentence codex needs. It parses transcripts with a strict JSON reader and fails on the
# truncated lines a slimmed transcript deliberately contains, where the claude models just read text.
L1_CODEX_NOTE="Some lines of a slimmed transcript are cut off mid-JSON. That is expected: read them as plain text and triage what is present. It is never an error."
l1_build_prompt "$transcript" "$workdir/findings.json" "$REPO/prompts/SESSION_TRIAGE.md" "$stats" > "$workdir/prompt.txt"
{ head -n 3 "$workdir/prompt.txt"; printf '%s %s\n\n' "$L1_APPEND_SYSTEM_PROMPT" "$L1_CODEX_NOTE"; tail -n +4 "$workdir/prompt.txt"; } \
  | "$CODEX_BIN" "${args[@]}" > "$cli_json"
rc=$?
[ -s "$workdir/findings.json" ] && cp "$workdir/findings.json" "$out"
exit $rc
