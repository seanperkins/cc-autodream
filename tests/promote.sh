#!/bin/bash
# Tests for bin/promote.sh: the human step that writes accepted memory candidates
# to Mnemopi. Runs against a fixture findings dir with a fake shared-memory CLI on
# PATH, so nothing touches the real store. Companion to run-all.sh.
#
# Usage:  tests/promote.sh
# Exit:   0 if every assertion passes, 1 otherwise.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
PROMOTE="$REPO/bin/promote.sh"
pass=0; fail=0
ok(){ printf '  ok   - %s\n' "$1"; pass=$((pass + 1)); }
no(){ printf '  FAIL - %s\n' "$1"; fail=$((fail + 1)); }
assert_grep(){ grep -q -- "$2" "$1" 2>/dev/null && ok "$3" || no "$3 (no /$2/ in $1)"; }
assert_eq(){ [ "$1" = "$2" ] && ok "$3" || no "$3 (got [$1] want [$2])"; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
AD="$T/autodream"; mkdir -p "$AD/findings/2026-01-02"
# Fake shared-memory: `context` returns a bank; `call mnemopi_remember` records the payload and returns an id.
FAKE="$T/shared-memory"; cat > "$FAKE" <<'EOF'
#!/bin/bash
# Fake shared-memory CLI: `context` returns a bank; `call` logs the payload and returns an id.
case "$1" in
  context) echo '{"retainBank":"fake-bank"}' ;;
  call) printf '%s\n' "$3" >> "$FAKE_LOG"; n=$(wc -l < "$FAKE_LOG" | tr -d ' '); echo "{\"status\":\"stored\",\"memory_id\":\"id-$n\"}" ;;
esac
EOF
chmod +x "$FAKE"; export FAKE_LOG="$T/calls.log"; : > "$FAKE_LOG"
CAND="$AD/findings/2026-01-02/memory-candidates.json"
cat > "$CAND" <<EOF
[
  {"cwd": "$REPO", "content": "first candidate", "kind": "project_note", "evidence": ["s1"]},
  {"cwd": "$T/does-not-exist", "content": "bad cwd", "kind": "project_note", "evidence": []},
  {"cwd": "", "content": "no cwd", "kind": "preference", "evidence": []}
]
EOF
run(){ AUTODREAM_DIR="$AD" SHARED_MEMORY="$FAKE" bash "$PROMOTE" "$@" > "$T/out" 2>&1; echo $?; }

echo "# dry-run writes nothing"
rc=$(run 2026-01-02 --dry-run); assert_eq "$rc" 0 "dry-run exits 0"
assert_grep "$T/out" "dry-run: would call mnemopi_remember" "dry-run shows the payload"
assert_grep "$T/out" 'skipped: cwd does not exist' "bad cwd is skipped"
assert_grep "$T/out" 'skipped: missing cwd or content' "empty cwd is skipped"
assert_eq "$(wc -l < "$FAKE_LOG" | tr -d ' ')" 0 "no store call in dry-run"

echo "# --yes stores the valid candidate once"
rc=$(run 2026-01-02 --yes); assert_eq "$rc" 0 "--yes exits 0"
assert_eq "$(wc -l < "$FAKE_LOG" | tr -d ' ')" 1 "exactly one store call"
assert_grep "$FAKE_LOG" '"source":"cc-autodream"' "payload carries source cc-autodream"
assert_grep "$FAKE_LOG" '"extract":false' "payload disables extraction"
assert_grep "$FAKE_LOG" '"bank":"fake-bank"' "bank resolved from cwd"
assert_grep "$AD/findings/2026-01-02/memory-promoted.jsonl" 'first candidate' "promoted log written"

echo "# re-run skips what was promoted"
rc=$(run 2026-01-02 --yes); assert_grep "$T/out" 'already promoted' "already-promoted entry skipped"
assert_eq "$(wc -l < "$FAKE_LOG" | tr -d ' ')" 1 "no second store call"

echo "# malformed sidecar is refused"
echo '{"not":"an array"}' > "$CAND"; rc=$(run 2026-01-02 --yes); assert_eq "$rc" 2 "non-array exits 2"
echo "# missing sidecar is a no-op"
rm "$CAND"; rc=$(run 2026-01-02 --yes); assert_eq "$rc" 0 "no candidates exits 0"; assert_grep "$T/out" 'no memory candidates' "says there is nothing to promote"

echo; echo "passed: $pass   failed: $fail"; [ "$fail" -eq 0 ]
