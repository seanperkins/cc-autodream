#!/bin/bash
# bench/l1-prod.sh must stay the production L1 call: the argv is the claude adapter's, and the
# prompt framing is the text bin/run.sh sends. Run: bash bench/tests/l1_prod.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
pass=0; fail=0
ok() { pass=$((pass + 1)); printf '  ok   - %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL - %s\n' "$1"; }
eq() { if [ "$1" = "$2" ]; then ok "$3"; else no "$3 (got [$1] want [$2])"; fi; }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/bench-l1-prod.XXXXXX") || exit 70
trap 'rm -rf "$tmp"' EXIT
. "$REPO/bench/l1-prod.sh"

echo "# the prompt framing is the text run.sh sends"
printf 'TRIAGE BODY\n' > "$tmp/triage.md"
printf '{"turn_count":3}\n' > "$tmp/stats.json"
l1_build_prompt /t/s.jsonl /o/f.json "$tmp/triage.md" "$tmp/stats.json" > "$tmp/prompt.txt"
eq "$(sed -n '1p' "$tmp/prompt.txt")" "Session transcript to analyze (literal absolute path): /t/s.jsonl" "line 1 names the transcript"
eq "$(sed -n '2p' "$tmp/prompt.txt")" "Write your findings JSON to this literal absolute path: /o/f.json" "line 2 names the output"
eq "$(sed -n '4p' "$tmp/prompt.txt")" "TRIAGE BODY" "the triage document follows"
for frag in 'Session transcript to analyze (literal absolute path): %s' \
            'Write your findings JSON to this literal absolute path: %s' \
            '## Precomputed session stats (authoritative — copy these into your output)'; do
  if grep -qF -- "$frag" "$REPO/bin/run.sh" && grep -qF -- "$frag" "$REPO/bench/l1-prod.sh"; then ok "run.sh and the bench agree on: ${frag%%(*}"
  else no "run.sh and the bench agree on: $frag"; fi
done

echo "# the argv is the adapter's, with --effort controlled by the caller"
A="$REPO/adapters/claude/adapter.sh"
export CLAUDE_BIN=/opt/test/claude
eq "$(l1_argv claude-x low | tr '\0' '\n')" "$(AUTODREAM_L1_EFFORT_CLAUDE=low "$A" l1-argv claude-x | tr '\0' '\n')" "l1_argv is the adapter's l1-argv"
eq "$(l1_argv claude-x high | tr '\0' '\n' | sed -n '/^--effort$/{n;p;}')" "high" "an effort reaches --effort"
case "$(l1_argv claude-x "" | tr '\0' '\n')" in *--effort*) no "an empty effort drops --effort (the adapter default must not leak in)" ;; *) ok "an empty effort drops --effort (the adapter default must not leak in)" ;; esac
eq "$(l1_system_prompt | cut -c1-23)" "Headless triage worker." "the system prompt is read back from the adapter"

echo "# l1_invoke_claude runs the adapter's argv and appends the output format"
export CLAUDE_BIN="$HERE/fake_claude.sh"
printf 'Session transcript to analyze (literal absolute path): /t/s.jsonl\nWrite your findings JSON to this literal absolute path: %s\n' "$tmp/out.json" \
  | FAKE_MODE=good l1_invoke_claude claude-x low json > "$tmp/cli.json" 2> "$tmp/err.txt"
eq "$?" "0" "the fake claude accepted the production argv"
[ -s "$tmp/out.json" ] && ok "and wrote the findings file" || no "and wrote the findings file"

printf '\npassed: %s   failed: %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
