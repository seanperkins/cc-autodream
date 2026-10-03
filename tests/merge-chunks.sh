#!/bin/bash
# Unit tests for bin/merge-chunks.sh: turn N per-chunk L1 answers back into the ONE
# findings JSON per session that L2 and every other consumer already reads.
#
# The merge is mechanical on purpose (no model call), so it has to say what each field
# means when the answers disagree: the session's goal comes from where it began, its
# outcome from where it ended, and the authoritative stats (copied verbatim by every
# worker from one sidecar) are taken once rather than summed into nonsense.
#
# Contract: merge-chunks.sh --session PATH [--elided N] CHUNK.json ... > merged.json

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
MG="$REPO/bin/merge-chunks.sh"

pass=0; fail=0
ok(){ printf '  ok   - %s\n' "$1"; pass=$((pass + 1)); }
no(){ printf '  FAIL - %s\n' "$1"; fail=$((fail + 1)); }
assert_eq(){ [ "$1" = "$2" ] && ok "$3" || no "$3 (got [$1] want [$2])"; }

[ -x "$MG" ] || {
  printf '  FAIL - bin/merge-chunks.sh missing or not executable\n'
  printf '\npassed: 0   failed: 1\n'; exit 1; }
command -v jq >/dev/null 2>&1 || {
  printf '  ok   - jq not installed; this suite is skipped\n'
  printf '\npassed: 1   failed: 0\n'; exit 0; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/mgtest.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
SESS="/real/session.jsonl"

# chunk FILE GOAL OUTCOME FINDINGS_JSON [INITIATIVES_JSON] [INSTRUCTIONS_JSON]
chunk(){
  jq -cn --arg p "/slim/chunk.jsonl" --arg g "$2" --arg o "$3" --argjson f "$4" \
         --argjson ni "${5:-[]}" --argjson ig "${6:-[]}" \
    '{session_path:$p, project:"proj-a", started_at:"2026-10-01T10:00:00Z", turn_count:42, tool_call_count:7,
      tools_used:["Bash","Read"], skills_invoked:["s1"], models_used:["m1"],
      compliance_markers:{"RETRY-BUDGET":0,"FETCH-PIVOT":0,"DELEGATED":0,"DIRECT-OK":0},
      notable_initiatives:$ni, underlying_goal:(if $g == "" then null else $g end), outcome:$o,
      satisfaction_signals:{happy:1,satisfied:0,dissatisfied:0,frustrated:0},
      instructions_given:$ig, findings:$f}' > "$1"
}
F1='[{"category":"permission_prompt","severity":"low","what":"A","evidence_excerpt":"e","proposed_rule":"r"},{"category":"other","severity":"low","what":"SHARED","evidence_excerpt":"e","proposed_rule":"r"}]'
F2='[{"category":"retry_loop","severity":"high","what":"B","evidence_excerpt":"e","proposed_rule":"r"},{"category":"other","severity":"low","what":"SHARED","evidence_excerpt":"e","proposed_rule":"r"}]'

echo "# merge: the session is the original one, and the shape stays the L2 contract"
chunk "$TMP/c1.json" "" partially_achieved "$F1" '["init one"]' '["always test"]'
chunk "$TMP/c2.json" "build the thing" fully_achieved "$F2" '["init two","init one"]' '["always test","use fish"]'
"$MG" --session "$SESS" "$TMP/c1.json" "$TMP/c2.json" > "$TMP/m.json" 2>/dev/null; rc=$?
assert_eq "$rc" "0" "merge exits 0"
assert_eq "$(jq -r .session_path "$TMP/m.json")" "$SESS" "session_path is the ORIGINAL transcript, not a chunk file"
assert_eq "$(jq -r .meta.chunks "$TMP/m.json")" "2" "meta.chunks records how many chunks"
assert_eq "$(jq -r .meta.chunks_elided "$TMP/m.json")" "0" "meta.chunks_elided defaults to 0"

echo "# merge: goal from where the session began, outcome from where it ended"
assert_eq "$(jq -r .underlying_goal "$TMP/m.json")" "build the thing" "the first NON-NULL goal wins (chunk 1 had null)"
assert_eq "$(jq -r .outcome "$TMP/m.json")" "fully_achieved" "the LAST chunk's outcome wins"

echo "# merge: authoritative stats are taken once, not summed"
assert_eq "$(jq -r .turn_count "$TMP/m.json")" "42" "turn_count is the stats value, not 84"
assert_eq "$(jq -r .tool_call_count "$TMP/m.json")" "7" "tool_call_count is the stats value, not 14"
assert_eq "$(jq -c .tools_used "$TMP/m.json")" '["Bash","Read"]' "tools_used is not duplicated"
assert_eq "$(jq -r .project "$TMP/m.json")" "proj-a" "project survives"

echo "# merge: findings are unioned, tagged with their chunk, and de-duplicated"
assert_eq "$(jq -r '.findings | length' "$TMP/m.json")" "3" "A, B and ONE copy of the finding both chunks reported"
assert_eq "$(jq -r '[.findings[] | select(.what == "A")][0].chunk' "$TMP/m.json")" "1" "A is tagged chunk 1"
assert_eq "$(jq -r '[.findings[] | select(.what == "B")][0].chunk' "$TMP/m.json")" "2" "B is tagged chunk 2"
assert_eq "$(jq -r '[.findings[] | select(.what == "SHARED")][0].chunk' "$TMP/m.json")" "1" "the duplicate keeps the FIRST chunk's copy"
assert_eq "$(jq -r '.findings[0].severity' "$TMP/m.json")" "high" "findings are ordered most severe first"

echo "# merge: lists are unioned in order, instructions capped at 3"
assert_eq "$(jq -c .notable_initiatives "$TMP/m.json")" '["init one","init two"]' "notable_initiatives: order-preserving union"
assert_eq "$(jq -c .instructions_given "$TMP/m.json")" '["always test","use fish"]' "instructions_given: order-preserving union"
chunk "$TMP/c3.json" "g" fully_achieved '[]' '[]' '["i1","i2","i3","i4"]'
"$MG" --session "$SESS" "$TMP/c3.json" > "$TMP/m3.json" 2>/dev/null
assert_eq "$(jq -r '.instructions_given | length' "$TMP/m3.json")" "3" "instructions_given never exceeds 3 (the schema cap)"

echo "# merge: findings are capped at 10, most severe kept"
jq -cn '[range(0;12) | {category:"c",severity:(if . < 2 then "high" else "low" end),what:("w"+(.|tostring)),evidence_excerpt:"e",proposed_rule:"r"}]' > "$TMP/many.json"
chunk "$TMP/c4.json" "g" fully_achieved "$(cat "$TMP/many.json")"
"$MG" --session "$SESS" "$TMP/c4.json" > "$TMP/m4.json" 2>/dev/null
assert_eq "$(jq -r '.findings | length' "$TMP/m4.json")" "10" "12 findings are cut to 10"
assert_eq "$(jq -r '[.findings[] | select(.severity == "high")] | length' "$TMP/m4.json")" "2" "both high findings survive the cut"

echo "# merge: a chunk that returned an error object is excluded, not merged as data"
printf '{"session_path":"/slim/c","error":"unreadable","findings":[]}\n' > "$TMP/err.json"
chunk "$TMP/c5.json" "late goal" mostly_achieved "$F1"
"$MG" --session "$SESS" "$TMP/c5.json" "$TMP/err.json" > "$TMP/m5.json" 2>/dev/null
assert_eq "$(jq -r .outcome "$TMP/m5.json")" "mostly_achieved" "outcome comes from the last chunk that actually answered"
assert_eq "$(jq -r .meta.chunks_ok "$TMP/m5.json")" "1" "meta.chunks_ok counts only the answering chunks"
assert_eq "$(jq -r .meta.chunks "$TMP/m5.json")" "2" "meta.chunks still counts both"
"$MG" --session "$SESS" "$TMP/err.json" "$TMP/err.json" > "$TMP/m6.json" 2>/dev/null
assert_eq "$(jq -r 'has("error")' "$TMP/m6.json")" "true" "when EVERY chunk errored the merge is an error object"
assert_eq "$(jq -r '.findings | length' "$TMP/m6.json")" "0" "with an empty findings list, per the L1 error contract"
assert_eq "$(jq -r .session_path "$TMP/m6.json")" "$SESS" "and the original session path"

echo "# merge: elided chunks and signals pass through"
"$MG" --session "$SESS" --elided 6 "$TMP/c1.json" "$TMP/c2.json" > "$TMP/m7.json" 2>/dev/null
assert_eq "$(jq -r .meta.chunks_elided "$TMP/m7.json")" "6" "--elided is recorded in meta"
assert_eq "$(jq -r .satisfaction_signals.happy "$TMP/m.json")" "2" "satisfaction_signals are summed across chunks"

echo "# merge: wrongly typed fields from a worker never abort the merge"
# Found in review (two reviewers reproduced it): a finding with a numeric "what" made
# jq exit 5 ("string and number cannot be added"), a string where a list belongs made
# it exit 5 ("Cannot iterate over string"), and a string signal count concatenated
# into "11" with exit 0. Haiku can emit these unprompted, and a transcript can nudge it.
jq -cn '{session_path:"/slim/c", turn_count:42, outcome:"mostly_achieved", underlying_goal:"g2",
         notable_initiatives:"oops", instructions_given:"also oops",
         satisfaction_signals:{happy:"1", satisfied:2, dissatisfied:null, frustrated:"x"},
         findings:[{category:"c",severity:"low",what:123,evidence_excerpt:"e",proposed_rule:"r"},
                   "not an object",
                   {category:7,severity:"low",what:"W",evidence_excerpt:"e",proposed_rule:"r"}]}' > "$TMP/typed.json"
chunk "$TMP/c6.json" "g1" partially_achieved "$F1" '["init one"]' '["always test"]'
"$MG" --session "$SESS" "$TMP/c6.json" "$TMP/typed.json" > "$TMP/m8.json" 2>"$TMP/m8.err"; rc=$?
assert_eq "$rc" "0" "the merge still succeeds (exit 0)"
assert_eq "$(jq -r '.findings | length' "$TMP/m8.json" 2>/dev/null)" "4" "both object findings from the typed chunk are kept next to chunk 1's two; the bare string is dropped"
assert_eq "$(jq -c '.notable_initiatives' "$TMP/m8.json" 2>/dev/null)" '["init one"]' "a string where a list belongs contributes nothing, and does not crash"
assert_eq "$(jq -c '.instructions_given' "$TMP/m8.json" 2>/dev/null)" '["always test"]' "same for instructions_given"
assert_eq "$(jq -r '.satisfaction_signals | [.happy, .satisfied, .dissatisfied, .frustrated] | @csv' "$TMP/m8.json" 2>/dev/null)" "1,2,0,0" "signal counts are numeric sums: a string or null counts as 0, never concatenated"

echo "# gate: l1_chunk_ok and the merge agree on what ONE chunk answer is"
# Found in verification (three reviewers, two reproduced it): `jq -e` judges only the LAST value in
# a file while the merge slurps every value, so a file holding an error object followed by a good
# object passed the gate and was merged around, and every later chunk number was off by one.
. "$REPO/bin/l1-invoke.sh"
printf '%s\n' '{"findings":[],"outcome":"fully_achieved"}' > "$TMP/g-ok.json"
printf '%s\n' '{"error":"unreadable","findings":[]}' > "$TMP/g-err.json"
printf '%s\n%s\n' '{"error":"unreadable","findings":[]}' '{"findings":[],"outcome":"fully_achieved"}' > "$TMP/g-two.json"
printf '%s\n%s\n' '{"findings":[]}' '{"findings":[]}' > "$TMP/g-two-good.json"
l1_chunk_ok "$TMP/g-ok.json" && ok "one findings object passes" || no "one findings object passes"
l1_chunk_ok "$TMP/g-err.json" && no "an error object is rejected" || ok "an error object is rejected"
l1_chunk_ok "$TMP/g-two.json" && no "an error object FOLLOWED by a good object is rejected" || ok "an error object FOLLOWED by a good object is rejected"
l1_chunk_ok "$TMP/g-two-good.json" && no "two good objects in one file are rejected (that is two chunks, not one)" || ok "two good objects in one file are rejected (that is two chunks, not one)"

echo "# merge: bad input fails loudly and writes nothing"
printf 'this is not json' > "$TMP/bad.json"
out=$("$MG" --session "$SESS" "$TMP/c1.json" "$TMP/bad.json" 2>/dev/null); rc=$?
[ "$rc" -ne 0 ] && ok "an unparseable chunk file exits nonzero" || no "an unparseable chunk file exits nonzero"
assert_eq "${#out}" "0" "and nothing reaches stdout"
"$MG" --session "$SESS" >/dev/null 2>&1; assert_eq "$?" "2" "no chunk files exits 2 (usage)"
"$MG" "$TMP/c1.json" >/dev/null 2>&1; assert_eq "$?" "2" "a missing --session exits 2 (usage)"

printf '\npassed: %s   failed: %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
