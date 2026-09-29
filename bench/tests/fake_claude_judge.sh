#!/bin/bash
# Fake `claude` for judge tests: prints the CLI's JSON result with a schema-validated answer.
# FAKE_JUDGE_MODE: good | no_structured | is_error | bad_verdict | wrongmodel | cli_error |
#                  always_rate_limit | rate_limit_then_good
# FAKE_JUDGE_VERDICT (default same), FAKE_COUNTER + FAKE_FAIL_FIRST for rate_limit_then_good.
cat > /dev/null
model=""
while [ $# -gt 0 ]; do case "$1" in --model) model="$2"; shift 2 ;; *) shift ;; esac; done
mode="${FAKE_JUDGE_MODE:-good}"; verdict="${FAKE_JUDGE_VERDICT:-same}"; served="$model"
[ "$mode" = wrongmodel ] && served="claude-haiku-4-5"
case "$mode" in
  cli_error) echo "boom" >&2; exit 1 ;;
  always_rate_limit) echo "usage limit reached" >&2; exit 1 ;;
  rate_limit_then_good)
    n=$(cat "$FAKE_COUNTER" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$FAKE_COUNTER"
    if [ "$n" -le "${FAKE_FAIL_FIRST:-1}" ]; then echo "429 rate limit" >&2; exit 1; fi ;;
esac
[ "$mode" = bad_verdict ] && verdict="maybe"
iserr=false; [ "$mode" = is_error ] && iserr=true
so="\"structured_output\":{\"verdict\":\"$verdict\",\"reason\":\"because\"},"
[ "$mode" = no_structured ] && so=""
printf '{"type":"result","is_error":%s,"stop_reason":"tool_use",%s"total_cost_usd":0.05,"usage":{"input_tokens":10,"output_tokens":5},"modelUsage":{"%s":{"inputTokens":10,"outputTokens":5}}}\n' "$iserr" "$so" "$served"
