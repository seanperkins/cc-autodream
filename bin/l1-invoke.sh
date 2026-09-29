#!/bin/bash
# Shared L1 (per-session triage) invocation. Sourced by bin/run.sh and by the model
# benchmark (bench/run-one-l1.sh) so the benchmark measures the production call and
# the two cannot drift. Claude-harness only: other harnesses get their own adapters.
#
# No apostrophes in L1_APPEND_SYSTEM_PROMPT or in any function body a caller embeds
# inside a single-quoted `bash -c '...'` block.

L1_APPEND_SYSTEM_PROMPT='Headless triage worker. Read the session transcript and write exactly one findings JSON object, via the Write tool, to the literal output path given on line 2 of the prompt. Those paths are literal strings, not shell variables — never $-expand them. Print only the literal word done and exit.'

# l1_build_prompt TRANSCRIPT OUTPUT TRIAGE_MD [STATS_JSON] -> the L1 prompt on stdout.
# The paths are passed as LITERAL data so the worker hands them straight to Read/Write
# and never tries to $-expand them (see the 2026 worker-path failures).
l1_build_prompt() {
  printf 'Session transcript to analyze (literal absolute path): %s\n' "$1"
  printf 'Write your findings JSON to this literal absolute path: %s\n\n' "$2"
  cat "$3"
  if [ -n "${4:-}" ] && [ -s "$4" ]; then
    printf '\n## Precomputed session stats (authoritative — copy these into your output)\n\n```json\n'
    cat "$4"
    printf '\n```\n'
  fi
}

# l1_invoke_claude MODEL EFFORT OUTPUT_FORMAT  (prompt on stdin; needs $CLAUDE_BIN)
# EFFORT and OUTPUT_FORMAT are omitted from the argv when empty.
l1_invoke_claude() {
  local model="$1" effort="${2:-}" fmt="${3:-}"
  local -a args=(--print --permission-mode bypassPermissions --model "$model")
  [ -n "$effort" ] && args+=(--effort "$effort")
  [ -n "$fmt" ] && args+=(--output-format "$fmt")
  args+=(--no-session-persistence --tools Read Write --disable-slash-commands
         --strict-mcp-config --settings '{"disableAllHooks":true}'
         --append-system-prompt "$L1_APPEND_SYSTEM_PROMPT")
  "$CLAUDE_BIN" "${args[@]}"
}
