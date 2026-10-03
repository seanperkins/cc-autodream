#!/bin/bash
# Unit tests for bin/session-window.sh: the local-day window over a transcript.
#
# Why this exists. Enumeration used to select a session by FILE MTIME inside the
# report day (`-newermt DAY ! -newermt NEXT`). A multi-day orchestrator is still
# being written, so its mtime is after the day ends and it was never selected; its
# subagents were, and the parent surfaced once as a single 200 MB blob. Dropping the
# upper bound fixes that and makes the in-transcript timestamp the only thing that
# says which day a record belongs to, so this helper has to be right about edges:
# the boundary second, fractional seconds, 23h and 25h DST days, records with no
# clock, and lines that are not JSON.
#
# Exit codes of `in-window` and `needs-slice` are a three-way contract (0 yes, 1 no,
# 2 error). The caller keeps a session on an error rather than dropping it, so a
# broken helper reads as extra work and never as a quiet night.

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
WIN="$REPO/bin/session-window.sh"

pass=0; fail=0
ok(){ printf '  ok   - %s\n' "$1"; pass=$((pass + 1)); }
no(){ printf '  FAIL - %s\n' "$1"; fail=$((fail + 1)); }
assert_eq(){ [ "$1" = "$2" ] && ok "$3" || no "$3 (got [$1] want [$2])"; }

[ -x "$WIN" ] || {
  printf '  FAIL - bin/session-window.sh missing or not executable\n'
  printf '\npassed: 0   failed: 1\n'; exit 1; }
command -v jq >/dev/null 2>&1 || {
  printf '  ok   - jq not installed; this suite is skipped\n'
  printf '\npassed: 1   failed: 0\n'; exit 0; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/swtest.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

# 2026-10-01 00:00:00Z and 2026-10-02 00:00:00Z, written as literals on purpose: a
# test that derives its expected bounds with the same `date` call as the code under
# test cannot disagree with it.
START=1790812800
END=1790899200

rec(){ printf '{"type":"user","timestamp":"%s","message":{"content":"%s"}}\n' "$1" "$2"; }
rc_of(){ "$@" >/dev/null 2>&1; printf '%s' "$?"; }

echo "# window: bounds are local midnight to local midnight"
assert_eq "$(TZ=UTC "$WIN" bounds 2026-10-01 2026-10-02)" "$START $END" "a UTC day is 1790812800..1790899200"
read -r a b <<< "$(TZ=America/New_York "$WIN" bounds 2026-03-08 2026-03-09)"
assert_eq "$((b - a))" "82800" "the spring-forward day is 23 hours"
read -r a b <<< "$(TZ=America/New_York "$WIN" bounds 2026-11-01 2026-11-02)"
assert_eq "$((b - a))" "90000" "the fall-back day is 25 hours"
read -r a b <<< "$(TZ=America/New_York "$WIN" bounds 2026-10-01 2026-10-02)"
assert_eq "$((b - a))" "86400" "an ordinary day is 24 hours"
[ "$(rc_of "$WIN" bounds not-a-date 2026-10-02)" != "0" ] && ok "an invalid date is refused" || no "an invalid date is refused"
assert_eq "$(rc_of "$WIN" bounds 2026-10-01)" "2" "missing arguments exit 2 (usage)"

echo "# window: in-window is yes / no / error, and biases to YES when it cannot tell"
{ rec "2026-10-01T05:00:00.500Z" a; } > "$TMP/in.jsonl"
{ rec "2026-09-30T23:59:59.999Z" a; } > "$TMP/before.jsonl"
{ rec "2026-10-02T00:00:00.000Z" a; } > "$TMP/after.jsonl"
{ rec "2026-10-01T00:00:00.500Z" a; } > "$TMP/startedge.jsonl"
{ rec "2026-09-30T10:00:00Z" a; rec "2026-10-01T10:00:00Z" b; rec "2026-10-03T10:00:00Z" c; } > "$TMP/mixed.jsonl"
{ printf '{"type":"summary","summary":"x"}\n'; printf 'not json at all\n'; } > "$TMP/nots.jsonl"
: > "$TMP/empty.jsonl"
{ printf 'garbage line\n'; rec "2026-09-30T10:00:00Z" a; printf '{broken\n'; } > "$TMP/malformed-out.jsonl"
assert_eq "$(rc_of "$WIN" in-window "$TMP/in.jsonl" $START $END)" "0" "a record inside the day -> yes"
assert_eq "$(rc_of "$WIN" in-window "$TMP/before.jsonl" $START $END)" "1" "only records before the day -> no"
assert_eq "$(rc_of "$WIN" in-window "$TMP/after.jsonl" $START $END)" "1" "a record at exactly the end (exclusive) -> no"
assert_eq "$(rc_of "$WIN" in-window "$TMP/startedge.jsonl" $START $END)" "0" "a fractional second just past the start -> yes"
assert_eq "$(rc_of "$WIN" in-window "$TMP/mixed.jsonl" $START $END)" "0" "before, inside and after -> yes"
# A file with no clock cannot be placed by its records, so its mtime decides, exactly as the
# bounded find used to: modified by the end of the day -> yes (triage it, bias to triage);
# modified AFTER the day -> no. Without that, dropping the find upper bound would enumerate
# a no-clock file on every later date too and triage it twice, filed under the wrong day
# (found in review).
touch -t 202610011200 "$TMP/nots.jsonl" "$TMP/empty.jsonl"
assert_eq "$(rc_of "$WIN" in-window "$TMP/nots.jsonl" $START $END)" "0" "no parseable timestamp, modified inside the day -> yes (bias to triage)"
assert_eq "$(rc_of "$WIN" in-window "$TMP/empty.jsonl" $START $END)" "0" "an empty file modified inside the day -> yes"
{ printf '{"type":"summary","summary":"x"}\n'; } > "$TMP/nots-late.jsonl"; : > "$TMP/empty-late.jsonl"
touch -t 202610031200 "$TMP/nots-late.jsonl" "$TMP/empty-late.jsonl"
assert_eq "$(rc_of "$WIN" in-window "$TMP/nots-late.jsonl" $START $END)" "1" "no parseable timestamp, modified AFTER the day -> no (the old mtime rule)"
assert_eq "$(rc_of "$WIN" in-window "$TMP/empty-late.jsonl" $START $END)" "1" "an empty file modified after the day -> no"
assert_eq "$(rc_of "$WIN" in-window "$TMP/malformed-out.jsonl" $START $END)" "1" "malformed lines are ignored; the valid out-of-window record decides -> no"
assert_eq "$(rc_of "$WIN" in-window "$TMP/missing.jsonl" $START $END)" "2" "an unreadable file is an ERROR (2), distinct from no (1)"

echo "# window: needs-slice says whether a file spills outside the day"
{ rec "2026-10-01T01:00:00Z" a; rec "2026-10-01T23:00:00Z" b; } > "$TMP/inside.jsonl"
{ rec "2026-09-30T23:00:00Z" a; rec "2026-10-01T10:00:00Z" b; } > "$TMP/starts-early.jsonl"
{ rec "2026-10-01T10:00:00Z" a; rec "2026-10-02T03:00:00Z" b; } > "$TMP/ends-late.jsonl"
{ for i in $(seq 1 100); do rec "2026-10-01T10:00:00Z" "t$i"; done; rec "2026-10-02T05:00:00Z" last; } > "$TMP/long-ends-late.jsonl"
assert_eq "$(rc_of "$WIN" needs-slice "$TMP/inside.jsonl" $START $END)" "1" "wholly inside the day -> no slice needed"
assert_eq "$(rc_of "$WIN" needs-slice "$TMP/starts-early.jsonl" $START $END)" "0" "first record before the day -> slice"
assert_eq "$(rc_of "$WIN" needs-slice "$TMP/ends-late.jsonl" $START $END)" "0" "last record after the day -> slice"
assert_eq "$(rc_of "$WIN" needs-slice "$TMP/long-ends-late.jsonl" $START $END)" "0" "a 101-line file whose LAST line is late -> slice (tail is checked)"
assert_eq "$(rc_of "$WIN" needs-slice "$TMP/nots.jsonl" $START $END)" "1" "no timestamps -> nothing to slice by -> no"
# Found in review: only the first and last 200 lines were read, so 200+ leading clockless
# lines hid an earlier-day record and a small file was read whole while its stats were sliced.
{ for i in $(seq 1 250); do printf '{"type":"summary","summary":"s%d"}\n' "$i"; done
  rec "2026-09-30T10:00:00Z" before; rec "2026-10-01T10:00:00Z" inside; } > "$TMP/lead-clockless.jsonl"
assert_eq "$(rc_of "$WIN" needs-slice "$TMP/lead-clockless.jsonl" $START $END)" "0" "250 clockless lines before an earlier-day record -> still slice"
{ rec "2026-10-01T10:00:00Z" inside; rec "2026-10-02T09:00:00Z" late
  for i in $(seq 1 300); do printf '{"type":"summary","summary":"s%d"}\n' "$i"; done; } > "$TMP/trail-clockless.jsonl"
assert_eq "$(rc_of "$WIN" needs-slice "$TMP/trail-clockless.jsonl" $START $END)" "0" "a later-day record followed by 300 clockless lines -> still slice"

echo "# window: slice keeps exactly the in-window records, byte for byte"
{ rec "2026-09-30T10:00:00Z" before1; rec "2026-10-01T02:00:00Z" keep1
  printf 'torn line {"type":\n'
  printf '{"type":"summary","summary":"no clock"}\n'
  rec "2026-10-01T03:00:00.250Z" keep2; rec "2026-10-02T00:00:00Z" after1; rec "2026-10-01T23:59:59.999Z" keep3
  rec "2026-09-29T10:00:00Z" before2; } > "$TMP/slice-in.jsonl"
{ rec "2026-10-01T02:00:00Z" keep1; rec "2026-10-01T03:00:00.250Z" keep2; rec "2026-10-01T23:59:59.999Z" keep3; } > "$TMP/slice-want.jsonl"
"$WIN" slice "$TMP/slice-in.jsonl" $START $END > "$TMP/slice-got.jsonl" 2>/dev/null; src=$?
assert_eq "$src" "0" "slice exits 0 despite a torn line and a record with no clock"
assert_eq "$(cat "$TMP/slice-got.jsonl")" "$(cat "$TMP/slice-want.jsonl")" "only the three in-window records survive, in order, unmodified"
"$WIN" slice "$TMP/before.jsonl" $START $END > "$TMP/slice-none.jsonl" 2>/dev/null; src=$?
assert_eq "$src" "0" "a slice with nothing in window still exits 0"
assert_eq "$(wc -c < "$TMP/slice-none.jsonl" | tr -d ' ')" "0" "and writes nothing"
assert_eq "$(rc_of "$WIN" slice "$TMP/missing.jsonl" $START $END)" "2" "slice of an unreadable file is an ERROR (2)"

printf '\npassed: %s   failed: %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
