#!/bin/bash
# Unit tests for bin/chunk-transcript.sh: split a slimmed transcript into chunks an
# L1 worker can read, cutting only at line boundaries.
#
# Why this exists. A day of a multi-day orchestrator slims to ~875 KB, more than one
# worker can read, and eliding the middle is how L1 came to see 2% of a session. The
# chunker keeps every line and the merge step turns the per-chunk answers back into
# the one findings JSON per session that L2 reads. The properties that matter are the
# ones a smoke test cannot see: no line is ever split, nothing is lost or reordered
# when the cap is not hit, and an over-the-cap session reports what it dropped.
#
# Contract: chunk-transcript.sh SRC OUTDIR CHUNK_BYTES MAX_CHUNKS
#   stdout "COUNT ELIDED"   OUTDIR/chunk-01.jsonl ... COUNT files
#   exit 0 ok, 1 empty source, 2 usage or unreadable

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
CH="$REPO/bin/chunk-transcript.sh"

pass=0; fail=0
ok(){ printf '  ok   - %s\n' "$1"; pass=$((pass + 1)); }
no(){ printf '  FAIL - %s\n' "$1"; fail=$((fail + 1)); }
assert_eq(){ [ "$1" = "$2" ] && ok "$3" || no "$3 (got [$1] want [$2])"; }

[ -x "$CH" ] || {
  printf '  FAIL - bin/chunk-transcript.sh missing or not executable\n'
  printf '\npassed: 0   failed: 1\n'; exit 1; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/chtest.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

# A line of exactly 100 bytes including its newline, tagged with its number.
line(){ printf '{"n":%d,"pad":"%s"}\n' "$1" "$(printf 'x%.0s' $(seq 1 $((84 - ${#1}))))"; }
mk(){ : > "$1"; local i; for i in $(seq 1 "$2"); do line "$i" >> "$1"; done; }
count_files(){ ls "$1"/chunk-*.jsonl 2>/dev/null | wc -l | tr -d ' '; }

echo "# chunk: a source under the limit is one chunk, unchanged"
mk "$TMP/small.jsonl" 3
OUT="$TMP/o1"; mkdir -p "$OUT"
read -r n e <<< "$("$CH" "$TMP/small.jsonl" "$OUT" 1000 8 2>/dev/null)"
assert_eq "$n $e" "1 0" "prints '1 0'"
assert_eq "$(cat "$OUT/chunk-01.jsonl")" "$(cat "$TMP/small.jsonl")" "and chunk-01 is the source, byte for byte"

echo "# chunk: cut only at line boundaries, nothing lost, nothing reordered"
mk "$TMP/ten.jsonl" 10
OUT="$TMP/o2"; mkdir -p "$OUT"
read -r n e <<< "$("$CH" "$TMP/ten.jsonl" "$OUT" 350 20 2>/dev/null)"
assert_eq "$n $e" "4 0" "ten 100-byte lines at a 350-byte limit -> 4 chunks (3,3,3,1), none elided"
assert_eq "$(count_files "$OUT")" "4" "four chunk files exist"
assert_eq "$(cat "$OUT"/chunk-01.jsonl "$OUT"/chunk-02.jsonl "$OUT"/chunk-03.jsonl "$OUT"/chunk-04.jsonl | shasum | cut -c1-40)" \
          "$(shasum < "$TMP/ten.jsonl" | cut -c1-40)" "the chunks concatenate back to the source exactly"
big=0; for f in "$OUT"/chunk-*.jsonl; do [ "$(wc -c < "$f" | tr -d ' ')" -gt 350 ] && big=1; done
assert_eq "$big" "0" "no chunk exceeds the limit"
bad=0; for f in "$OUT"/chunk-*.jsonl; do jq -e . "$f" >/dev/null 2>&1 || bad=1; done
assert_eq "$bad" "0" "every chunk parses as JSONL (no line was cut in half)"

echo "# chunk: a single line longer than the limit is its own chunk, not split"
{ line 1; printf '{"n":2,"pad":"%s"}\n' "$(printf 'y%.0s' $(seq 1 900))"; line 3; } > "$TMP/long.jsonl"
OUT="$TMP/o3"; mkdir -p "$OUT"
read -r n e <<< "$("$CH" "$TMP/long.jsonl" "$OUT" 350 8 2>/dev/null)"
assert_eq "$n" "3" "short, oversize, short -> 3 chunks"
assert_eq "$(jq -r .n "$OUT/chunk-02.jsonl")" "2" "the oversize line sits alone in the middle chunk"
assert_eq "$(wc -l < "$OUT/chunk-02.jsonl" | tr -d ' ')" "1" "and is intact (one whole line)"

echo "# chunk: over MAX_CHUNKS keeps the head and tail chunks and says what it dropped"
mk "$TMP/hundred.jsonl" 40      # 4,000 bytes at 400/chunk = 10 chunks
OUT="$TMP/o4"; mkdir -p "$OUT"
read -r n e <<< "$("$CH" "$TMP/hundred.jsonl" "$OUT" 400 4 2>/dev/null)"
assert_eq "$n $e" "4 6" "10 chunks capped at 4 -> prints '4 6'"
assert_eq "$(count_files "$OUT")" "4" "four chunk files remain"
assert_eq "$(jq -r .n "$OUT/chunk-01.jsonl" | head -1)" "1" "chunk 1 is the start of the session"
assert_eq "$(jq -r .n "$OUT/chunk-02.jsonl" | head -1)" "5" "chunk 2 is the second original chunk"
assert_eq "$(jq -r .n "$OUT/chunk-03.jsonl" | head -1)" "33" "chunk 3 is the ninth original chunk"
assert_eq "$(jq -r .n "$OUT/chunk-04.jsonl" | tail -1)" "40" "chunk 4 ends with the last line of the session"
OUT="$TMP/o4b"; mkdir -p "$OUT"
read -r n e <<< "$("$CH" "$TMP/hundred.jsonl" "$OUT" 400 5 2>/dev/null)"
assert_eq "$n $e" "5 5" "an odd cap of 5 keeps 3 head and 2 tail chunks"
assert_eq "$(jq -r .n "$OUT/chunk-03.jsonl" | head -1)" "9" "the third kept chunk is the third original (head side gets the extra)"
assert_eq "$(jq -r .n "$OUT/chunk-04.jsonl" | head -1)" "33" "the fourth kept chunk is the ninth original (the tail side resumes there)"

echo "# chunk: chunk files are private to the user"
OUT="$TMP/o5m"; mkdir -p "$OUT"
( umask 022; "$CH" "$TMP/ten.jsonl" "$OUT" 350 20 >/dev/null 2>&1 )
modes=$(for f in "$OUT"/chunk-*.jsonl; do stat -f %Lp "$f"; done | sort -u | tr '\n' ' ')
assert_eq "$modes" "600 " "every chunk is mode 600 even when the caller umask is 022 (they hold unredacted transcript text)"

echo "# chunk: numbers with leading zeros are decimal, not an invalid octal"
# AUTODREAM_L1_MAX_CHUNKS=08 passed the numeric check and then died in bash arithmetic ("08" is
# not valid octal), so the runner fell back to head/tail instead of using 8 chunks (found in verification).
OUT="$TMP/o4z"; mkdir -p "$OUT"
read -r n e <<< "$("$CH" "$TMP/hundred.jsonl" "$OUT" 0400 08 2>/dev/null)"
assert_eq "$n $e" "8 2" "a cap of 08 and a size of 0400 are read as 8 and 400 (10 chunks capped at 8 -> '8 2')"
OUT="$TMP/o4zz"; mkdir -p "$OUT"
"$CH" "$TMP/hundred.jsonl" "$OUT" 400 00 >/dev/null 2>&1; assert_eq "$?" "2" "a cap of 00 is still refused as zero"

echo "# chunk: stale chunk files from an earlier run are removed"
OUT="$TMP/o5"; mkdir -p "$OUT"; echo stale > "$OUT/chunk-09.jsonl"
"$CH" "$TMP/small.jsonl" "$OUT" 1000 8 >/dev/null 2>&1
[ ! -e "$OUT/chunk-09.jsonl" ] && ok "a leftover chunk-09.jsonl is gone" || no "a leftover chunk-09.jsonl is gone"

echo "# chunk: failure modes"
: > "$TMP/empty.jsonl"
"$CH" "$TMP/empty.jsonl" "$TMP/o6" 1000 8 >/dev/null 2>&1; assert_eq "$?" "1" "an empty source exits 1"
"$CH" "$TMP/nope.jsonl" "$TMP/o6" 1000 8 >/dev/null 2>&1; assert_eq "$?" "2" "an unreadable source exits 2"
"$CH" "$TMP/small.jsonl" "$TMP/o6" 0 8 >/dev/null 2>&1; assert_eq "$?" "2" "a zero chunk size exits 2 (usage)"
"$CH" "$TMP/small.jsonl" "$TMP/o6" abc 8 >/dev/null 2>&1; assert_eq "$?" "2" "a non-numeric chunk size exits 2 (usage)"
"$CH" "$TMP/small.jsonl" >/dev/null 2>&1; assert_eq "$?" "2" "missing arguments exit 2 (usage)"

printf '\npassed: %s   failed: %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
