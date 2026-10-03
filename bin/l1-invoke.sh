#!/bin/bash
# Shared L1 (per-session triage) invocation. Sourced by bin/run.sh and by the model
# benchmark (bench/run-one-l1.sh) so the benchmark measures the production call and
# the two cannot drift. Claude-harness only: other harnesses get their own adapters.
#
# No apostrophes in L1_APPEND_SYSTEM_PROMPT or in any function body a caller embeds
# inside a single-quoted `bash -c '...'` block.

L1_APPEND_SYSTEM_PROMPT='Headless triage worker. Read the session transcript and write exactly one findings JSON object, via the Write tool, to the literal output path given on line 2 of the prompt. Those paths are literal strings, not shell variables — never $-expand them. Print only the literal word done and exit.'

# l1_build_prompt TRANSCRIPT OUTPUT TRIAGE_MD [STATS_JSON [CHUNK_NOTE]] -> the L1 prompt on stdout.
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
  # Optional fifth argument: the chunk note for a transcript that is one chunk of a
  # longer session. Absent for an ordinary session, so its prompt is byte-for-byte
  # what it always was.
  if [ -n "${5:-}" ]; then
    printf '\n## Chunk note\n\n%s\n' "$5"
  fi
}

# l1_chunk_note I N ELIDED -> the chunk note text on stdout. The wording "chunk I of N of
# ONE session" is matched by tests/mock-claude.sh, so change both together.
l1_chunk_note() {
  printf 'This transcript is chunk %s of %s of ONE session, split at line boundaries. Other workers triage the other chunks. A tool call and its result can fall in different chunks, and the opening goal and the final outcome may be in a chunk other than yours. Long lines were cut by the slimmer, so a cut line is not malformed input. Report only what is in this chunk, and judge the outcome from the end state of this chunk.' "$1" "$2"
  if [ "${3:-0}" -gt 0 ] 2>/dev/null; then
    printf ' %s chunks from the middle of the session were omitted for size.' "$3"
  fi
}

# l1_chunk_ok FILE -> exit 0 only for a findings object that is not an error. A chunk
# answer is untrusted shape: a worker can write the error object the prompt tells it to
# emit on malformed input, a bare {}, or a wrongly typed findings field, and a transcript
# can nudge it to. Such an answer must be retried, never cached or merged around. EXACTLY one
# JSON value: plain jq -e judges only the last value in a file while the merge slurps them all,
# so an error object followed by a good object used to pass here and be merged around.
l1_chunk_ok() {
  [ -s "$1" ] && jq -s -e 'length == 1 and (.[0] | (type == "object") and (.error == null) and ((.findings | type) == "array"))' "$1" >/dev/null 2>&1
}

# l1_noise_gated STATS_FILE -> exit 0 when the noise gate would skip this session. One
# definition for the worker (which skips it) and select_escalations (which must not spend
# an escalation slot on it). Subagent transcripts and sessions with 5+ tool calls are never
# gated; an uncomputable duration never gates on the duration rule; a missing or unparseable
# sidecar never gates (bias to triage). Defaults: 2 user turns, 1 minute; either alone gates.
l1_noise_gated() {
  [ -s "$1" ] || return 1
  local g
  g=$(jq -r --argjson min_turns "${AUTODREAM_MIN_USER_TURNS:-2}" --argjson min_minutes "${AUTODREAM_MIN_MINUTES:-1}" \
    'if (.isSidechain == true) or ((.tool_call_count // 0) >= 5) then 0 elif (.user_message_count // 0) < $min_turns then 1 elif ((.duration_minutes // 0) > 0) and ((.duration_minutes // 0) < $min_minutes) then 1 else 0 end' "$1" 2>/dev/null)
  [ "$g" = "1" ]
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
