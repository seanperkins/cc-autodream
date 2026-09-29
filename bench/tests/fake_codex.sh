#!/bin/bash
# Fake `codex` for runner tests. Reads the prompt on stdin (the `-` argument) like the real CLI.
# FAKE_MODE: good | nooutput | badjson | hang | cli_error | always_rate_limit
# The findings path on prompt line 2 is honoured, and a JSONL event stream goes to stdout.
input=$(cat)
[ -n "${FAKE_CAPTURE:-}" ] && printf '%s' "$input" > "$FAKE_CAPTURE"
out=$(printf '%s\n' "$input" | sed -n '2p' | sed 's/^Write your findings JSON to this literal absolute path: //')
mode="${FAKE_MODE:-good}"
case "$mode" in
  hang) sleep 60; exit 0 ;;
  cli_error) echo "boom" >&2; exit 1 ;;
  always_rate_limit) echo "429 rate limit exceeded" >&2; exit 1 ;;
  nooutput) : ;;
  badjson) printf 'not json' > "$out" ;;
  *) printf '{"session_path":"/x","project":"p","outcome":"fully_achieved","satisfaction_signals":{"happy":0,"satisfied":0,"dissatisfied":0,"frustrated":0},"instructions_given":[],"notable_initiatives":["did a thing"],"findings":[]}' > "$out" ;;
esac
printf '%s\n' '{"type":"thread.started","thread_id":"t"}' '{"type":"turn.started"}' \
  '{"type":"item.completed","item":{"id":"i","type":"agent_message","text":"done"}}' \
  '{"type":"turn.completed","usage":{"input_tokens":1000,"cached_input_tokens":400,"cache_write_input_tokens":0,"output_tokens":50,"reasoning_output_tokens":10}}'
