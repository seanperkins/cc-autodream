#!/bin/bash
# Unit tests for bin/slim-transcript.sh's jq pre-pass.
#
# The pre-pass handles two transcript schemas that store tool output in
# completely different places, and it fails SILENTLY when it gets one wrong: jq
# exits 0 and writes a valid file, so the shell fallback never fires and the
# line-based pass downstream happily truncates an OMP envelope at '"content":['.
# The worker then receives ID soup and returns no findings, which looks exactly
# like a quiet day.
#
# So these assertions are about what SURVIVES the strip, not about whether the
# script exits 0. Every one of them passed a smoke test before it was written.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
SLIM="$REPO/bin/slim-transcript.sh"

pass=0; fail=0
ok(){ printf '  ok   - %s\n' "$1"; pass=$((pass + 1)); }
no(){ printf '  FAIL - %s\n' "$1"; fail=$((fail + 1)); }
assert_eq(){ [ "$1" = "$2" ] && ok "$3" || no "$3 (got [$1] want [$2])"; }
has(){ case "$2" in *"$1"*) ok "$3" ;; *) no "$3 (got: [$2])" ;; esac; }
# An EMPTY haystack is a failure, not a pass. Every `hasnt` in this file was
# vacuous whenever the slimmer produced no output at all — the strongest possible
# regression, a slimmer that emits nothing, satisfied all of them. The guard lives
# in the helper because the defect is the helper's, not any one call site's.
# `has` and `jq_is` already fail on empty input by construction.
hasnt(){
  [ -n "$2" ] || { no "$3 (nothing to check: the slimmer produced no output)"; return; }
  case "$2" in *"$1"*) no "$3 (found [$1] in: [$2])" ;; *) ok "$3" ;; esac
}
# Type and presence claims go through jq, never through a substring match.
# The first version asserted `hasnt '\\"file\\"'` to mean "not stringified" —
# jq emits ONE backslash there, so the pattern could never match and the
# assertion passed whatever the code did. It survived the red-then-green check
# for the same reason. An assertion that cannot fail is decoration.
jq_is(){ # $1=slimmer output (may be several lines) $2=jq expr $3=want $4=msg
  local rec g rc
  rec=$(printf '%s\n' "$1" | grep -m1 '^{')
  # jq's exit status is checked. Ignoring it meant a record that produced the
  # expected value and THEN hit malformed bytes still passed.
  g=$(printf '%s' "$rec" | jq -r "$2" 2>/dev/null); rc=$?
  [ "$rc" -eq 0 ] || { no "$4 (jq exit $rc on: [$rec])"; return; }
  assert_eq "$g" "$3" "$4"
}

[ -x "$SLIM" ] || {
  printf '  FAIL - bin/slim-transcript.sh missing or not executable\n'
  printf '\npassed: 0   failed: 1\n'; exit 1; }
command -v jq >/dev/null 2>&1 || {
  printf '  ok   - jq not installed; the pre-pass is skipped and so is this suite\n'
  printf '\npassed: 1   failed: 0\n'; exit 0; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/slimtest.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

# Run the slimmer over one JSONL record and print the result. head/tail/cap are
# raised well clear so ONLY the jq pre-pass is under test; the line-based pass is
# a separate mechanism and would otherwise mask what the pre-pass did.
slim_one() { # $1=json record -> slimmed record on stdout, or nothing on failure
  printf '%s\n' "$1" > "$TMP/in.jsonl"
  # Remove the destination FIRST and check the exit status. Without both, a
  # failed invocation left the previous case's output sitting at $TMP/out.txt
  # and the grep below returned THAT — so a broken slimmer would be asserted
  # against a stale record from an earlier assertion and pass.
  rm -f "$TMP/out.txt"
  AUTODREAM_SLIM_MAXLINE=100000 AUTODREAM_SLIM_HEAD=9000 AUTODREAM_SLIM_TAIL=9000 \
  AUTODREAM_SLIM_CAP=100000000 \
    "$SLIM" "$TMP/in.jsonl" "$TMP/out.txt" >/dev/null 2>&1 || return 1
  # The WHOLE output, not `grep -m1 '^{'`. Returning only the first record meant
  # every negative assertion inspected one line, so a slimmer emitting a clean
  # record followed by the original payload on line two passed them all. jq_is
  # picks the first record out for itself.
  cat "$TMP/out.txt" 2>/dev/null
}

echo "# slim: the script parses at all"
# Cheap, and it would have caught the bug that produced this line. The jq program
# is a single-quoted shell string, so ONE apostrophe anywhere inside it — in a
# comment, in the word "commit's" — terminates the quote and the whole file stops
# parsing. CLAUDE.md documents this trap for run.sh's L1 worker body; it applies
# to every single-quoted program in this repo.
if bash -n "$SLIM" 2>/dev/null; then ok "bin/slim-transcript.sh parses"
else no "bin/slim-transcript.sh has a shell syntax error (stray apostrophe in the jq program?)"; fi

echo "# slim: a null or absent value is not turned into the string \"null\""
# The bug this suite was written for. `trunc` ran `tostring` unconditionally, so
# a toolResult carrying no content came out asserting the literal text "null" —
# a value the worker reads as real tool output.
got=$(slim_one '{"message":{"role":"toolResult","content":null,"toolName":"Read"}}')
# BOTH assertions, because `type` alone reports "null" for an absent key too, so
# a regression that simply deleted .content would satisfy the type check.
jq_is "$got" '.message | has("content")' 'true' "an explicit null .content is KEPT, not deleted"
jq_is "$got" '.message.content | type' 'null' "and stays JSON null, not the string \"null\""
has '"toolName":"Read"' "$got" "and the rest of the record survives"

got=$(slim_one '{"message":{"role":"toolResult","toolName":"Read"}}')
jq_is "$got" '.message | has("content")' 'false' "an ABSENT .content is not invented as a key"
jq_is "$got" '.message.toolName' 'Read' "and the surrounding record is not simply dropped"

echo "# slim: a small structured value keeps its structure"
# tostring flattened `arguments` to an escaped JSON string even 40x under the
# cap, so triage lost the field names it reads. Structure is the payload here.
got=$(slim_one '{"message":{"content":[{"type":"toolCall","arguments":{"file":"a.txt","n":3}}]}}')
jq_is "$got" '.message.content[0].arguments | type' 'object' \
  "short arguments stay an OBJECT, not an escaped string"
jq_is "$got" '.message.content[0].arguments.file' 'a.txt' "and the field names triage reads survive"

# The false branch of the second has() guard. Without a fixture that OMITS
# arguments, a regression reintroducing a bare `.arguments = (...)` assignment
# would invent the key and every assertion above would still pass.
got=$(slim_one '{"message":{"content":[{"type":"toolCall","toolName":"Read"}]}}')
jq_is "$got" '.message.content[0] | has("arguments")' 'false' \
  "an ABSENT .arguments is not invented either"
jq_is "$got" '.message.content[0].type' 'toolCall' "and that block is not simply dropped"

echo "# slim: thinking blocks are capped without being fabricated"
got=$(slim_one '{"message":{"content":[{"type":"thinking","signature":"sig1"}]}}')
jq_is "$got" '.message.content[0] | has("thinking")' 'false' \
  "an ABSENT .thinking is not invented as an empty string"
jq_is "$got" '.message.content[0].signature' 'sig1' "and the block survives"
got=$(slim_one '{"message":{"content":[{"type":"thinking","thinking":null}]}}')
jq_is "$got" '.message.content[0].thinking | type' 'null' \
  "an explicit null .thinking stays null, not \"\""
bigt=$(printf 'y%.0s' $(seq 1 900))
got=$(slim_one "{\"message\":{\"content\":[{\"type\":\"thinking\",\"thinking\":\"$bigt\"}]}}")
has 'autodream: truncated' "$got" "a 900-char thinking block is capped at 800"

echo "# slim: an oversized value IS truncated"
# The cap has to still work, or the fix above traded one silent failure for a
# different one. 700 chars against a 600-char cap.
big=$(printf 'x%.0s' $(seq 1 700))
got=$(slim_one "{\"message\":{\"role\":\"toolResult\",\"content\":\"$big\"}}")
has 'autodream: truncated' "$got" "a 700-char content is truncated at the 600 cap"
[ "${#got}" -lt 900 ] && ok "and the record shrank" || no "and the record shrank (len ${#got})"

echo "# slim: Claude Code tool_result blocks are stripped, provenance kept"
got=$(slim_one '{"message":{"content":[{"type":"tool_result","tool_use_id":"tu_1","is_error":true,"content":[{"type":"text","text":"HUGE"}]}]}}')
has 'payload stripped' "$got" "the marker is inserted"
hasnt 'HUGE' "$got" "and the original payload is actually GONE, not just annotated"
has '"tool_use_id":"tu_1"' "$got" "tool_use_id is kept so triage can name the call"
has '"is_error":true' "$got" "is_error is kept so triage can tell a failure"

echo "# slim: image payloads leave, in BOTH shapes"
# This branch claimed to strip base64 image data from the day it was written and
# did not, for image_url. It set .source (Claude's field) on a block whose payload
# lives at .image_url.url, so the base64 stayed and the record gained a marker
# saying it had gone. A receipt for a deletion that never happened.
got=$(slim_one '{"message":{"content":[{"type":"image_url","image_url":{"url":"data:image/png;base64,SECRETPAYLOAD"}}]}}')
hasnt 'SECRETPAYLOAD' "$got" "an image_url base64 payload is actually removed"
has 'image stripped' "$got" "and the block says so"
got=$(slim_one '{"message":{"content":[{"type":"image","source":{"data":"BASE64HERE"}}]}}')
hasnt 'BASE64HERE' "$got" "a Claude image .source payload is actually removed"
got=$(slim_one '{"message":{"content":[{"type":"image_url","alt":"a chart"}]}}')
jq_is "$got" '.message.content[0] | has("image_url")' 'false' \
  "an image_url block with no payload does not have one invented"

echo "# slim: OMP image .data is stripped only when it IS a payload"
# Grounded in the corpus, not the schema. All 289 image blocks across 400 real OMP
# transcripts on the author's host carry `blob:sha256:<hash>` — a 76-char
# content-addressed reference, 22KB in total against a 262144-byte cap. Marking
# those "stripped" would delete an identifier and reclaim nothing, so only an
# inline data: URI counts as a payload here.
got=$(slim_one '{"message":{"content":[{"type":"image","data":"blob:sha256:ea5b55c53f28e07af31be6686b1281d9e4cd7bab9fbf9c4f65dc432affd2a010","mimeType":"image/webp"}]}}')
has 'blob:sha256:ea5b55c5' "$got" "a blob reference SURVIVES; it is an id, not a payload"
jq_is "$got" '.message.content[0].mimeType' 'image/webp' "and the block keeps its metadata"
got=$(slim_one '{"message":{"content":[{"type":"image","data":"data:image/png;base64,SECRETPAYLOAD","mimeType":"image/png"}]}}')
hasnt 'SECRETPAYLOAD' "$got" "an inline data: URI payload is removed"
jq_is "$got" '.message.content[0].mimeType' 'image/png' "while its metadata is kept"

echo "# slim: a tool_result with no content does not claim one was stripped"
got=$(slim_one '{"message":{"content":[{"type":"tool_result","tool_use_id":"u1"}]}}')
jq_is "$got" '.message.content[0] | has("content")' 'false' \
  "no content key is invented on a payload-free tool_result"
jq_is "$got" '.message.content[0].tool_use_id' 'u1' "and the block survives"

echo "# slim: a null or empty field is not marked as a stripped payload"
# Presence is not a payload. `has("details")` is true when details is null, so
# every marker site announced a removal that never happened when the field was
# there but empty. One level in from the bug the markers exist to prevent.
jq_is "$(slim_one '{"message":{"role":"toolResult","details":null,"content":"x"}}')" \
  '.message.details | type' 'null' "a null .details is left alone, not marked stripped"
jq_is "$(slim_one '{"message":{"content":[{"type":"image","source":null}]}}')" \
  '.message.content[0].source | type' 'null' "a null image .source is left alone"
jq_is "$(slim_one '{"message":{"content":[{"type":"image_url","image_url":{}}]}}')" \
  '.message.content[0].image_url | length' '0' "an EMPTY image_url carries no url, so nothing is claimed"
jq_is "$(slim_one '{"message":{"content":[{"type":"tool_result","tool_use_id":"u1","content":null}]}}')" \
  '.message.content[0].content | type' 'null' "a null tool_result .content is left alone"

echo "# slim: OMP toolResult details are stripped"
got=$(slim_one '{"message":{"role":"toolResult","details":{"big":"payload"},"content":"short"}}')
has 'details stripped' "$got" "OMP .details gets the marker"
hasnt '"big":"payload"' "$got" "and the original details payload is actually gone"
has '"content":"short"' "$got" "a short OMP content survives intact"

echo "# slim: providerPayload never survives"
got=$(slim_one '{"message":{"role":"assistant","providerPayload":{"raw":"secretish"},"content":"hi"}}')
jq_is "$got" '.message.content' 'hi' "the assistant record itself survives"
hasnt 'providerPayload' "$got" "the raw provider round-trip is dropped"
hasnt 'secretish' "$got" "and its contents go with it"

echo "# slim: a record the pre-pass does not understand passes through"
# The fallback is the whole reason this is safe to run on an unknown schema.
# (The fixture was queue-operation until that became a KNOWN dropped type; a
# genuinely unknown type is what this assertion is about.)
got=$(slim_one '{"type":"some-future-type","payload":{"a":1}}')
has 'some-future-type' "$got" "an unknown record shape is not dropped"

# Every fixture below pairs its record with a sentinel conversation record. If
# the pre-pass emits NOTHING (every record dropped) the script treats that as a jq
# failure and falls back to the raw line pass, which would hand the dropped record
# straight back and fail an assertion that the drop worked.
SENT='{"type":"user","timestamp":"2026-10-01T09:00:00.000Z","message":{"role":"user","content":"sentinel"}}'
slim_with() { slim_one "$(printf '%s\n%s' "$SENT" "$1")"; }

echo "# slim: Claude Code bookkeeping and hook noise is dropped"
# On a real multi-day orchestrator session 3,560 of 11,782 lines were hooks, reminders and
# mode/permission-mode/last-prompt bookkeeping. The head/tail pass is positional,
# so it spent its whole budget on them and the worker saw almost no conversation.
for t in bridge-session last-prompt permission-mode mode atis-latch ai-title queue-operation file-history-snapshot file-history-delta dev-mods; do
  got=$(slim_with "{\"type\":\"$t\",\"timestamp\":\"2026-10-01T10:00:00.000Z\",\"x\":1}")
  has 'sentinel' "$got" "($t) the sentinel conversation record survives"
  hasnt "\"type\":\"$t\"" "$got" "a $t record is dropped"
done
got=$(slim_with '{"type":"attachment","timestamp":"2026-10-01T10:00:00.000Z","attachment":{"type":"hook_success","stdout":"HOOKOUT"}}')
hasnt 'HOOKOUT' "$got" "a hook_success attachment is dropped"
got=$(slim_with '{"type":"attachment","timestamp":"2026-10-01T10:00:00.000Z","attachment":{"type":"total_tokens_reminder","text":"REMINDER"}}')
hasnt 'REMINDER' "$got" "a total_tokens_reminder attachment is dropped"
for st in stop_hook_summary turn_duration; do
  got=$(slim_with "{\"type\":\"system\",\"subtype\":\"$st\",\"timestamp\":\"2026-10-01T10:00:00.000Z\",\"content\":\"SYSNOISE\"}")
  hasnt 'SYSNOISE' "$got" "a system/$st record is dropped"
done

echo "# slim: records that carry conversation signal are KEPT"
# queued_command is the user typing mid-turn; it is the only place that text lives.
got=$(slim_with '{"type":"attachment","timestamp":"2026-10-01T10:00:00.000Z","attachment":{"type":"queued_command","prompt":"also fix the footer"}}')
has 'also fix the footer' "$got" "a queued_command attachment (the user typing mid-turn) is kept"
# The L1 prompt names skill_listing twice: the HARD RULE that StructuredOutput is never
# fabricated_id (a tool absent from the listing is harness-provided) and the missed_skill
# category (what a known skill would have automated). Found in review, after the denylist
# was written: dropping every attachment but queued_command had dropped this one too.
got=$(slim_with '{"type":"attachment","timestamp":"2026-10-01T10:00:00.000Z","attachment":{"type":"skill_listing","content":"- python-env-management: sets up venvs"}}')
has 'python-env-management' "$got" "a skill_listing attachment is kept (the L1 prompt relies on it)"
got=$(slim_with '{"type":"system","subtype":"compact_boundary","timestamp":"2026-10-01T10:00:00.000Z","content":"Conversation compacted"}')
has 'Conversation compacted' "$got" "a system/compact_boundary record is kept (drift_after_compaction needs the marker)"
got=$(slim_with '{"type":"system","subtype":"away_summary","timestamp":"2026-10-01T10:00:00.000Z","content":"AWAYRECAP"}')
has 'AWAYRECAP' "$got" "a system/away_summary recap is kept"
got=$(slim_with '{"type":"pr-link","prNumber":42,"prUrl":"https://example.test/pr/42"}')
has 'pr/42' "$got" "a pr-link record is kept"
got=$(slim_with '{"type":"summary","summary":"COMPACTED EARLIER WORK","leafUuid":"l1"}')
has 'COMPACTED EARLIER WORK' "$got" "a compaction summary record is kept"

echo "# slim: kept Claude Code lines are reshaped so the 400-char budget buys payload"
# Key order put timestamp AFTER message, so the 400-char cut dropped it from 3,560
# lines, and the envelope (parentUuid, uuid, cwd, sessionId, version, gitBranch,
# userType, toolUseResult, message.usage/id/model) ate ~185 chars before content began.
UREC='{"parentUuid":"p1","isSidechain":false,"userType":"external","cwd":"/x/y","sessionId":"s1","version":"2.1.0","gitBranch":"main","type":"user","message":{"role":"user","content":"hello world"},"uuid":"u1","timestamp":"2026-10-01T14:21:52.155Z","toolUseResult":{"big":"payload"}}'
got=$(slim_one "$UREC")
jq_is "$got" 'keys_unsorted[0]' 'type' "type is the first key"
jq_is "$got" 'keys_unsorted[1]' 'timestamp' "timestamp is the second key, ahead of the payload"
jq_is "$got" '.message | keys_unsorted | join(",")' 'role,content' "message is reduced to role and content"
jq_is "$got" '.message.content' 'hello world' "and the user text survives"
jq_is "$got" '.isSidechain' 'false' "isSidechain is kept"
for k in parentUuid uuid cwd sessionId version gitBranch userType toolUseResult; do
  hasnt "\"$k\"" "$got" "envelope field $k is dropped"
done
first=$(printf '%s\n' "$got" | grep -m1 '^{' | cut -c1-80)
has '"timestamp":"2026-10-01T14:21:52.155Z"' "$first" "the timestamp sits inside the first 80 chars"

AREC='{"parentUuid":"p2","type":"assistant","message":{"model":"claude-opus-5-5","id":"msg_1","type":"message","role":"assistant","content":[{"type":"thinking","thinking":"hmm","signature":"AAAASIGNATUREBLOB"},{"type":"tool_use","id":"tu1","name":"Bash","input":{"command":"ls"}}],"usage":{"input_tokens":9}},"uuid":"a1","timestamp":"2026-10-01T14:21:53.000Z"}'
got=$(slim_one "$AREC")
hasnt 'SIGNATUREBLOB' "$got" "a thinking signature blob is dropped"
jq_is "$got" '.message.content[0].thinking' 'hmm' "while the thinking text stays"
jq_is "$got" '.message.content[1].input.command' 'ls' "and a tool_use command survives"
jq_is "$got" '.message | keys_unsorted | join(",")' 'role,content' "an assistant message loses model, id, type and usage"

# Nothing is invented: the existing suite is strict about that, and a reshape that
# writes {type, timestamp} unconditionally would add timestamp:null to every record
# that has none.
got=$(slim_one '{"type":"user","message":{"role":"user","content":"no clock"}}')
jq_is "$got" 'has("timestamp")' 'false' "a record with no timestamp does not gain a null one"
got=$(slim_one '{"type":"user","timestamp":"2026-10-01T14:21:52.155Z","message":{"content":"no role"}}')
jq_is "$got" '.message | has("role")' 'false' "a message with no role does not gain a null role"

echo "# slim: OMP and other non-Claude records pass through UNCHANGED"
# A denylist by Claude Code .type is the only safe shape. An allowlist of
# user/assistant would delete every OMP record, and the worker would return an
# empty findings list that reads exactly like a quiet night.
OMPREC='{"type":"message","id":"a1","parentId":"p0","timestamp":"2026-08-25T00:43:56.469Z","message":{"role":"toolResult","toolName":"Read","content":"short","details":null,"usage":{"input":1}}}'
got=$(slim_one "$OMPREC")
assert_eq "$(printf '%s\n' "$got" | grep -m1 '^{' | jq -cS .)" "$(printf '%s' "$OMPREC" | jq -cS .)" \
  "an OMP message record is byte-for-byte equivalent after the pre-pass"
for rec in '{"type":"custom","customType":"x","data":{"a":1}}' '{"type":"custom_message","customType":"x","content":"hi"}' '{"type":"title","title":"T"}' '{"type":"session","id":"s1","cwd":"/x"}' '{"type":"title_change","title":"T2"}' '{"type":"thinking_level_change","thinkingLevel":"high"}'; do
  want=$(printf '%s' "$rec" | jq -cS .)
  got=$(slim_with "$rec" | grep -F "\"type\":\"$(printf '%s' "$rec" | jq -r .type)\"" | head -1 | jq -cS . 2>/dev/null)
  assert_eq "$got" "$want" "an OMP $(printf '%s' "$rec" | jq -r .type) record passes through unchanged"
done

echo "# slim: head and tail are counted over the surviving conversation lines"
# Counted over the raw stream, 400 head lines of a 3,479-line session were mostly
# noise. Six conversation lines padded with twelve noise lines: keeping 2 head and
# 2 tail must keep conversation turns 1,2,5,6 and elide 2 OF 6, not 14 of 18.
: > "$TMP/budget.jsonl"
for i in 1 2 3 4 5 6; do
  printf '{"type":"user","timestamp":"2026-10-01T10:00:0%d.000Z","message":{"role":"user","content":"turn%d"}}\n' "$i" "$i" >> "$TMP/budget.jsonl"
  printf '{"type":"mode","mode":"auto"}\n{"type":"attachment","attachment":{"type":"hook_success"}}\n' >> "$TMP/budget.jsonl"
done
rm -f "$TMP/budget.out"
AUTODREAM_SLIM_HEAD=2 AUTODREAM_SLIM_TAIL=2 "$SLIM" "$TMP/budget.jsonl" "$TMP/budget.out" >/dev/null 2>&1
out=$(cat "$TMP/budget.out" 2>/dev/null)
has '[2 of 6 lines elided' "$out" "elision is measured against the 6 conversation lines, not the 18 raw ones"
for t in turn1 turn2 turn5 turn6; do has "$t" "$out" "$t is inside the kept head or tail"; done
for t in turn3 turn4; do hasnt "$t" "$out" "$t is in the elided middle"; done

echo "# slim: AUTODREAM_SLIM_FULL=1 keeps every conversation line (the chunker reads this)"
: > "$TMP/full.jsonl"
for i in $(seq 1 50); do
  printf '{"type":"user","timestamp":"2026-10-01T10:00:00.000Z","message":{"role":"user","content":"turn%d"}}\n' "$i" >> "$TMP/full.jsonl"
done
rm -f "$TMP/full.out" "$TMP/notfull.out"
AUTODREAM_SLIM_FULL=1 AUTODREAM_SLIM_HEAD=2 AUTODREAM_SLIM_TAIL=2 AUTODREAM_SLIM_CAP=100 \
  "$SLIM" "$TMP/full.jsonl" "$TMP/full.out" >/dev/null 2>&1
assert_eq "$(grep -c '"type":"user"' "$TMP/full.out" 2>/dev/null)" "50" \
  "FULL keeps all 50 lines even with head, tail and cap set tiny"
hasnt 'elided' "$(cat "$TMP/full.out" 2>/dev/null)" "and does not announce an elision"
AUTODREAM_SLIM_HEAD=2 AUTODREAM_SLIM_TAIL=2 "$SLIM" "$TMP/full.jsonl" "$TMP/notfull.out" >/dev/null 2>&1
has 'elided' "$(cat "$TMP/notfull.out" 2>/dev/null)" "control: without FULL the same input IS elided"

echo "# slim: non-JSONL input falls back instead of producing nothing"
printf 'this is not json\nnor is this\n' > "$TMP/plain.txt"
AUTODREAM_SLIM_MAXLINE=100000 "$SLIM" "$TMP/plain.txt" "$TMP/plain.out" >/dev/null 2>&1
rc=$?
assert_eq "$rc" "0" "a non-JSONL transcript still exits 0"
[ -s "$TMP/plain.out" ] && ok "and still writes output" || no "and still writes output"
has 'this is not json' "$(cat "$TMP/plain.out" 2>/dev/null)" "the original text survives the fallback"

echo "# slim: a report-day window slices the transcript BEFORE anything else"
# A multi-day orchestrator is one file. Without the slice the worker sees every day
# of it on every night it is triaged. The slice runs first because it needs the
# ORIGINAL timestamp, which the reshape would otherwise have to carry through.
# 1790812800..1790899200 is 2026-10-01 in UTC.
WSTART=1790812800; WEND=1790899200
{ printf '{"type":"user","timestamp":"2026-09-30T10:00:00Z","message":{"role":"user","content":"DAYBEFORE"}}\n'
  printf '{"type":"user","timestamp":"2026-10-01T10:00:00Z","message":{"role":"user","content":"DAYINSIDE"}}\n'
  printf '{"type":"user","timestamp":"2026-10-02T10:00:00Z","message":{"role":"user","content":"DAYAFTER"}}\n'; } > "$TMP/win.jsonl"
rm -f "$TMP/win.out" "$TMP/nowin.out" "$TMP/emptywin.out"
AUTODREAM_WINDOW_START_EPOCH=$WSTART AUTODREAM_WINDOW_END_EPOCH=$WEND "$SLIM" "$TMP/win.jsonl" "$TMP/win.out" >/dev/null 2>&1
out=$(cat "$TMP/win.out" 2>/dev/null)
has 'DAYINSIDE' "$out" "the in-window record is kept"
hasnt 'DAYBEFORE' "$out" "a record from the day before is dropped"
hasnt 'DAYAFTER' "$out" "a record from the day after is dropped"
"$SLIM" "$TMP/win.jsonl" "$TMP/nowin.out" >/dev/null 2>&1
out=$(cat "$TMP/nowin.out" 2>/dev/null)
has 'DAYBEFORE' "$out" "control: with no window set nothing is sliced"
has 'DAYAFTER' "$out" "control: the day after is kept too"
# An empty slice means the file has no records the window can place (the enumeration
# gate already refused any file that HAS timestamps and none in the day). Hand the
# worker the whole transcript rather than nothing, as the no-clock case always did.
{ printf '{"type":"user","message":{"role":"user","content":"NOCLOCK"}}\n'; } > "$TMP/noclock.jsonl"
AUTODREAM_WINDOW_START_EPOCH=$WSTART AUTODREAM_WINDOW_END_EPOCH=$WEND "$SLIM" "$TMP/noclock.jsonl" "$TMP/emptywin.out" >/dev/null 2>&1
has 'NOCLOCK' "$(cat "$TMP/emptywin.out" 2>/dev/null)" "a transcript with no clock survives a window (empty slice falls back to the whole file)"

echo "# slim: nothing it writes is readable by another local account"
# Source transcripts are 0600, and the day slice is the UNSTRIPPED record stream (tool output
# with whatever credentials it held), written before the stripping pass. Under the usual 022
# umask every redirection in this script created a 0644 copy at a predictable path (found in
# review). The script now sets its own umask, so the output is private whatever the caller has.
printf '%s\n' "$SENT" > "$TMP/mode.jsonl"
rm -f "$TMP/mode.out"
( umask 022; AUTODREAM_WINDOW_START_EPOCH=1790812800 AUTODREAM_WINDOW_END_EPOCH=1790899200 "$SLIM" "$TMP/mode.jsonl" "$TMP/mode.out" >/dev/null 2>&1 )
assert_eq "$(stat -f %Lp "$TMP/mode.out" 2>/dev/null)" "600" "the slimmed output is mode 600 even when the caller umask is 022"
ls "$TMP"/mode.out.win.[0-9]*.jsonl >/dev/null 2>&1 && no "the raw day slice is removed" || ok "the raw day slice is removed"

echo "# slim: full mode ends on a transcript line, not on the footer"
# The footer is plain text. In full mode the output is cut into chunks, so the footer landed in the
# last chunk as a non-JSON line the worker read as transcript content (found in review). The
# prompt already tells the worker that long lines are cut, and the chunk note now says it too.
printf '%s\n' "$SENT" > "$TMP/foot.jsonl"
rm -f "$TMP/foot-full.out" "$TMP/foot-def.out"
AUTODREAM_SLIM_FULL=1 "$SLIM" "$TMP/foot.jsonl" "$TMP/foot-full.out" >/dev/null 2>&1
hasnt 'autodream slimmed this transcript' "$(cat "$TMP/foot-full.out" 2>/dev/null)" "full mode appends no footer"
assert_eq "$(tail -1 "$TMP/foot-full.out" 2>/dev/null | jq -r .type 2>/dev/null)" "user" "and its last line is a transcript record"
"$SLIM" "$TMP/foot.jsonl" "$TMP/foot-def.out" >/dev/null 2>&1
has 'autodream slimmed this transcript' "$(cat "$TMP/foot-def.out" 2>/dev/null)" "control: default mode still appends the footer"

echo "# slim: stale files at its predictable paths do not keep their old mode"
# `>` onto an existing file keeps that file mode, so a 0644 leftover from an older run would stay
# readable while the new unstripped slice was written into it.
printf 'old\n' > "$TMP/stale.out"; printf 'old\n' > "$TMP/stale.out.win.jsonl"; printf 'old\n' > "$TMP/stale.out.pre.jsonl"
chmod 644 "$TMP/stale.out" "$TMP/stale.out.win.jsonl" "$TMP/stale.out.pre.jsonl"
AUTODREAM_WINDOW_START_EPOCH=1790812800 AUTODREAM_WINDOW_END_EPOCH=1790899200 "$SLIM" "$TMP/mode.jsonl" "$TMP/stale.out" >/dev/null 2>&1
assert_eq "$(stat -f %Lp "$TMP/stale.out" 2>/dev/null)" "600" "a pre-existing 0644 output is replaced by a 0600 one"
ls "$TMP"/stale.out.win.jsonl "$TMP"/stale.out.pre.jsonl >/dev/null 2>&1 && no "stale temp files are gone" || ok "stale temp files are gone"

echo "# slim: its own scratch cleanup never touches the input, and a bad cap falls back to the default"
# Found in the final pass: a direct call whose INPUT is named like the scratch file ("x.out.pre.jsonl"
# with destination "x.out") had its input removed, and a non-numeric AUTODREAM_SLIM_CAP made head -c
# fail, leaving a destination holding only the footer.
printf '%s\n' "$SENT" > "$TMP/sc.out.pre.jsonl"
"$SLIM" "$TMP/sc.out.pre.jsonl" "$TMP/sc.out" >/dev/null 2>&1
[ -s "$TMP/sc.out.pre.jsonl" ] && ok "an input named like a scratch file survives" || no "an input named like a scratch file survives"
: > "$TMP/capbad.jsonl"
for i in $(seq 1 30); do printf '{"type":"user","timestamp":"2026-10-01T10:00:00.000Z","message":{"role":"user","content":"capturn%d"}}\n' "$i" >> "$TMP/capbad.jsonl"; done
rm -f "$TMP/capbad.out"
AUTODREAM_SLIM_CAP=abc AUTODREAM_SLIM_HEAD=5 AUTODREAM_SLIM_TAIL=5 "$SLIM" "$TMP/capbad.jsonl" "$TMP/capbad.out" >/dev/null 2>&1
has 'capturn1' "$(cat "$TMP/capbad.out" 2>/dev/null)" "a non-numeric cap uses the default and the output still holds the records"

echo "# slim: no .pre.jsonl temp is left behind"
ls "$TMP"/*.pre.[0-9]*.jsonl >/dev/null 2>&1 && no "the pre-pass temp is cleaned up" \
  || ok "the pre-pass temp is cleaned up"

printf '\npassed: %s   failed: %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
