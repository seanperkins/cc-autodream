#!/bin/bash
# Fake `claude` for runner tests. Reads the prompt on stdin like the real CLI.
# FAKE_MODE: good | unclear | nooutput | badjson | hang | cli_error | always_rate_limit |
#            rate_limit_then_good | refusal | wrongmodel | nomodelusage
# FAKE_COUNTER: file used by rate_limit_then_good; FAKE_FAIL_FIRST: failures before success.
input=$(cat)
model=""
while [ $# -gt 0 ]; do
  case "$1" in --model) model="$2"; shift 2 ;; *) shift ;; esac
done
out=$(printf '%s\n' "$input" | sed -n '2p' | sed 's/^Write your findings JSON to this literal absolute path: //')
mode="${FAKE_MODE:-good}"
served="$model"
[ "$mode" = wrongmodel ] && served="claude-sonnet-5-5"
case "$mode" in
  hang) sleep 60; exit 0 ;;
  cli_error) echo "boom" >&2; exit 1 ;;
  always_rate_limit) echo "Error: usage limit reached" >&2; exit 1 ;;
  rate_limit_then_good)
    n=$(cat "$FAKE_COUNTER" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$FAKE_COUNTER"
    if [ "$n" -le "${FAKE_FAIL_FIRST:-1}" ]; then echo "API Error: 429 rate limit exceeded" >&2; exit 1; fi ;;
esac
case "$mode" in
  nooutput) : ;;
  badjson) printf 'this is not json' > "$out" ;;
  unclear) printf '{"session_path":"/x","project":"p","outcome":"unclear_from_transcript","satisfaction_signals":{"happy":0,"satisfied":0,"dissatisfied":0,"frustrated":0},"instructions_given":[],"notable_initiatives":["only session header read"],"findings":[]}' > "$out" ;;
  *) printf '{"session_path":"/x","project":"p","outcome":"fully_achieved","satisfaction_signals":{"happy":0,"satisfied":0,"dissatisfied":0,"frustrated":0},"instructions_given":[],"notable_initiatives":["did a thing"],"findings":[]}' > "$out" ;;
esac
stop=end_turn; [ "$mode" = refusal ] && stop=refusal
if [ "$mode" = nomodelusage ]; then mu=''; else
  mu=",\"modelUsage\":{\"$served\":{\"inputTokens\":10,\"outputTokens\":5,\"cacheReadInputTokens\":0,\"cacheCreationInputTokens\":100,\"costUSD\":0.01}}"
fi
printf '{"type":"result","subtype":"success","is_error":false,"stop_reason":"%s","result":"done","total_cost_usd":0.01,"usage":{"input_tokens":10,"output_tokens":5,"cache_creation_input_tokens":100,"cache_read_input_tokens":0}%s}\n' "$stop" "$mu"
