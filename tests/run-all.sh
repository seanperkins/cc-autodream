#!/bin/bash
# Integration tests for cc-autodream's bin/run.sh.
#
# Drives the real run.sh end-to-end against a mock claude binary and fixture
# session files, then asserts on the output tree. No network, no model calls.
# macOS only (BSD `date`/`touch`), like the rest of the project.
#
# Usage:  tests/run-all.sh
# Exit:   0 if every assertion passes, 1 otherwise.

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
RUN="$REPO/bin/run.sh"
MOCK="$HERE/mock-claude.sh"
# Guard every run against accidental memory writes if the nightly ever regresses.
# The candidate tests replace these nonexistent paths with a logging mock.
export SHARED_MEMORY_BIN="$HERE/no-such-shared-memory"
export SHARED_MEMORY="$HERE/no-such-shared-memory"
DATE=2020-01-02          # fixed target date; sessions are touched into this day
STAMP=202001021200       # touch -t form of DATE at noon

pass=0; fail=0
ok(){ printf '  ok   - %s\n' "$1"; pass=$((pass + 1)); }
no(){ printf '  FAIL - %s\n' "$1"; fail=$((fail + 1)); }
assert_file(){     [ -f "$1" ] && ok "$2" || no "$2 (missing: $1)"; }
assert_no_file(){  [ ! -e "$1" ] && ok "$2" || no "$2 (unexpected: $1)"; }
assert_nonempty(){ [ -s "$1" ] && ok "$2" || no "$2 (empty/missing: $1)"; }
assert_grep(){     grep -q "$2" "$1" 2>/dev/null && ok "$3" || no "$3 (no /$2/ in $1)"; }
assert_nogrep(){   grep -q "$2" "$1" 2>/dev/null && no "$3 (/$2/ unexpectedly in $1)" || ok "$3"; }
assert_eq(){       [ "$1" = "$2" ] && ok "$3" || no "$3 (got [$1] want [$2])"; }

# Fresh sandbox: projects/ (session inputs) + autodream/ (prompts + state) + dreams/.
setup_env(){
  local root; root=$(mktemp -d "${TMPDIR:-/tmp}/ccad.XXXXXX")
  mkdir -p "$root/projects/proj-a" "$root/autodream" "$root/dreams" "$root/cap"
  cp "$REPO/prompts/SESSION_TRIAGE.md" "$root/autodream/SESSION_TRIAGE.md"
  cp "$REPO/prompts/PROMPT.md"         "$root/autodream/PROMPT.md"
  printf '%s' "$root"
}
mk_session(){ # $1=root $2=name
  # Two real user turns (no timestamps -> duration_minutes 0, uncomputable and
  # so exempt from the duration gate rule) so this fixture clears the noise
  # gate's default AUTODREAM_MIN_USER_TURNS=2 floor and every existing test
  # that expects real L1 triage keeps getting it.
  local f="$1/projects/proj-a/$2.jsonl"
  printf '%s\n' \
    '{"type":"user","cwd":"/tmp/proj-a","message":{"content":"start the task"}}' \
    '{"type":"user","message":{"content":"keep going"}}' \
    '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read"}]}}' \
    > "$f"
  touch -t "$STAMP" "$f"
}
mk_trivial_session(){ # $1=root $2=name — single user turn, no tool calls: below the noise gate
  local f="$1/projects/proj-a/$2.jsonl"
  printf '{"type":"user","message":{"content":"quick question"}}\n' > "$f"
  touch -t "$STAMP" "$f"
}
mk_short_duration_session(){ # $1=root $2=name — 2 user turns, 5s apart: gates on duration alone
  local f="$1/projects/proj-a/$2.jsonl"
  printf '%s\n' \
    '{"type":"user","timestamp":"2026-07-20T10:00:00Z","message":{"content":"quick check"}}' \
    '{"type":"user","timestamp":"2026-07-20T10:00:05Z","message":{"content":"thanks bye"}}' \
    > "$f"
  touch -t "$STAMP" "$f"
}
mk_subagent_session(){ # $1=root $2=name — isSidechain + >=5 tool calls: carve-out, never gated
  local f="$1/projects/proj-a/$2.jsonl"
  printf '%s\n' \
    '{"type":"user","isSidechain":true,"timestamp":"2026-07-20T10:00:00Z","message":{"content":"subagent task"}}' \
    '{"type":"assistant","isSidechain":true,"timestamp":"2026-07-20T10:00:05Z","message":{"content":[{"type":"tool_use","name":"Read"},{"type":"tool_use","name":"Write"},{"type":"tool_use","name":"Bash"},{"type":"tool_use","name":"Grep"},{"type":"tool_use","name":"Edit"}]}}' \
    > "$f"
  touch -t "$STAMP" "$f"
}
mk_timed_session(){ # $1=root $2=name $3.. = ISO8601 timestamps, one user turn each (#14 overlap fixtures)
  local root="$1" name="$2"; shift 2
  local f="$root/projects/proj-a/$name.jsonl" ts
  : > "$f"
  for ts in "$@"; do
    printf '{"type":"user","timestamp":"%s","message":{"content":"turn"}}\n' "$ts" >> "$f"
  done
  touch -t "$STAMP" "$f"
}
hash_of(){ printf '%s' "$1" | shasum -a 1 | cut -c1-12; }
run_dream(){ # $1=root ; inherits MOCK_MODE/MOCK_CAPTURE_DIR/FANOUT + changelog knobs from env
  # Changelog check defaults OFF so the suite never touches the network; the dedicated
  # changelog test exports AUTODREAM_CHANGELOG=1 with a local CHANGELOG_REMOTE.
  # Retry/network knobs forced fast+offline so the suite never sleeps or hits the net.
  # AUTODREAM_CONFIG is pinned into the sandbox so the HOST's own
  # ~/.claude/autodream/config can never leak in. run.sh started sourcing that file so
  # AUTODREAM_VAULT_DIR could reach the nightly run; without this pin a developer whose
  # config points at a real Obsidian vault would have the suite writing into it.
  # Individual tests override this by exporting AUTODREAM_CONFIG before calling.
  AUTODREAM_CHANGELOG="${AUTODREAM_CHANGELOG:-0}" CLAUDE_BIN="$MOCK" \
  AUTODREAM_CONFIG="${AUTODREAM_CONFIG:-$1/autodream/config}" \
  AUTODREAM_CONSUME_DATE="${AUTODREAM_CONSUME_DATE:-$DATE}" \
  AUTODREAM_NETCHECK=0 AUTODREAM_RETRY_WAIT=0 AUTODREAM_L1_ROUNDS="${AUTODREAM_L1_ROUNDS:-2}" \
  PROJECTS_DIR="$1/projects" AUTODREAM_DIR="$1/autodream" DREAMS_DIR="$1/dreams" \
  bash "$RUN" "$DATE" > "$1/run.out" 2>&1
  local rc=$?
  # An unattended run logs to its file rather than through a pipe, so that stdout carries
  # only a pointer now. Fold the real log in, so every assertion below still reads what a
  # nightly run actually recorded rather than what a tty run happens to echo.
  cat "$1/autodream/logs/run-$DATE.log" >> "$1/run.out" 2>/dev/null || true
  return "$rc"
}
# Same run, but piped into a reader that closes immediately, so any write run.sh makes to
# stdout lands on a dead pipe. This is the shape of the real 2026-08-02 failure.
run_dream_broken_pipe(){ # $1=root
  AUTODREAM_CHANGELOG=0 CLAUDE_BIN="$MOCK" \
  AUTODREAM_CONFIG="$1/autodream/config" \
  AUTODREAM_CONSUME_DATE="$DATE" \
  AUTODREAM_NETCHECK=0 AUTODREAM_RETRY_WAIT=0 AUTODREAM_L1_ROUNDS=2 \
  PROJECTS_DIR="$1/projects" AUTODREAM_DIR="$1/autodream" DREAMS_DIR="$1/dreams" \
  bash "$RUN" "$DATE" 2>&1 | true
  cat "$1/autodream/logs/run-$DATE.log" > "$1/run.out" 2>/dev/null || true
}
fdir(){ printf '%s' "$1/autodream/findings/$DATE"; }   # findings dir for a root

# ---------------------------------------------------------------------------

# ---- Operator notes: notes.md + vault inbox merged into operator-notes.md ----------
# The seam under test is that PROMPT.md reads exactly ONE file. Every assertion here is
# about that file's contents and about what leaves the inbox, because the two ways this
# feature fails silently are (a) a surface not reaching the model and (b) a note being
# archived before it was read.

mk_vault_note(){ # $1=root $2=name $3=body [$4=expires]
  local d="$1/vault/inbox"; mkdir -p "$d"
  {
    if [ -n "${4:-}" ]; then printf -- '---\nexpires: %s\n---\n' "$4"; fi
    printf '%s\n' "$3"
  } > "$d/$2.md"
}
vault_run(){ # $1=root — a run with the vault surface enabled
  AUTODREAM_VAULT_DIR="$1/vault" run_dream "$1"
}

test_notes_no_surfaces(){
  echo "# operator notes: no notes.md and no vault -> the file still exists, saying so"
  local root; root=$(setup_env); mk_session "$root" s1
  run_dream "$root"
  local f; f="$(fdir "$root")/operator-notes.md"
  assert_file "$f" "operator-notes.md is written even with nothing to report"
  assert_grep "$f" "active: 0" "header reports zero active notes"
  assert_grep "$f" "No active operator notes" "body says there are no notes"
  rm -rf "$root"
}

test_notes_from_notes_file(){
  echo "# operator notes: notes.md lines reach the merged file verbatim"
  local root; root=$(setup_env); mk_session "$root" s1
  printf -- '- [2020-01-01] check whether /graphify is used\n' > "$root/autodream/notes.md"
  run_dream "$root"
  local f; f="$(fdir "$root")/operator-notes.md"
  assert_grep "$f" "check whether /graphify is used" "the note text is present"
  assert_grep "$f" "active: 1" "the line note is counted active"
  rm -rf "$root"
}

test_notes_from_vault_inbox(){
  echo "# operator notes: a vault inbox file becomes a note block"
  local root; root=$(setup_env); mk_session "$root" s1
  mk_vault_note "$root" idea-from-phone "look at how often the retry budget fires"
  vault_run "$root"
  local f; f="$(fdir "$root")/operator-notes.md"
  assert_grep "$f" "note: idea-from-phone" "the inbox file is titled by its filename"
  assert_grep "$f" "how often the retry budget fires" "the inbox note body is present"
  assert_grep "$f" "active: 1" "the inbox note is counted active"
  assert_nogrep "$f" "^expires:" "frontmatter is stripped from the body"
  rm -rf "$root"
}

test_notes_vault_expired_dropped(){
  echo "# operator notes: an expired vault note is dropped from the merged file but still archived"
  local root; root=$(setup_env); mk_session "$root" s1
  mk_vault_note "$root" stale "this stopped mattering" 2020-01-01
  vault_run "$root"
  local f; f="$(fdir "$root")/operator-notes.md"
  assert_nogrep "$f" "this stopped mattering" "expired note body is not shown to the model"
  assert_grep "$f" "expired-and-dropped: 1" "the expired note is counted in the header"
  assert_no_file "$root/vault/inbox/stale.md" "an expired note still leaves the inbox"
  rm -rf "$root"
}

test_notes_vault_archived_after_report(){
  echo "# operator notes: a consumed vault note moves to processed/<date>/"
  local root; root=$(setup_env); mk_session "$root" s1
  mk_vault_note "$root" done-with-this "some note"
  vault_run "$root"
  assert_no_file "$root/vault/inbox/done-with-this.md" "the note left the inbox"
  assert_file "$root/vault/processed/$DATE/done-with-this.md" "the note landed in processed/<date>/"
  rm -rf "$root"
}

test_notes_vault_not_archived_without_report(){
  echo "# operator notes: a failed L2 (no report) leaves the note in the inbox"
  local root; root=$(setup_env); mk_session "$root" s1
  mk_vault_note "$root" keep-me "must survive a failed run"
  # l2_fail makes the aggregator write nothing; the archive step is gated on a
  # non-empty report precisely so an unread note is never thrown away.
  export MOCK_MODE=l2_fail AUTODREAM_L2_ATTEMPTS=1
  vault_run "$root"
  unset MOCK_MODE AUTODREAM_L2_ATTEMPTS
  assert_file "$root/vault/inbox/keep-me.md" "the note stayed in the inbox after a failed run"
  assert_no_file "$root/vault/processed/$DATE/keep-me.md" "the note was not archived"
  rm -rf "$root"
}

test_notes_vault_report_published(){
  echo "# operator notes: the report is copied into the vault for phone reading"
  local root; root=$(setup_env); mk_session "$root" s1
  vault_run "$root"
  assert_nonempty "$root/vault/reports/$DATE.md" "the report was published into the vault"
  rm -rf "$root"
}

test_notes_vault_unreadable_note_stays(){
  echo "# operator notes: an empty (unsynced) note is reported, not silently skipped"
  local root; root=$(setup_env); mk_session "$root" s1
  mkdir -p "$root/vault/inbox"; : > "$root/vault/inbox/not-synced.md"
  AUTODREAM_ICLOUD_WAIT=0 vault_run "$root"
  local f; f="$(fdir "$root")/operator-notes.md"
  assert_grep "$f" "unreadable: 1" "the unreadable note is counted"
  assert_grep "$f" "not-synced.md — UNREADABLE" "the unreadable note is named for the model"
  assert_file "$root/vault/inbox/not-synced.md" "an unread note is left in the inbox to retry"
  rm -rf "$root"
}

# ---- Config file: run.sh sources it, but the environment still wins ----------------
# run.sh ignored ~/.claude/autodream/config until AUTODREAM_VAULT_DIR needed to reach the
# nightly run. The env-wins half is the part worth pinning: the config uses plain
# KEY=value, so a naive `.` would let the file override a caller who deliberately
# exported something.

test_config_file_sourced(){
  echo "# config: AUTODREAM_VAULT_DIR set only in the config file reaches the run"
  local root; root=$(setup_env); mk_session "$root" s1
  mk_vault_note "$root" from-config "config-sourced vault"
  printf 'AUTODREAM_VAULT_DIR=%s/vault\n' "$root" > "$root/autodream/config"
  run_dream "$root"
  assert_grep "$(fdir "$root")/operator-notes.md" "config-sourced vault" "the config-only vault path was used"
  rm -rf "$root"
}

test_config_env_wins_over_config(){
  echo "# config: an exported AUTODREAM_VAULT_DIR beats the config file's value"
  local root; root=$(setup_env); mk_session "$root" s1
  mk_vault_note "$root" real "the env-chosen vault"
  mkdir -p "$root/decoy/inbox"
  printf 'the config-chosen vault\n' > "$root/decoy/inbox/decoy.md"
  printf 'AUTODREAM_VAULT_DIR=%s/decoy\n' "$root" > "$root/autodream/config"
  vault_run "$root"
  local f; f="$(fdir "$root")/operator-notes.md"
  assert_grep   "$f" "the env-chosen vault"    "the environment's vault was read"
  assert_nogrep "$f" "the config-chosen vault" "the config's vault was overridden"
  rm -rf "$root"
}

# ---- Regressions from the PR #37 review -------------------------------------------
# Every one of these had a reproducer in the review and no test. They are grouped here
# rather than merged into the tests above because each pins a specific way the feature
# lost the user's input silently.

test_notes_header_only_file_does_not_abort(){
  echo "# regression: a notes.md with no '- [' lines must not abort collect"
  local root; root=$(setup_env); mk_session "$root" s1
  # Exactly what autodream-note.sh leaves once the user deletes the notes a report told
  # them were addressed. `grep -c` prints 0 AND exits 1, so a `|| echo 0` fallback made
  # the count "0\n0" and the arithmetic killed the whole collect under set -e.
  printf '# Operator notes for autodream\n\nFree-text notes.\n\n' > "$root/autodream/notes.md"
  mk_vault_note "$root" survives "this note must still reach the model"
  vault_run "$root"
  local f; f="$(fdir "$root")/operator-notes.md"
  assert_file "$f" "operator-notes.md was still written"
  assert_grep "$f" "active: 1" "the vault note was still counted"
  assert_grep "$f" "this note must still reach the model" "the vault note still reached the model"
  rm -rf "$root"
}

test_notes_icloud_placeholder_is_counted(){
  echo "# regression: an iCloud placeholder is a missed note, not a clean zero"
  local root; root=$(setup_env); mk_session "$root" s1
  # An evicted note is NOT a zero-byte .md — the real file is gone and only the
  # dot-prefixed placeholder remains, so the '*.md' walk matched nothing at all.
  mkdir -p "$root/vault/inbox"; : > "$root/vault/inbox/.from-phone.md.icloud"
  AUTODREAM_ICLOUD_WAIT=0 vault_run "$root"
  local f; f="$(fdir "$root")/operator-notes.md"
  assert_grep "$f" "unreadable: 1" "the evicted note is counted, not reported as zero"
  assert_grep "$f" "from-phone.md — UNREADABLE" "it is named so the user knows what was missed"
  assert_file "$root/vault/inbox/.from-phone.md.icloud" "the placeholder stays for the next run"
  rm -rf "$root"
}

test_notes_placeholder_and_real_file_counted_once(){
  echo "# regression: a materialised note with a leftover placeholder is not double-counted"
  local root; root=$(setup_env); mk_session "$root" s1
  mk_vault_note "$root" both "the real content"
  : > "$root/vault/inbox/.both.md.icloud"
  AUTODREAM_ICLOUD_WAIT=0 vault_run "$root"
  local f; f="$(fdir "$root")/operator-notes.md"
  assert_grep "$f" "active: 1" "counted as one active note"
  assert_grep "$f" "unreadable: 0" "not also counted as unreadable"
  rm -rf "$root"
}

test_notes_expiry_uses_report_date(){
  echo "# regression: expiry is judged against the reported date, not today"
  local root; root=$(setup_env); mk_session "$root" s1
  # Expires long after the date being reported on ($DATE) but long before today, so a
  # wall-clock comparison drops and archives a note that was active for this window.
  mk_vault_note "$root" still-active "active during the reported window" 2020-06-01
  vault_run "$root"
  local f; f="$(fdir "$root")/operator-notes.md"
  assert_grep "$f" "active during the reported window" "the note is still shown to the model"
  assert_grep "$f" "expired-and-dropped: 0" "it is not counted as expired"
  rm -rf "$root"
}

test_force_rebuild_failed_l2_does_not_consume(){
  echo "# regression: a stale report must not satisfy the consume gate under --force"
  local root; root=$(setup_env); mk_session "$root" s1
  vault_run "$root"                                    # first run succeeds, leaves a report
  mk_vault_note "$root" written-later "must survive the failed rebuild"
  # Rebuild with an L2 that writes nothing. The old report is still on disk, and it used
  # to satisfy both the retry loop's break and the consume gate, so this note was
  # archived having been read by nothing.
  export MOCK_MODE=l2_fail AUTODREAM_FORCE=1 AUTODREAM_L2_ATTEMPTS=1
  vault_run "$root"
  unset MOCK_MODE AUTODREAM_FORCE AUTODREAM_L2_ATTEMPTS
  assert_file "$root/vault/inbox/written-later.md" "the note stayed in the inbox"
  assert_no_file "$root/vault/processed/$DATE/written-later.md" "the note was not archived"
  ls "$root/dreams/$DATE.md.stale-"* >/dev/null 2>&1 \
    && ok "the previous report was preserved, not destroyed" \
    || no "the previous report was not preserved"
  rm -rf "$root"
}

test_unmovable_stale_report_disarms_consuming(){
  echo "# regression: if the stale report cannot be moved aside, nothing may be consumed"
  local root; root=$(setup_env); mk_session "$root" s1
  vault_run "$root"                                    # first run leaves a report
  mk_vault_note "$root" must-survive "the mv failed, so this must not be archived"
  # Make the move fail the way it would in practice: the destination directory is not
  # writable, so the old report stays at $REPORT_PATH. Without the disarm this is the
  # original hole reopened — the retry loop and the consume gate both see the old file.
  chmod 555 "$root/dreams"
  export MOCK_MODE=l2_fail AUTODREAM_FORCE=1 AUTODREAM_L2_ATTEMPTS=1
  vault_run "$root"
  unset MOCK_MODE AUTODREAM_FORCE AUTODREAM_L2_ATTEMPTS
  chmod 755 "$root/dreams"
  assert_file "$root/vault/inbox/must-survive.md" "the note stayed in the inbox"
  assert_no_file "$root/vault/processed/$DATE/must-survive.md" "the note was not archived"
  assert_grep "$root/run.out" "will NOT archive notes" "the run says why consuming was disarmed"
  rm -rf "$root"
}

test_partial_report_does_not_consume(){
  echo "# regression: a truncated report must not satisfy the retry break or the consume gate"
  local root; root=$(setup_env); mk_session "$root" s1
  mk_vault_note "$root" survives-truncation "a half-written report must not consume this"
  # l2_partial writes a non-empty report with no open-questions marker — what a mid-write
  # kill leaves. `-s` alone cannot tell it from a good report.
  export MOCK_MODE=l2_partial AUTODREAM_L2_ATTEMPTS=2
  vault_run "$root"
  unset MOCK_MODE AUTODREAM_L2_ATTEMPTS
  assert_file "$root/vault/inbox/survives-truncation.md" "the note stayed in the inbox"
  assert_no_file "$root/vault/processed/$DATE/survives-truncation.md" "the note was not archived"
  assert_grep "$root/run.out" "no open-questions marker" "the run names the reason"
  # It must also have RETRIED rather than accepting the partial file on attempt 1.
  assert_grep "$root/run.out" "L2 aggregation attempt 2" "a truncated report triggers a retry"
  rm -rf "$root"
}

test_partial_report_does_not_block_retry(){
  echo "# regression: a truncated report must not satisfy the idempotency guard forever"
  local root; root=$(setup_env); mk_session "$root" s1
  # Every attempt dies mid-write. Without the move-aside, the next launchd catch-up
  # trigger sees a non-empty file, says "nothing to do", and the half-written report
  # becomes the permanent output for the date.
  export MOCK_MODE=l2_partial AUTODREAM_L2_ATTEMPTS=1
  vault_run "$root"
  unset MOCK_MODE AUTODREAM_L2_ATTEMPTS
  assert_no_file "$root/dreams/$DATE.md" "the truncated report was moved off the report path"
  ls "$root/dreams/$DATE.md.partial-"* >/dev/null 2>&1 \
    && ok "it was preserved as .partial-<epoch>, not deleted" \
    || no "the partial report was lost"
  # The next trigger must actually re-run rather than no-op on the leftover.
  vault_run "$root"
  assert_nonempty "$root/dreams/$DATE.md" "a later trigger produced a real report"
  assert_grep "$root/dreams/$DATE.md" "autodream:open-questions=" "and it is a complete one"
  rm -rf "$root"
}

test_unassembled_dates_are_surfaced(){
  echo "# a date triaged but never assembled must be named, not left for someone to find"
  local root; root=$(setup_env); mk_session "$root" s1
  local prior="$root/autodream/findings/2020-01-01"
  mkdir -p "$prior"
  printf '{"findings":[]}\n' > "$prior/abc123def456.json"
  printf '{"transcript_bytes":10}\n' > "$prior/abc123def456.stats.json"
  # A second dir holding only a sidecar: never triaged, so nothing to assemble.
  mkdir -p "$root/autodream/findings/2020-01-03"
  printf '{"transcript_bytes":10}\n' > "$root/autodream/findings/2020-01-03/dead.stats.json"
  run_dream "$root"
  assert_grep "$root/run.out" "findings but no complete report: 2020-01-01" "the log names the abandoned date"
  assert_grep "$(fdir "$root")/run-stats.txt" "unassembled_dates: 2020-01-01" "and the stat carries it into the next report"
  assert_nogrep "$(fdir "$root")/run-stats.txt" "2020-01-03" "a sidecar-only dir was never triaged and is not a failure"
  rm -rf "$root"
}

test_unassembled_ignores_a_finished_date(){
  echo "# a date with a complete report is not an abandoned one"
  local root; root=$(setup_env); mk_session "$root" s1
  local prior="$root/autodream/findings/2020-01-01"
  mkdir -p "$prior" "$root/dreams"
  printf '{"findings":[]}\n' > "$prior/abc123def456.json"
  printf '# report\n\nautodream:open-questions=0\n' > "$root/dreams/2020-01-01.md"
  run_dream "$root"
  assert_grep "$(fdir "$root")/run-stats.txt" "unassembled_dates: *$" "the finished date is not listed"
  # A truncated report is not a finished one, and must come back onto the list.
  printf '# report with no marker\n' > "$root/dreams/2020-01-01.md"
  rm -f "$root/dreams/$DATE.md"
  run_dream "$root"
  assert_grep "$(fdir "$root")/run-stats.txt" "unassembled_dates: 2020-01-01" "but a marker-less one is"
  rm -rf "$root"
}

test_dead_stdout_does_not_kill_the_run(){
  echo "# regression: losing the log reader must cost the run its output, not its life"
  local root; root=$(setup_env); mk_session "$root" s1
  # Three runs died this way on 2026-08-02: tee was killed, the next log line SIGPIPEd the
  # run, and everything after L2 — the retry loop, the move-aside, the consume gate — was
  # never reached. No error line said so, because saying so was the thing that died.
  run_dream_broken_pipe "$root"
  assert_grep "$root/dreams/$DATE.md" "autodream:open-questions=" "the run finished and wrote a complete report"
  assert_grep "$root/run.out" "autodream end" "and its log reached the end on disk"
  rm -rf "$root"
}

test_complete_report_retires_partials(){
  echo "# a complete report supersedes the partials left by the nights that failed"
  local root; root=$(setup_env); mk_session "$root" s1
  # Two failed nights, so the second run has to retire a partial it did not itself create.
  export MOCK_MODE=l2_partial AUTODREAM_L2_ATTEMPTS=1
  vault_run "$root"
  vault_run "$root"
  unset MOCK_MODE AUTODREAM_L2_ATTEMPTS
  ls "$root/dreams/$DATE.md.partial-"* >/dev/null 2>&1 \
    && ok "the failed nights left partials behind" \
    || no "setup failed: no partial report to retire"
  vault_run "$root"                                   # the night that finally works
  assert_grep "$root/dreams/$DATE.md" "autodream:open-questions=" "a complete report landed"
  ls "$root/dreams/$DATE.md.partial-"* >/dev/null 2>&1 \
    && no "partials survived the complete report that supersedes them" \
    || ok "every partial for the date was discarded"
  rm -rf "$root"
}

test_no_sessions_stub_carries_marker(){
  echo "# the no-sessions stub is a complete report and must carry the marker"
  local root; root=$(setup_env)     # no sessions at all
  run_dream "$root"
  assert_grep "$root/dreams/$DATE.md" "autodream:open-questions=" "the stub carries the marker"
  rm -rf "$root"
}

test_partial_report_keeps_previous(){
  echo "# regression: a truncated rebuild must not discard the previous good report"
  local root; root=$(setup_env); mk_session "$root" s1
  vault_run "$root"                                   # a good report lands
  export MOCK_MODE=l2_partial AUTODREAM_FORCE=1 AUTODREAM_L2_ATTEMPTS=1
  vault_run "$root"
  unset MOCK_MODE AUTODREAM_FORCE AUTODREAM_L2_ATTEMPTS
  ls "$root/dreams/$DATE.md.stale-"* >/dev/null 2>&1 \
    && ok "the previous good report was kept" \
    || no "the previous good report was discarded for a truncated one"
  rm -rf "$root"
}

test_old_date_reprocess_does_not_consume(){
  echo "# regression: reprocessing an old date must not consume today's pending input"
  local root; root=$(setup_env); mk_session "$root" s1
  mk_vault_note "$root" todays-note "written this morning"
  # TARGET_DATE is not the date a normal nightly run would process.
  AUTODREAM_CONSUME_DATE=2099-01-01 vault_run "$root"
  local f; f="$(fdir "$root")/operator-notes.md"
  assert_grep "$f" "written this morning" "the note is still collected as context for L2"
  assert_file "$root/vault/inbox/todays-note.md" "but it is NOT archived out of the inbox"
  assert_nonempty "$root/vault/reports/$DATE.md" "publishing still happens (it consumes nothing)"
  rm -rf "$root"
}

test_config_unbound_var_does_not_kill_run(){
  echo "# regression: a typo'd variable in the config must warn, not kill the run"
  local root; root=$(setup_env); mk_session "$root" s1
  # AUTODREAM_HOME does not exist; under `set -u` this used to abort bash outright,
  # before the log file or log() existed, so the night produced nothing and said nothing.
  printf 'X_CREDS_FILE=$AUTODREAM_HOME/x-credentials\nAUTODREAM_VAULT_DIR=%s/vault\n' "$root" > "$root/autodream/config"
  mk_vault_note "$root" survives-typo "the run must still happen"
  run_dream "$root"
  assert_nonempty "$root/dreams/$DATE.md" "the run still produced a report"
  assert_grep "$root/run.out" "unbound variable" "the bad config key is named in a warning"
  assert_grep "$(fdir "$root")/operator-notes.md" "the run must still happen" \
    "keys after the bad line still took effect"
  rm -rf "$root"
}

test_session_stats(){
  echo "# deterministic session stats pre-pass acceptance fixtures"
  local root; root=$(mktemp -d "${TMPDIR:-/tmp}/ccad.XXXXXX")
  local fixture out

  fixture="$root/carriers.jsonl"; out="$root/carriers.stats.json"
  printf '%s\n' \
    '{"type":"user","message":{"role":"user","content":"human question"}}' \
    '{"type":"assistant","message":{"model":"claude-haiku","content":[{"type":"tool_use","name":"Read"}]}}' \
    '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"a","content":"result"}]}}' \
    'not json' \
    '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"b","content":"result"}]}}' > "$fixture"
  "$REPO/bin/session-stats.sh" "$fixture" "$out"
  assert_eq "$(jq -r '.user_turn_timestamps | length' "$out")" "0" "no timestamped user turns in this fixture -> empty user_turn_timestamps"
  assert_eq "$(jq -r .user_message_count "$out")" "1" "tool_result carriers are excluded from user message count"
  assert_eq "$(jq -r .turn_count "$out")" "4" "turn count includes tool_result carriers"

  fixture="$root/skills.jsonl"; out="$root/skills.stats.json"
  printf '%s\n' \
    '{"type":"assistant","message":{"content":[{"type":"text","text":"Use superpowers:fake"},{"type":"tool_use","name":"Skill","input":{"skill":"superpowers:brainstorming"}},{"type":"tool_use","name":"Skill","input":{"skill":"superpowers:brainstorming"}},{"type":"tool_use","name":"Read","input":{"skill":"not-a-skill"}},{"type":"tool_use","name":"Skill","input":{}}]}}' \
    '{"type":"user","message":{"content":[{"type":"tool_result","content":"Launching skill: not-an-invocation"}]}}' > "$fixture"
  "$REPO/bin/session-stats.sh" "$fixture" "$out"
  assert_eq "$(jq -c .skills_invoked "$out")" '["superpowers:brainstorming"]' \
    "skill names come from calls, not prose/results, and repeated calls count once"
  printf '%s\n' \
    '{"type":"user","message":{"content":"<command-message>cc-codemaps:update-codemaps</command-message>\n<command-name>/cc-codemaps:update-codemaps</command-name>"}}' \
    '{"type":"user","message":{"content":[{"type":"text","text":"<command-message>superpowers:brainstorming</command-message>\n<command-name>/superpowers:brainstorming</command-name>"}]}}' \
    '{"type":"assistant","message":{"content":[{"type":"text","text":"<command-name>/not-a-user-command</command-name>"}]}}' \
    '{"type":"user","message":{"content":"Example: <command-name>/not-invoked</command-name>"}}' \
    '{"type":"user","message":{"content":"<command-name>/clear</command-name>\n<command-message>clear</command-message>\n<command-args></command-args>"}}' \
    '{"type":"attachment","attachment":{"type":"skill_listing","content":"- debate:review-panel: available, not invoked"}}' >> "$fixture"
  "$REPO/bin/session-stats.sh" "$fixture" "$out"
  assert_eq "$(jq -c .skills_invoked "$out")" '["cc-codemaps:update-codemaps","superpowers:brainstorming"]' \
    "slash invocations survive without Skill calls; overlap deduplicates and listings/prose do not count"

  fixture="$root/timestamps.jsonl"; out="$root/timestamps.stats.json"
  printf '%s\n' \
    '{"type":"user","timestamp":"2026-07-20T10:00:00.500Z","message":{"content":"start"}}' \
    '{"type":"system","message":{"content":"no timestamp needed"}}' \
    '{"type":"assistant","message":{"model":"claude-opus","content":"middle"}}' \
    '{"type":"progress","timestamp":"2026-07-20T10:01:00.250Z"}' \
    '{"type":"assistant","timestamp":"2026-07-20T10:02:30.750Z","message":{"model":"<synthetic>","content":"end"}}' > "$fixture"
  "$REPO/bin/session-stats.sh" "$fixture" "$out"
  assert_eq "$(jq -r .duration_minutes "$out")" "2.5" "duration uses available fractional timestamps"
  assert_eq "$(jq -r .models_used[0] "$out")" "claude-opus" "synthetic model is dropped"
  assert_eq "$(jq -r '.user_turn_timestamps | join(",")' "$out")" "1784541600" "user_turn_timestamps holds only the (fractional-second-truncated) real user turn's epoch"

  fixture="$root/markers.jsonl"; out="$root/markers.stats.json"
  printf '%s\n' \
    '{"type":"user","message":{"content":"user pasted RETRY-BUDGET: not a marker"}}' \
    '{"type":"user","message":{"content":[{"type":"tool_result","content":"payload RETRY-BUDGET: not a marker"}]}}' \
    '{"type":"assistant","message":{"content":[{"type":"text","text":"RETRY-BUDGET: real"}]}}' \
    '{"type":"assistant","message":{"content":[{"type":"text","text":"DELEGATED: scout — find X\nthe report said DELEGATED: quoted mid-line\n```\nDELEGATED: fenced example\nDIRECT-OK: fenced example\n```\nDIRECT-OK: tiny-edit — one-line fix"}]}}' \
    '{"type":"assistant","isSidechain":true,"message":{"content":[{"type":"text","text":"DELEGATED: harvester — sidechain worker line"}]}}' > "$fixture"
  "$REPO/bin/session-stats.sh" "$fixture" "$out"
  assert_eq "$(jq -r '.compliance_markers["RETRY-BUDGET"]' "$out")" "1" "only assistant text counts RETRY-BUDGET"
  assert_eq "$(jq -r '.compliance_markers["DELEGATED"]' "$out")" "1" "DELEGATED counts line-start only (mid-line, fenced, sidechain excluded)"
  assert_eq "$(jq -r '.compliance_markers["DIRECT-OK"]' "$out")" "1" "DIRECT-OK counts line-start only (fenced excluded)"
  assert_eq "$(jq -r '.compliance_markers | keys | sort | join(",")' "$out")" \
    "DELEGATED,DIRECT-OK,FETCH-PIVOT,RETRY-BUDGET" "compliance_markers carries all four keys"

  fixture="$root/text-image.jsonl"; out="$root/text-image.stats.json"
  printf '%s\n' \
    '{"type":"user","message":{"content":[{"type":"text","text":"caption"},{"type":"image","source":{"type":"base64","data":"abc"}}]}}' > "$fixture"
  "$REPO/bin/session-stats.sh" "$fixture" "$out"
  assert_eq "$(jq -r .user_message_count "$out")" "1" "text plus image human turn counts"

  fixture="$root/sidechain.jsonl"; out="$root/sidechain.stats.json"
  printf '%s\n' \
    '{"type":"user","isSidechain":true,"message":{"content":"subagent task"}}' \
    '{"type":"assistant","isSidechain":true,"message":{"model":"claude-haiku","content":[{"type":"tool_use","name":"Write"},{"type":"tool_use","name":"Bash"},{"type":"tool_use","name":"Read"}]}}' \
    '{"type":"user","isSidechain":true,"message":{"content":[{"type":"tool_result","content":"one"}]}}' \
    '{"type":"user","isSidechain":true,"message":{"content":[{"type":"tool_result","content":"two"}]}}' \
    '{"type":"user","isSidechain":true,"message":{"content":[{"type":"tool_result","content":"three"}]}}' > "$fixture"
  "$REPO/bin/session-stats.sh" "$fixture" "$out"
  assert_eq "$(jq -r .user_message_count "$out")" "1" "sidechain has one human message"
  assert_eq "$(jq -r .turn_count "$out")" "5" "sidechain turn count includes carriers"
  assert_eq "$(jq -r .tool_call_count "$out")" "3" "sidechain tool calls are counted mechanically"
  assert_eq "$(jq -r '.tools_used | join(",")' "$out")" "Bash,Read,Write" "sidechain tools are sorted and unique"
  assert_eq "$(jq -r .isSidechain "$out")" "true" "sidechain marker is copied"
  rm -rf "$root"
}

test_happy(){
  echo "# happy path"
  local root; root=$(setup_env); mk_session "$root" sess1
  run_dream "$root"
  local h; h=$(hash_of "$root/projects/proj-a/sess1.jsonl")
  assert_file    "$(fdir "$root")/$h.json"     "L1 wrote findings JSON"
  assert_file    "$(fdir "$root")/$h.stats.json" "mechanical stats sidecar written"
  assert_eq      "$(jq -r .tool_call_count "$(fdir "$root")/$h.stats.json")" "1" "sidecar has plausible tool_call_count"
  assert_no_file "$(fdir "$root")/$h.json.err" "no .err on success"
  assert_file    "$root/dreams/$DATE.md"       "L2 wrote the report"
  rm -rf "$root"
}

test_unreadable(){
  echo "# unreadable session (validated before dispatch)"
  local root; root=$(setup_env); mk_session "$root" sess1
  chmod 000 "$root/projects/proj-a/sess1.jsonl"
  run_dream "$root"
  local h; h=$(hash_of "$root/projects/proj-a/sess1.jsonl")
  assert_file    "$(fdir "$root")/$h.json"     "unreadable -> structured error JSON written"
  assert_grep    "$(fdir "$root")/$h.json"     'not readable at dispatch' "error JSON states the reason"
  assert_no_file "$(fdir "$root")/$h.json.err" "no .err (structured record instead of a loop)"
  chmod 644 "$root/projects/proj-a/sess1.jsonl"; rm -rf "$root"
}

test_incomplete(){
  echo "# incomplete worker run (no JSON written)"
  local root; root=$(setup_env); mk_session "$root" sess1
  export MOCK_MODE=l1_incomplete; run_dream "$root"; unset MOCK_MODE
  local h; h=$(hash_of "$root/projects/proj-a/sess1.jsonl")
  # After the 2026-06-11 self-audit fix: on the FINAL retry round, a worker
  # that produced no output gets a metadata-only stub so the session is
  # visible to L1_ERRORED and the L2 aggregator instead of becoming a silent
  # .err. Earlier rounds still left the slot absent so retries could fire.
  assert_file     "$(fdir "$root")/$h.json"     "final-round stub written (no longer a silent failure)"
  assert_grep     "$(fdir "$root")/$h.json"     'worker exited without findings JSON' "stub carries the failure reason"
  # Whitespace-tolerant: the project-field normalization pass rewrites this stub via
  # json.dump (it has a real session_path + no project), reformatting "findings":[] →
  # "findings": []. The assertion is about the empty array, not its exact spacing.
  assert_grep     "$(fdir "$root")/$h.json"     '"findings": *\[\]'                   "stub has an empty findings array (counted by L1_ERRORED via the error key)"
  assert_nonempty "$(fdir "$root")/$h.json.err" ".err is still non-empty (per-round diagnostics)"
  assert_grep     "$(fdir "$root")/$h.json.err" 'incomplete run' ".err carries a diagnostic"
  assert_file     "$root/dreams/$DATE.md"       "L2 still produced the report"
  rm -rf "$root"
}

test_self_audit_stats(){
  echo "# run-stats.txt self-audit telemetry is written"
  local root; root=$(setup_env); mk_session "$root" real1
  local sf="$root/projects/proj-a/selfworker.jsonl"
  printf '{"type":"user","message":{"role":"user","content":"SESSION_PATH=/x/y.jsonl"}}\n{"type":"assistant"}\n' > "$sf"
  touch -t "$STAMP" "$sf"
  run_dream "$root"
  local stats="$(fdir "$root")/run-stats.txt"
  assert_file  "$stats" "run-stats.txt written"
  assert_grep  "$stats" 'self_sessions_excluded: 1' "stats record the excluded self-session"
  assert_grep  "$stats" 'sessions_triaged: 1'        "stats record the triaged count"
  assert_grep  "$stats" 'l1_findings_with_error: 0'  "stats record the in-band error count"
  # 2026-06-11 self-audit fix: vs.-raw denominator + cache-disambiguating fields.
  assert_grep  "$stats" 'sessions_dropped_after_failures: 0'   "no dropped sessions on a clean happy-path run"
  assert_grep  "$stats" 'l1_sessions_already_done_at_start: 0' "no precached findings on a fresh run"
  assert_grep  "$stats" 'l1_sessions_freshly_processed: 1'     "the one session was freshly processed this run"
  # #38: the key is always emitted, even with no bookmark credentials anywhere near the
  # sandbox, so a consumer never has to tell "absent" from "the walk did not run".
  assert_grep  "$stats" 'x_queryid_source: not_attempted'      "the queryId source is recorded even when the walk never ran"
  rm -rf "$root"
}

test_self_audit_stats_failure_denominator(){
  echo "# self-audit stats: dropped-after-failures is nonzero when a worker dies"
  local root; root=$(setup_env); mk_session "$root" sess1
  export MOCK_MODE=l1_incomplete; run_dream "$root"; unset MOCK_MODE
  local stats="$(fdir "$root")/run-stats.txt"
  assert_file  "$stats" "run-stats.txt written"
  # After the fix, even a stubbed final-round failure is counted: the stub
  # carries an "error" key so it lands in l1_findings_with_error, AND the
  # vs.-raw denominator stays accurate. Old behavior reported zero across
  # the board even though the session never produced real findings.
  assert_grep  "$stats" 'l1_findings_with_error: 1' "stats now surface the failed session via the error key"
  rm -rf "$root"
}

test_self_audit_stats_precached_disambiguation(){
  echo "# self-audit stats: precached findings counted so fast elapsed isn't 'impossible'"
  local root; root=$(setup_env); mk_session "$root" sess1
  local h; h=$(hash_of "$root/projects/proj-a/sess1.jsonl")
  # Pre-seed a valid findings JSON so dispatcher's idempotency skips the worker.
  mkdir -p "$(fdir "$root")"; printf '{"session_path":"CACHED","findings":[]}' > "$(fdir "$root")/$h.json"
  run_dream "$root"
  local stats="$(fdir "$root")/run-stats.txt"
  assert_grep  "$stats" 'l1_sessions_already_done_at_start: 1' "precached session counted as already done"
  assert_grep  "$stats" 'l1_sessions_freshly_processed: 0'     "no fresh work this run"
  rm -rf "$root"
}

test_idempotent(){
  echo "# idempotent (pre-existing VALID findings JSON is not re-run)"
  local root; root=$(setup_env); mk_session "$root" sess1
  local h; h=$(hash_of "$root/projects/proj-a/sess1.jsonl")
  # A valid findings record (has a top-level findings key) marks a completed
  # triage; the run must leave it untouched. Sentinel lives in session_path.
  mkdir -p "$(fdir "$root")"
  printf '{"session_path":"SENTINEL","findings":[]}' > "$(fdir "$root")/$h.json"
  run_dream "$root"
  assert_eq "$(jq -r .session_path "$(fdir "$root")/$h.json")" "SENTINEL" "valid findings JSON left untouched"
  rm -rf "$root"
}

test_revalidates_garbage(){
  echo "# a non-empty but malformed findings JSON is re-dispatched, not counted as done"
  local root; root=$(setup_env); mk_session "$root" sess1
  local h; h=$(hash_of "$root/projects/proj-a/sess1.jsonl")
  # Old contract treated any non-empty file as done; new contract re-runs a
  # record that lacks a valid top-level findings key (a worker that emitted
  # garbage). The mock worker overwrites it with a well-formed record.
  mkdir -p "$(fdir "$root")"; printf 'GARBAGE{not json' > "$(fdir "$root")/$h.json"
  run_dream "$root"
  assert_eq "$(jq -e 'has("findings")' "$(fdir "$root")/$h.json" 2>/dev/null)" "true" "garbage findings JSON re-dispatched and replaced"
  rm -rf "$root"
}

test_no_sessions(){
  echo "# no sessions for the date"
  local root; root=$(setup_env)   # no mk_session
  run_dream "$root"
  assert_file "$root/dreams/$DATE.md" "stub report written"
  assert_grep "$root/dreams/$DATE.md" 'No sessions were triaged' "stub report has the no-sessions notice"
  # The stub is harness-neutral now, and it distinguishes "nothing was there"
  # from "everything was refused" — a night where every path was unrepresentable
  # used to read identically to a quiet one.
  assert_grep "$root/dreams/$DATE.md" 'No session files were modified' "a genuinely empty night says so"
  assert_file "$(fdir "$root")/run-stats.txt" "run-stats is written even with zero sessions"
  rm -rf "$root"
}

# ---- The approved L2 model stays stable; environment overrides still win ----
test_l2_uses_the_default_model(){
  echo "# L2: claude-opus-5-5 is the effective default; L1 is claude-haiku-4-5"
  local root; root=$(setup_env); mk_session "$root" sess1
  export FANOUT=1 MOCK_CAPTURE_DIR="$root/cap" AUTODREAM_L2_MODEL=""
  run_dream "$root"
  unset FANOUT MOCK_CAPTURE_DIR AUTODREAM_L2_MODEL
  assert_grep "$root/cap/l2-args.txt" '^claude-opus-5-5$' "L2 requests the approved model"
  assert_grep "$root/cap/l1-args.txt" '^claude-haiku-4-5$' "L1 requests Haiku 4.5"
  assert_grep "$(fdir "$root")/run-stats.txt" '^l2_model: claude-opus-5-5$' "the report records the requested model"
  assert_nonempty "$root/dreams/$DATE.md" "the report lands"
  rm -rf "$root"
}

test_l2_model_pin_is_honoured(){
  echo "# L2: AUTODREAM_L2_MODEL still pins a model when set"
  local root; root=$(setup_env); mk_session "$root" sess1
  printf 'AUTODREAM_L2_MODEL=from-config\n' > "$root/autodream/config"
  export FANOUT=1 MOCK_CAPTURE_DIR="$root/cap" AUTODREAM_L2_MODEL="claude-test-model"
  run_dream "$root"
  unset FANOUT MOCK_CAPTURE_DIR AUTODREAM_L2_MODEL
  local cap="$root/cap/l2-args.txt"
  assert_grep "$cap" '^[-][-]model$' "the model flag is present"
  assert_grep "$cap" '^claude-test-model$' "the exported override wins over the config"
  # The run-stats key exists because the CLI falls back SILENTLY on an
  # unrecognised model, so the artifact has to say what was asked for.
  assert_grep "$root/autodream/findings/$DATE/run-stats.txt" '^l2_model: claude-test-model' \
    "and run-stats records the pin"
  rm -rf "$root"
}

test_framing(){
  echo "# prompt framing regression (literal paths, no \$VAR, blank separator)"
  local root; root=$(setup_env); mk_session "$root" sess1
  export FANOUT=1 MOCK_CAPTURE_DIR="$root/cap"; run_dream "$root"; unset FANOUT MOCK_CAPTURE_DIR
  local cap="$root/cap/l1-stdin.txt"
  assert_file "$cap" "captured the L1 prompt"
  local l1 l2 l3 l4
  l1=$(sed -n '1p' "$cap"); l2=$(sed -n '2p' "$cap"); l3=$(sed -n '3p' "$cap"); l4=$(sed -n '4p' "$cap")
  case "$l1" in "Session transcript to analyze (literal absolute path): /"*) ok "line 1 = literal session path" ;; *) no "line 1 framing (got [$l1])" ;; esac
  case "$l2" in "Write your findings JSON to this literal absolute path: /"*) ok "line 2 = literal output path" ;; *) no "line 2 framing (got [$l2])" ;; esac
  assert_eq "$l3" "" "line 3 = blank separator (doc not glued onto the path)"
  case "$l4" in "# Session Triage"*) ok "line 4 = SESSION_TRIAGE.md begins" ;; *) no "line 4 doc start (got [$l4])" ;; esac
  local doc_line stats_line
  doc_line=$(grep -n '^## Output schema' "$cap" | head -n 1 | cut -d: -f1)
  stats_line=$(grep -n '^## Precomputed session stats' "$cap" | head -n 1 | cut -d: -f1)
  [ -n "$doc_line" ] && [ -n "$stats_line" ] && [ "$stats_line" -gt "$doc_line" ] \
    && ok "precomputed stats block follows the full SESSION_TRIAGE.md body" \
    || no "precomputed stats block follows the full SESSION_TRIAGE.md body"
  assert_grep "$cap" '"tool_call_count": 1' "captured L1 prompt contains the sidecar JSON"
  if printf '%s\n%s\n' "$l1" "$l2" | grep -qE 'SESSION_PATH=|OUTPUT_PATH=|[$]SESSION_PATH|[$]OUTPUT_PATH'; then
    no "no legacy KEY=value / \$VAR framing in the inlined header"
  else
    ok "no legacy KEY=value / \$VAR framing in the inlined header"
  fi
  assert_grep "$root/cap/l1-args.txt" 'not shell variables' "system prompt forbids shell-variable treatment"
  rm -rf "$root"
}

test_changelog(){
  echo "# upstream changelog window (offline, local fixture remote)"
  command -v git >/dev/null 2>&1 || { echo "  skip - git not available"; return 0; }
  local root; root=$(setup_env); mk_session "$root" sess1

  # Build a local 'remote' for anthropics/claude-code: one CHANGELOG commit dated
  # inside the target day [2020-01-02, 2020-01-03), one dated a month later (out of window).
  local up="$root/upstream"; mkdir -p "$up"
  ( cd "$up" && git init -q && git config user.email t@t.invalid && git config user.name t
    printf '# Changelog\n\n## 2.1.999\n\n- In-window mock feature\n' > CHANGELOG.md
    git add CHANGELOG.md
    GIT_AUTHOR_DATE="2020-01-02T12:00:00" GIT_COMMITTER_DATE="2020-01-02T12:00:00" \
      git commit -q -m 'release 2.1.999'
    printf '# Changelog\n\n## 2.2.0\n\n- Out-of-window mock feature\n\n## 2.1.999\n\n- In-window mock feature\n' > CHANGELOG.md
    git add CHANGELOG.md
    GIT_AUTHOR_DATE="2020-02-01T12:00:00" GIT_COMMITTER_DATE="2020-02-01T12:00:00" \
      git commit -q -m 'release 2.2.0' )

  export AUTODREAM_CHANGELOG=1 CHANGELOG_REMOTE="$up" CLAUDE_CODE_REPO="$root/cache/cc"
  run_dream "$root"
  unset AUTODREAM_CHANGELOG CHANGELOG_REMOTE CLAUDE_CODE_REPO

  local cw="$(fdir "$root")/changelog-window.md"
  assert_file   "$cw" "changelog-window.md written"
  assert_grep   "$cw" '2.1.999'              "captures the in-window release"
  assert_grep   "$cw" 'In-window mock'       "captures the in-window bullet"
  assert_nogrep "$cw" '2.2.0'                "excludes the out-of-window release"
  rm -rf "$root"
}

test_prune_helper(){
  echo "# prune-self-sessions helper: list / filter / delete"
  local PR="$REPO/bin/prune-self-sessions.sh"
  [ -x "$PR" ] || { no "prune helper executable"; return 0; }
  local root; root=$(mktemp -d "${TMPDIR:-/tmp}/ccad.XXXXXX")
  mkdir -p "$root/projects/-Users-x"
  local self="$root/projects/-Users-x/self.jsonl" real="$root/projects/-Users-x/real.jsonl"
  printf '{"type":"user","message":{"role":"user","content":"Session transcript to analyze (literal absolute path): /x"}}\n' > "$self"
  printf '{"type":"user","message":{"role":"user","content":"fix the bug in foo.ts"}}\n' > "$real"

  local out; out=$(PROJECTS_DIR="$root/projects" "$PR")
  case "$out" in *self.jsonl*) ok "list includes the self session" ;; *) no "list includes the self session (got [$out])" ;; esac
  case "$out" in *real.jsonl*) no "list must exclude the real session" ;; *) ok "list excludes the real session" ;; esac

  printf '%s\n%s\n' "$self" "$real" | "$PR" --filter > "$root/filtered.txt"
  assert_grep   "$root/filtered.txt" 'real.jsonl' "filter keeps the real session"
  assert_nogrep "$root/filtered.txt" 'self.jsonl' "filter drops the self session"

  PROJECTS_DIR="$root/projects" "$PR" --delete >/dev/null
  assert_no_file "$self" "self session deleted"
  assert_file    "$real" "real session kept"
  rm -rf "$root"
}

test_self_session_excluded(){
  echo "# autodream's own transcripts are excluded from triage"
  local root; root=$(setup_env); mk_session "$root" real1
  local sf="$root/projects/proj-a/selfworker.jsonl"
  printf '{"type":"user","message":{"role":"user","content":"SESSION_PATH=/Users/x/.claude/projects/foo/bar.jsonl"}}\n{"type":"assistant"}\n' > "$sf"
  touch -t "$STAMP" "$sf"
  run_dream "$root"
  local hr hs; hr=$(hash_of "$root/projects/proj-a/real1.jsonl"); hs=$(hash_of "$sf")
  assert_file    "$(fdir "$root")/$hr.json" "real session triaged"
  assert_no_file "$(fdir "$root")/$hs.json" "self-session excluded (no findings JSON)"
  assert_grep    "$root/run.out" 'excluded 1 autodream-own' "run log reports the exclusion"
  rm -rf "$root"
}

test_skip_empty_sessions(){
  echo "# 0-turn shell sessions are skipped before fanout"
  local root; root=$(setup_env); mk_session "$root" real1
  # an auto-opened/aborted shell: a single ai-title line, no user turn at all
  local empty="$root/projects/proj-a/shell.jsonl"
  printf '{"type":"ai-title","title":"some tab title"}\n' > "$empty"
  touch -t "$STAMP" "$empty"
  run_dream "$root"
  local hr he; hr=$(hash_of "$root/projects/proj-a/real1.jsonl"); he=$(hash_of "$empty")
  assert_file    "$(fdir "$root")/$hr.json" "real session triaged"
  assert_no_file "$(fdir "$root")/$he.json" "empty shell skipped (no findings JSON)"
  assert_grep    "$(fdir "$root")/run-stats.txt" 'sessions_skipped_empty: 1' "stats record the empty skip"
  assert_grep    "$(fdir "$root")/run-stats.txt" 'sessions_triaged: 1'        "stats record one triaged"
  assert_grep    "$root/run.out" 'skipped 1 empty' "run log reports the empty skip"
  rm -rf "$root"
}

test_skip_empty_disabled(){
  echo "# AUTODREAM_SKIP_EMPTY=0 keeps 0-turn shells in the triage set"
  local root; root=$(setup_env)
  local empty="$root/projects/proj-a/shell.jsonl"
  printf '{"type":"ai-title","title":"some tab title"}\n' > "$empty"
  touch -t "$STAMP" "$empty"
  export AUTODREAM_SKIP_EMPTY=0; run_dream "$root"; unset AUTODREAM_SKIP_EMPTY
  assert_grep "$(fdir "$root")/run-stats.txt" 'sessions_skipped_empty: 0' "no skips when disabled"
  assert_grep "$(fdir "$root")/run-stats.txt" 'sessions_triaged: 1'        "shell still triaged when disabled"
  rm -rf "$root"
}

test_l1_retry(){
  echo "# L1 retries a flaky session and completes it on a later round"
  local root; root=$(setup_env); mk_session "$root" sess1
  export MOCK_MODE=l1_flaky AUTODREAM_L1_ROUNDS=3; run_dream "$root"; unset MOCK_MODE AUTODREAM_L1_ROUNDS
  local h; h=$(hash_of "$root/projects/proj-a/sess1.jsonl")
  assert_file "$(fdir "$root")/$h.json"  "flaky session produced findings on retry"
  assert_grep "$root/run.out" 'round 2'  "a second L1 round ran"
  assert_file "$root/dreams/$DATE.md"    "report still produced"
  rm -rf "$root"
}

test_idempotency_guard(){
  echo "# existing report short-circuits the run (launchd catch-up no-op)"
  local root; root=$(setup_env); mk_session "$root" sess1
  printf 'SENTINEL REPORT' > "$root/dreams/$DATE.md"
  run_dream "$root"
  assert_eq   "$(cat "$root/dreams/$DATE.md")" "SENTINEL REPORT" "existing report left untouched"
  assert_grep "$root/run.out" 'already exists' "run logged the skip"
  local h; h=$(hash_of "$root/projects/proj-a/sess1.jsonl")
  assert_no_file "$(fdir "$root")/$h.json" "no L1 work done when report already exists"
  rm -rf "$root"
}

test_normalize_project(){
  echo "# project field is normalized deterministically from the session path"
  command -v python3 >/dev/null 2>&1 || { echo "  skip - python3 not available"; return 0; }
  local root; root=$(setup_env); mk_session "$root" sess1
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Skill","input":{"skill":"superpowers:brainstorming"}}]}}' >> "$root/projects/proj-a/sess1.jsonl"
  touch -t "$STAMP" "$root/projects/proj-a/sess1.jsonl"
  export MOCK_MODE=l1_badproject; run_dream "$root"; unset MOCK_MODE
  local h; h=$(hash_of "$root/projects/proj-a/sess1.jsonl")
  local fj="$(fdir "$root")/$h.json"
  assert_file   "$fj" "findings JSON written"
  assert_nogrep "$fj" 'WRONG-PROJECT'     "model's wrong project value was overwritten"
  assert_grep   "$fj" '"project": "proj-a"' "project normalized to the session dir basename"
  # l1_badproject emits the pre-pilot JSON shape (no facet fields) — the report
  # landing proves L2 still accepts legacy findings.
  assert_file   "$root/dreams/$DATE.md" "L2 completed on facet-free legacy findings"
  assert_eq "$(jq -c .skills_invoked "$fj")" '["superpowers:brainstorming"]' \
    "full-transcript skill invocation survives model omission"
  jq '.skills_invoked = []' "$fj" > "$fj.tmp" && mv "$fj.tmp" "$fj"
  AUTODREAM_FORCE=1 run_dream "$root"
  assert_eq "$(jq -c .skills_invoked "$fj")" '["superpowers:brainstorming"]' \
    "report rebuild repairs omitted skills in cached findings"
  rm -rf "$root"
}

test_slim_transcript(){
  echo "# slim-transcript bounds an oversized transcript"
  local SL="$REPO/bin/slim-transcript.sh"
  [ -x "$SL" ] || { no "slim-transcript executable"; return 0; }
  local root; root=$(mktemp -d "${TMPDIR:-/tmp}/ccad.XXXXXX")
  local big="$root/big.jsonl" out="$root/slim.jsonl"
  # 3000 lines × ~3000 chars ≈ 9 MB
  awk 'BEGIN{ b=""; for(i=0;i<3000;i++) b=b "x"; for(n=0;n<3000;n++) print "{\"n\":" n ",\"blob\":\"" b "\"}" }' > "$big"
  "$SL" "$big" "$out"
  local osz; osz=$(wc -c < "$out" | tr -d ' ')
  [ "$osz" -lt 300000 ] && ok "slimmed far below original ($osz bytes < 300k, orig ~9M)" || no "slim output too big ($osz)"
  assert_grep "$out" 'elided by autodream'     "elides the middle"
  assert_grep "$out" 'slimmed this transcript' "appends the slim note"
  rm -rf "$root"
}

test_facet_fields_plumbed(){
  echo "# pilot facet fields flow L1 -> findings JSON -> L2 input"
  # Plumbing only: the L2 mock ignores findings content, so assertions stop at
  # the findings JSON L2 reads. Behavioral quality is the production pilot's job.
  local root; root=$(setup_env); mk_session "$root" sess1
  run_dream "$root"
  local h j; h=$(hash_of "$root/projects/proj-a/sess1.jsonl"); j="$(fdir "$root")/$h.json"
  assert_eq "$(jq -r .outcome "$j")"                          "fully_achieved" "outcome facet present in findings JSON"
  assert_eq "$(jq -r .satisfaction_signals.satisfied "$j")"   "1"              "satisfaction_signals present"
  assert_eq "$(jq -e 'has("underlying_goal")' "$j")"          "true"           "underlying_goal key present (null allowed)"
  assert_eq "$(jq -r '.instructions_given[0]' "$j")"          "always run tests after edits" "instructions_given present"
  assert_file "$root/dreams/$DATE.md" "L2 run completed with facet-bearing findings as input"
  rm -rf "$root"
}

test_noise_gate_trivial(){
  echo "# noise gate: a trivial (1-user-turn) session is stubbed, not sent to the model"
  local root; root=$(setup_env)
  mk_session "$root" real1
  mk_trivial_session "$root" trivial1
  export MOCK_CALL_LOG="$root/calls.log"
  run_dream "$root"
  unset MOCK_CALL_LOG
  local hr ht
  hr=$(hash_of "$root/projects/proj-a/real1.jsonl")
  ht=$(hash_of "$root/projects/proj-a/trivial1.jsonl")
  assert_file    "$(fdir "$root")/$ht.json"     "gated session still got a findings JSON (the stub)"
  # Whitespace-tolerant like test_incomplete: the project-field normalization
  # pass rewrites this stub via json.dump (it has a real session_path + no
  # project), reformatting "skipped":"below_noise_gate" -> "skipped": "..." etc.
  assert_grep    "$(fdir "$root")/$ht.json"     '"skipped": *"below_noise_gate"' "gated stub carries the skip reason"
  assert_grep    "$(fdir "$root")/$ht.json"     '"findings": *\[\]'              "gated stub has an empty findings array"
  assert_no_file "$(fdir "$root")/$ht.json.err" "no .err for a gated session (clean skip, not a failure)"
  assert_grep    "$root/calls.log" "$hr" "model was called for the real session"
  assert_nogrep  "$root/calls.log" "$ht" "model was NOT called for the gated session"
  rm -rf "$root"
}

test_noise_gate_short_duration(){
  echo "# noise gate: duration alone gates even with enough user turns"
  local root; root=$(setup_env)
  mk_short_duration_session "$root" short1
  run_dream "$root"
  local h; h=$(hash_of "$root/projects/proj-a/short1.jsonl")
  assert_grep "$(fdir "$root")/$h.json" '"skipped": *"below_noise_gate"' "short-duration session gated despite 2 user turns"
  rm -rf "$root"
}

test_noise_gate_subagent_carveout(){
  echo "# noise gate: subagent / high-tool-count sessions are never gated"
  local root; root=$(setup_env)
  mk_subagent_session "$root" subagent1
  run_dream "$root"
  local h; h=$(hash_of "$root/projects/proj-a/subagent1.jsonl")
  assert_nogrep "$(fdir "$root")/$h.json" 'below_noise_gate' "subagent session was not gated"
  assert_grep   "$(fdir "$root")/$h.json" 'fully_achieved'    "subagent session got real findings from the model"
  rm -rf "$root"
}

test_noise_gate_stats(){
  echo "# noise gate: gated count in run-stats.txt; precache count stays truthful alongside gating"
  local root; root=$(setup_env)
  mk_session "$root" real1
  mk_trivial_session "$root" trivial1
  mk_session "$root" cached1
  local hc; hc=$(hash_of "$root/projects/proj-a/cached1.jsonl")
  mkdir -p "$(fdir "$root")"
  printf '{"session_path":"CACHED","findings":[]}' > "$(fdir "$root")/$hc.json"
  run_dream "$root"
  local stats="$(fdir "$root")/run-stats.txt"
  assert_grep "$stats" 'gated: 1'                        "gated count recorded"
  assert_grep "$stats" 'sessions_triaged: 3'              "all three sessions counted as triaged"
  assert_grep "$stats" 'l1_sessions_already_done_at_start: 1' "precache count unaffected by gating (only cached1 was precached)"
  local ht; ht=$(hash_of "$root/projects/proj-a/trivial1.jsonl")
  assert_grep "$(fdir "$root")/$ht.json" 'below_noise_gate' "gated session got the stub"
  rm -rf "$root"
}

test_noise_gate_env_override(){
  echo "# noise gate: AUTODREAM_MIN_USER_TURNS override changes the threshold"
  local root; root=$(setup_env)
  mk_trivial_session "$root" trivial1
  export AUTODREAM_MIN_USER_TURNS=1
  run_dream "$root"
  unset AUTODREAM_MIN_USER_TURNS
  local h; h=$(hash_of "$root/projects/proj-a/trivial1.jsonl")
  assert_nogrep "$(fdir "$root")/$h.json" 'below_noise_gate' "lowering the threshold keeps the 1-turn session out of the gate"
  rm -rf "$root"
}

test_oversized_gate_zero(){
  echo "# oversized gate (#12 measurement): both keys present at 0 on a normal run"
  local root; root=$(setup_env); mk_session "$root" sess1
  run_dream "$root"
  local stats="$(fdir "$root")/run-stats.txt"
  assert_grep "$stats" 'oversized_total: 0'   "no oversized sessions under the default threshold"
  assert_grep "$stats" 'oversized_errored: 0' "no oversized-errored sessions under the default threshold"
  rm -rf "$root"
}

test_oversized_gate_total(){
  echo "# oversized gate (#12 measurement): a session over a lowered AUTODREAM_SLIM_BYTES counts as oversized"
  local root; root=$(setup_env); mk_session "$root" sess1
  # mk_session's fixture is 205 bytes; a threshold of 100 puts it over the line
  # without needing a multi-KB fixture. slim-transcript.sh also fires at this
  # size (harmless — the mock still writes findings regardless of readpath).
  export AUTODREAM_SLIM_BYTES=100
  run_dream "$root"
  unset AUTODREAM_SLIM_BYTES
  local stats="$(fdir "$root")/run-stats.txt"
  assert_grep "$stats" 'oversized_total: 1'   "one session counted as oversized"
  assert_grep "$stats" 'oversized_errored: 0' "the oversized session still triaged cleanly (no error key)"
  rm -rf "$root"
}

test_oversized_gate_errored(){
  echo "# oversized gate (#12 measurement): an oversized session that still errors is paired correctly"
  local root; root=$(setup_env); mk_session "$root" sess1
  # Force the final-round metadata stub (carries a top-level "error" key) on an
  # oversized session, and verify oversized_errored pairs the right hash's
  # stats sidecar to the right findings JSON (not just a raw count).
  export AUTODREAM_SLIM_BYTES=100 MOCK_MODE=l1_incomplete AUTODREAM_L1_ROUNDS=1
  run_dream "$root"
  unset AUTODREAM_SLIM_BYTES MOCK_MODE AUTODREAM_L1_ROUNDS
  local stats="$(fdir "$root")/run-stats.txt"
  assert_grep "$stats" 'oversized_total: 1'   "the incomplete session still counted as oversized"
  assert_grep "$stats" 'oversized_errored: 1' "its final-round error stub is paired and counted"
  rm -rf "$root"
}

test_stats_sidecar_ok(){
  echo "# sidecar health (#27): a normal run reports zero unparseable sidecars"
  local root; root=$(setup_env); mk_session "$root" sess1
  run_dream "$root"
  local stats="$(fdir "$root")/run-stats.txt"
  assert_grep "$stats" 'stats_sidecars_unparseable: 0' "healthy sidecars report a real zero"
  rm -rf "$root"
}

test_stats_sidecar_missing_counted(){
  echo "# sidecar health (#27): a session-stats.sh that never runs is counted, not silently absorbed"
  local root; root=$(setup_env)
  mk_session "$root" sess1
  mk_session "$root" sess2
  # compute_session_stats deletes and regenerates every sidecar each run, so the
  # only way to force the broken-sidecar path is to break the generator itself.
  export AUTODREAM_STATS_BIN="$root/does-not-exist.sh"
  run_dream "$root"
  unset AUTODREAM_STATS_BIN
  local stats="$(fdir "$root")/run-stats.txt"
  assert_grep "$stats" 'stats_sidecars_unparseable: 2' "both missing sidecars counted"
  rm -rf "$root"
}

test_stats_sidecar_missing_keeps_oversized_count(){
  echo "# sidecar health (#27): an oversized session does NOT vanish from oversized_total when its sidecar is missing"
  local root; root=$(setup_env); mk_session "$root" sess1
  # This is the issue's exact reproduction: a genuinely oversized session whose
  # sidecar never got written used to drop straight out of oversized_total, the
  # counter that gates #12, with nothing recording that it happened.
  export AUTODREAM_SLIM_BYTES=100 AUTODREAM_STATS_BIN="$root/does-not-exist.sh"
  run_dream "$root"
  unset AUTODREAM_SLIM_BYTES AUTODREAM_STATS_BIN
  local stats="$(fdir "$root")/run-stats.txt"
  assert_grep "$stats" 'oversized_total: 1'            "oversized session still counted via the live-size fallback"
  assert_grep "$stats" 'stats_sidecars_unparseable: 1' "and the sidecar failure is recorded alongside it"
  rm -rf "$root"
}

test_stats_sidecar_malformed_counted(){
  echo "# sidecar health (#27): a sidecar that is a valid object but has no usable transcript_bytes is counted"
  local root; root=$(setup_env); mk_session "$root" sess1
  # compute_session_stats only validates `type == "object"`, so this stub survives
  # generation intact and breaks at read time instead — the quieter of the two paths.
  local stub="$root/stats-no-bytes.sh"
  printf '%s\n' '#!/bin/bash' 'printf %s "{\"user_message_count\":5,\"tool_call_count\":9}" > "$2"' > "$stub"
  chmod +x "$stub"
  export AUTODREAM_SLIM_BYTES=100 AUTODREAM_STATS_BIN="$stub"
  run_dream "$root"
  unset AUTODREAM_SLIM_BYTES AUTODREAM_STATS_BIN
  local stats="$(fdir "$root")/run-stats.txt"
  assert_grep "$stats" 'stats_sidecars_unparseable: 1' "missing transcript_bytes counts as unparseable"
  assert_grep "$stats" 'oversized_total: 1'            "oversized session still counted via the live-size fallback"
  rm -rf "$root"
}

test_stats_sidecar_non_numeric_counted(){
  echo "# sidecar health (#27): a non-numeric transcript_bytes is counted, not clamped to 0 in silence"
  local root; root=$(setup_env); mk_session "$root" sess1
  local stub="$root/stats-bad-bytes.sh"
  printf '%s\n' '#!/bin/bash' 'printf %s "{\"transcript_bytes\":\"lots\"}" > "$2"' > "$stub"
  export AUTODREAM_STATS_BIN="$stub"
  chmod +x "$stub"
  run_dream "$root"
  unset AUTODREAM_STATS_BIN
  local stats="$(fdir "$root")/run-stats.txt"
  assert_grep "$stats" 'stats_sidecars_unparseable: 1' "a string transcript_bytes is not a measurement"
  rm -rf "$root"
}

test_runner_provenance(){
  echo "# runner provenance (#29): run-stats.txt records which code produced it"
  local root; root=$(setup_env); mk_session "$root" sess1
  run_dream "$root"
  local stats="$(fdir "$root")/run-stats.txt"
  # The suite runs run.sh from the repo checkout, so HEAD resolves and the stamp must be
  # the real short SHA rather than the "unknown" degradation path.
  local head; head=$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null)
  assert_grep "$stats" "runner_commit: $head" "stamps the commit the runner was checked out at"
  assert_grep "$stats" 'runner_dirty: \(yes\|no\)' "records whether the tree had uncommitted changes"
  assert_grep "$root/run.out" "runner: $head" "run log names the runner up front"
  rm -rf "$root"
}

test_runner_provenance_no_git(){
  echo "# runner provenance (#29): a non-git install degrades to unknown, never fails the run"
  local root; root=$(setup_env); mk_session "$root" sess1
  # Copy the scripts out of the repo so SCRIPT_DIR resolves somewhere with no git
  # history at all — the tarball-install case, which must still produce a report.
  local bin="$root/bin"; mkdir -p "$bin"
  cp "$REPO"/bin/*.sh "$bin/"
  AUTODREAM_CHANGELOG=0 CLAUDE_BIN="$MOCK" \
  AUTODREAM_NETCHECK=0 AUTODREAM_RETRY_WAIT=0 AUTODREAM_L1_ROUNDS=2 \
  PROJECTS_DIR="$root/projects" AUTODREAM_DIR="$root/autodream" DREAMS_DIR="$root/dreams" \
  bash "$bin/run.sh" "$DATE" > "$root/run.out" 2>&1
  local stats="$(fdir "$root")/run-stats.txt"
  assert_grep "$stats" 'runner_commit: unknown' "no git history degrades to unknown"
  assert_grep "$stats" 'runner_dirty: no'       "dirty is not claimed when the commit is unknown"
  assert_file "$root/dreams/$DATE.md"           "the run still produced a report"
  rm -rf "$root"
}

test_runner_provenance_through_symlink(){
  echo "# runner provenance (#29): the installed symlink layout still stamps the repo's sha"
  local root; root=$(setup_env); mk_session "$root" sess1
  # Reproduce what install.sh actually leaves on disk, which is what the earlier tests
  # missed: ~/.claude/autodream is a REAL directory holding one symlink per script, not a
  # symlink to the checkout. `cd "$(dirname "$0")"` therefore lands in a directory with no
  # .git, and provenance has to follow the file's own link to find the working tree.
  # Six production runs through 2026-08-03 stamped "unknown" against a clean checkout.
  local f; for f in "$REPO"/bin/*.sh; do ln -sf "$f" "$root/autodream/$(basename "$f")"; done
  AUTODREAM_CHANGELOG=0 CLAUDE_BIN="$MOCK" \
  AUTODREAM_CONFIG="$root/autodream/config" AUTODREAM_CONSUME_DATE="$DATE" \
  AUTODREAM_NETCHECK=0 AUTODREAM_RETRY_WAIT=0 AUTODREAM_L1_ROUNDS=2 \
  PROJECTS_DIR="$root/projects" AUTODREAM_DIR="$root/autodream" DREAMS_DIR="$root/dreams" \
  bash "$root/autodream/run.sh" "$DATE" > "$root/run.out" 2>&1
  local head; head=$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null)
  local stats="$(fdir "$root")/run-stats.txt"
  assert_grep "$stats" "runner_commit: $head" "a symlinked runner reports the checkout it points at"
  assert_file "$root/dreams/$DATE.md"          "the run still produced a report"
  rm -rf "$root"
}

test_runner_provenance_relative_symlink(){
  echo "# runner provenance (#29): a symlink with a relative target still finds the checkout"
  command -v python3 >/dev/null 2>&1 || { echo "  skip - python3 not available"; return 0; }
  local root; root=$(setup_env); mk_session "$root" sess1
  # install.sh writes absolute targets, so nothing in production exercises the walk's
  # relative-target branch. A hand-rolled install (ln -s ../../git/oss/cc-autodream/bin/…)
  # produces one, and a target resolved against $PWD instead of the link's own directory
  # silently lands nowhere.
  # Both sides must be physical paths before relpath: on macOS $TMPDIR sits under /var,
  # which is itself a link to /private/var, so a relative path computed from the logical
  # name walks up through a directory that does not exist and the link is born broken.
  local phys_ad phys_bin rel
  phys_ad=$(cd "$root/autodream" && pwd -P)
  phys_bin=$(cd "$REPO/bin" && pwd -P)
  rel=$(python3 -c 'import os,sys;print(os.path.relpath(sys.argv[1],sys.argv[2]))' "$phys_bin" "$phys_ad")
  local f; for f in "$REPO"/bin/*.sh; do ln -sf "$rel/$(basename "$f")" "$root/autodream/$(basename "$f")"; done
  AUTODREAM_CHANGELOG=0 CLAUDE_BIN="$MOCK" \
  AUTODREAM_CONFIG="$root/autodream/config" AUTODREAM_CONSUME_DATE="$DATE" \
  AUTODREAM_NETCHECK=0 AUTODREAM_RETRY_WAIT=0 AUTODREAM_L1_ROUNDS=2 \
  PROJECTS_DIR="$root/projects" AUTODREAM_DIR="$root/autodream" DREAMS_DIR="$root/dreams" \
  bash "$root/autodream/run.sh" "$DATE" > "$root/run.out" 2>&1
  local head; head=$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null)
  assert_grep "$(fdir "$root")/run-stats.txt" "runner_commit: $head" "a relative link target resolves against the link's own dir"
  assert_file "$root/dreams/$DATE.md" "the run still produced a report"
  rm -rf "$root"
}

test_runner_provenance_unresolvable_chain(){
  echo "# runner provenance (#29): a chain past the hop cap says unknown, never a wrong sha"
  local root; root=$(setup_env); mk_session "$root" sess1
  local f; for f in "$REPO"/bin/*.sh; do ln -sf "$f" "$root/autodream/$(basename "$f")"; done
  # A chain longer than the cap leaves the walk holding a path that is still a symlink.
  # Resolving it anyway would stamp the sha of whatever checkout that truncated path sits
  # in — here, this very repo, which is exactly the plausible-but-wrong answer #29 exists
  # to rule out. 12 hops clears the cap of 8 while staying under macOS's ELOOP limit of 16,
  # so bash still executes the script and only the provenance field degrades.
  local prev="$REPO/bin/run.sh" i
  for i in $(seq 1 12); do
    ln -sf "$prev" "$root/autodream/hop-$i.sh"
    prev="$root/autodream/hop-$i.sh"
  done
  ln -sf "$prev" "$root/autodream/run.sh"
  AUTODREAM_CHANGELOG=0 CLAUDE_BIN="$MOCK" \
  AUTODREAM_CONFIG="$root/autodream/config" AUTODREAM_CONSUME_DATE="$DATE" \
  AUTODREAM_NETCHECK=0 AUTODREAM_RETRY_WAIT=0 AUTODREAM_L1_ROUNDS=2 \
  PROJECTS_DIR="$root/projects" AUTODREAM_DIR="$root/autodream" DREAMS_DIR="$root/dreams" \
  bash "$root/autodream/run.sh" "$DATE" > "$root/run.out" 2>&1
  local stats="$(fdir "$root")/run-stats.txt"
  assert_grep "$stats" 'runner_commit: unknown' "an unresolved chain degrades instead of guessing"
  assert_grep "$stats" 'runner_dirty: no'       "dirty is not claimed when the commit is unknown"
  assert_file "$root/dreams/$DATE.md"           "the run still produced a report"
  rm -rf "$root"
}

test_oversized_gate_script(){
  echo "# oversized-gate.sh (#29): recomputes the #12 window from artifacts, including dates whose run-stats.txt lacks the keys"
  local GATE="$REPO/bin/oversized-gate.sh"
  [ -x "$GATE" ] || { no "oversized-gate.sh executable"; return 0; }
  local root; root=$(setup_env); mk_session "$root" sess1
  export AUTODREAM_SLIM_BYTES=100
  run_dream "$root"
  unset AUTODREAM_SLIM_BYTES
  local fd; fd=$(fdir "$root")
  # Strip the keys to simulate a pre-#25 runner: the script must still recover the
  # numbers from the sidecars, which is the whole point of it existing.
  grep -v '^oversized_' "$fd/run-stats.txt" > "$fd/run-stats.tmp" && mv "$fd/run-stats.tmp" "$fd/run-stats.txt"
  assert_nogrep "$fd/run-stats.txt" 'oversized_total' "precondition: the keys really are gone"
  local out; out=$(AUTODREAM_SLIM_BYTES=100 bash "$GATE" "$fd" 2>&1)
  printf '%s' "$out" > "$root/gate.out"
  assert_grep "$root/gate.out" 'GATE CLOSED'  "a clean window reports the gate closed"
  assert_grep "$root/gate.out" '1 oversized'  "recovered the oversized count without run-stats.txt"
  assert_grep "$root/gate.out" 'rule of three' "quotes the upper bound rather than implying 0% is certain"
  rm -rf "$root"
}

test_oversized_gate_script_open(){
  echo "# oversized-gate.sh (#29): an errored oversized session pushes the window over the threshold"
  local GATE="$REPO/bin/oversized-gate.sh"
  [ -x "$GATE" ] || { no "oversized-gate.sh executable"; return 0; }
  local root; root=$(setup_env); mk_session "$root" sess1
  export AUTODREAM_SLIM_BYTES=100 MOCK_MODE=l1_incomplete AUTODREAM_L1_ROUNDS=1
  run_dream "$root"
  unset AUTODREAM_SLIM_BYTES MOCK_MODE AUTODREAM_L1_ROUNDS
  local out; out=$(AUTODREAM_SLIM_BYTES=100 bash "$GATE" "$(fdir "$root")" 2>&1)
  printf '%s' "$out" > "$root/gate.out"
  assert_grep "$root/gate.out" 'GATE OPEN'    "1 of 1 errored is 100%, well over the 5% threshold"
  rm -rf "$root"
}

test_oversized_gate_script_empty(){
  echo "# oversized-gate.sh (#29): an empty window is not reported as a measured 0%"
  local GATE="$REPO/bin/oversized-gate.sh"
  [ -x "$GATE" ] || { no "oversized-gate.sh executable"; return 0; }
  local root; root=$(setup_env); mk_session "$root" sess1
  run_dream "$root"
  local out; out=$(bash "$GATE" "$(fdir "$root")" 2>&1)
  printf '%s' "$out" > "$root/gate.out"
  assert_grep  "$root/gate.out" 'nothing to measure' "no oversized sessions is not evidence either way"
  assert_nogrep "$root/gate.out" 'GATE CLOSED'       "and must not be reported as a closed gate"
  rm -rf "$root"
}

test_oversized_gate_script_args(){
  echo "# oversized-gate.sh (#29): argument validation, including the --days spin found in review"
  local GATE="$REPO/bin/oversized-gate.sh"
  [ -x "$GATE" ] || { no "oversized-gate.sh executable"; return 0; }
  # `--days` with no value left $# at 1 while `shift 2` refused to shift, looping forever.
  # A hang in a nightly-adjacent script is worse than a wrong number, so it gets a test.
  # These are the only assertions in the suite that need GNU `timeout`. Stock macOS has
  # neither name; homebrew coreutils installs `gtimeout`, and `timeout` too if its gnubin
  # is on PATH. Resolve whichever exists and say so plainly when neither does — without
  # this, all four assertions come back as exit 127 and read like real regressions.
  local TO=""
  command -v timeout  >/dev/null 2>&1 && TO=timeout
  [ -n "$TO" ] || { command -v gtimeout >/dev/null 2>&1 && TO=gtimeout; }
  [ -n "$TO" ] || { no "oversized-gate arg tests need GNU timeout (brew install coreutils)"; return 0; }
  local out rc
  out=$( { "$TO" 10 bash "$GATE" --days; } 2>&1 ); rc=$?
  assert_eq "$rc" "2" "--days with no value exits 2 instead of hanging (124 would be the hang)"
  out=$( { "$TO" 10 bash "$GATE" --days abc; } 2>&1 ); rc=$?
  assert_eq "$rc" "2" "--days with a non-integer exits 2"
  out=$( { "$TO" 10 bash "$GATE" --days 0; } 2>&1 ); rc=$?
  assert_eq "$rc" "2" "--days 0 exits 2"
  out=$( { "$TO" 10 bash "$GATE" --bogus; } 2>&1 ); rc=$?
  assert_eq "$rc" "2" "an unknown option exits 2 rather than being read as a findings dir"
}

test_notify_count(){
  echo "# notify.sh counts from the open-questions marker, falling back to shape for older reports"
  local NOTIFY="$REPO/bin/notify.sh"
  [ -x "$NOTIFY" ] || { no "notify.sh executable"; return 0; }
  local root; root=$(mktemp -d "${TMPDIR:-/tmp}/ccad.XXXXXX")
  # Pre-seed an executable stub at the branded-notifier path so the test neither
  # bootstraps a real app bundle nor posts a real banner. OSA backup off for the same
  # reason; SUBL points at true so no editor opens.
  mkdir -p "$root/cc-autodream.app/Contents/MacOS"
  printf '#!/bin/sh\nexit 0\n' > "$root/cc-autodream.app/Contents/MacOS/terminal-notifier"
  chmod +x "$root/cc-autodream.app/Contents/MacOS/terminal-notifier"
  run_notify(){
    AUTODREAM_DIR="$root" AUTODREAM_NOTIFY_OSA_BACKUP=0 SUBL=/usr/bin/true \
      "$NOTIFY" "$1" > "$root/notify.out" 2>&1
  }
  mk_report(){ # $1=date, stdin=Open questions section body
    local f="$root/$1.md"
    { printf '# Autodream — %s\n\n## Open questions for the user\n' "$1"; cat; printf '\n## Trailing section\n'; } > "$f"
    printf '%s' "$f"
  }

  # --- marker is authoritative, even when the section's shape says otherwise ---
  # This is the real 2026-07-24 shape: one numbered question, then a "dropped by the
  # gate" list. The old counter scored 6 here; the marker says 1.
  local f
  f=$(mk_report 2020-02-01 <<'EOF'
**One question survived the triviality gate.**

1. **A real question** — should we do the thing?

Other findings dropped by the gate:
- Pattern 1 already addressed on disk.
- Pattern 2 settled last week.
- Pattern 3 below threshold.
- Pattern 4 quarantined.

<!-- autodream:open-questions=1 -->
EOF
)
  run_notify "$f"
  assert_grep "$root/inbox/2020-02-01-open-questions.md" '^# 1 open question$' "marker wins over the 6 list lines in the section"

  # --- marker of 0 must stay silent even though the section has prose and bullets ---
  f=$(mk_report 2020-02-02 <<'EOF'
None that clear the triviality gate this run.

- Pattern 1 was already fixed on disk.
- Pattern 2 is under a standing moratorium.

<!-- autodream:open-questions=0 -->
EOF
)
  run_notify "$f"
  assert_no_file "$root/inbox/2020-02-02-open-questions.md" "marker=0 writes no inbox file despite a non-empty section"
  assert_grep "$root/notify.out" '0 open questions' "marker=0 reports zero"

  # --- no marker (pre-contract report): numbered items win over their sub-bullets ---
  f=$(mk_report 2020-02-03 <<'EOF'
1. First question?
   - supporting detail
   - more detail
2. Second question?
   - supporting detail
EOF
)
  run_notify "$f"
  assert_grep "$root/inbox/2020-02-03-open-questions.md" '^# 2 open questions$' "no marker: 2 items, not 5 list lines"

  # --- no marker: bold topic titles beat the bullets underneath them ---
  f=$(mk_report 2020-02-04 <<'EOF'
**Scrape skill guardrail**
- Update step 3?
- Add a step-6 check?

**TLS-bypass rule**
- Add a rule?
- Where should it live?
EOF
)
  run_notify "$f"
  assert_grep "$root/inbox/2020-02-04-open-questions.md" '^# 2 open questions$' "no marker: 2 titles, not 4 bullets"

  # --- no marker: plain bullets are the questions ---
  f=$(mk_report 2020-02-05 <<'EOF'
- Raise the fanout?
- Drop the cache?
EOF
)
  run_notify "$f"
  assert_grep "$root/inbox/2020-02-05-open-questions.md" '^# 2 open questions$' "no marker: plain bullets counted"

  # --- no marker: bare prose still pops, since a non-empty section has something to say ---
  f=$(mk_report 2020-02-06 <<'EOF'
Should the fanout be raised to 12 given the recent session volume?
EOF
)
  run_notify "$f"
  assert_grep "$root/inbox/2020-02-06-open-questions.md" '^# 1 open question$' "no marker: prose falls back to 1"

  # --- no marker: a "None ..." lead-in is zero, not a prose question ---
  # Without this case the prose tier turns every quiet pre-marker night into a false pop.
  f=$(mk_report 2020-02-07 <<'EOF'
None that clear the triviality gate this run.
EOF
)
  run_notify "$f"
  assert_no_file "$root/inbox/2020-02-07-open-questions.md" "no marker: a None lead-in stays silent"

  # --- genuinely empty section stays a quiet no-op ---
  f=$(mk_report 2020-02-08 </dev/null)
  run_notify "$f"
  assert_no_file "$root/inbox/2020-02-08-open-questions.md" "empty section writes nothing"
  assert_grep "$root/notify.out" '0 open questions' "empty section reports zero"

  rm -rf "$root"
}

test_notify_open_command(){
  echo "# notify.sh opens the inbox via AUTODREAM_OPEN (multi-word commands, deprecated SUBL alias)"
  local NOTIFY="$REPO/bin/notify.sh"
  [ -x "$NOTIFY" ] || { no "notify.sh executable"; return 0; }
  local root; root=$(mktemp -d "${TMPDIR:-/tmp}/ccad.XXXXXX")
  mkdir -p "$root/cc-autodream.app/Contents/MacOS"
  printf '#!/bin/sh\nexit 0\n' > "$root/cc-autodream.app/Contents/MacOS/terminal-notifier"
  chmod +x "$root/cc-autodream.app/Contents/MacOS/terminal-notifier"
  # A recorder standing in for an editor: logs every argument it was handed, one per
  # line, so the test can prove word-splitting and quoting rather than just exit status.
  printf '#!/bin/sh\nfor a in "$@"; do echo "$a"; done >> "%s/opened.log"\n' "$root" > "$root/fake-editor"
  chmod +x "$root/fake-editor"

  printf '# Autodream — 2020-03-01\n\n## Open questions for the user\n1. A question?\n\n<!-- autodream:open-questions=1 -->\n' \
    > "$root/2020-03-01.md"

  # single-word command
  AUTODREAM_DIR="$root" AUTODREAM_NOTIFY_OSA_BACKUP=0 AUTODREAM_OPEN="$root/fake-editor" \
    "$NOTIFY" "$root/2020-03-01.md" > "$root/notify.out" 2>&1
  assert_grep "$root/opened.log" "2020-03-01-open-questions.md" "AUTODREAM_OPEN received the inbox path"
  assert_grep "$root/notify.out" 'opened .* with:' "log names the command it opened with"

  # multi-word command: the flag and the path must arrive as separate arguments
  : > "$root/opened.log"
  AUTODREAM_DIR="$root" AUTODREAM_NOTIFY_OSA_BACKUP=0 AUTODREAM_OPEN="$root/fake-editor --flag" \
    "$NOTIFY" "$root/2020-03-01.md" > "$root/notify.out" 2>&1
  assert_grep "$root/opened.log" '^--flag$'    "multi-word command word-splits into its own argument"
  assert_eq "$(wc -l < "$root/opened.log" | tr -d ' ')" "2" "exactly two arguments: the flag and the path"

  # a path with a space must stay ONE argument, not split by sh -c
  : > "$root/opened.log"
  mkdir -p "$root/dir with space"
  printf '# Autodream — 2020-03-02\n\n## Open questions for the user\n1. A question?\n\n<!-- autodream:open-questions=1 -->\n' \
    > "$root/dir with space/2020-03-02.md"
  AUTODREAM_DIR="$root" AUTODREAM_NOTIFY_OSA_BACKUP=0 AUTODREAM_OPEN="$root/fake-editor" \
    "$NOTIFY" "$root/dir with space/2020-03-02.md" > "$root/notify.out" 2>&1
  assert_eq "$(wc -l < "$root/opened.log" | tr -d ' ')" "1" "a spaced path arrives as a single argument"

  # SUBL still honored as the deprecated alias, so existing setups keep working
  : > "$root/opened.log"
  AUTODREAM_DIR="$root" AUTODREAM_NOTIFY_OSA_BACKUP=0 SUBL="$root/fake-editor" \
    "$NOTIFY" "$root/2020-03-01.md" > "$root/notify.out" 2>&1
  assert_grep "$root/opened.log" "2020-03-01-open-questions.md" "deprecated SUBL alias still opens the file"

  # AUTODREAM_OPEN wins when both are set
  : > "$root/opened.log"
  AUTODREAM_DIR="$root" AUTODREAM_NOTIFY_OSA_BACKUP=0 \
    AUTODREAM_OPEN="$root/fake-editor --winner" SUBL=/usr/bin/false \
    "$NOTIFY" "$root/2020-03-01.md" > "$root/notify.out" 2>&1
  assert_grep "$root/opened.log" '^--winner$' "AUTODREAM_OPEN takes precedence over SUBL"

  # a broken open command must not fail the run — the inbox file is the durable output
  AUTODREAM_DIR="$root" AUTODREAM_NOTIFY_OSA_BACKUP=0 AUTODREAM_OPEN="$root/does-not-exist" \
    "$NOTIFY" "$root/2020-03-01.md" > "$root/notify.out" 2>&1
  assert_eq "$?" "0" "a failing open command still exits 0"
  assert_grep "$root/notify.out" 'failed to open' "and says so instead of pretending it opened"
  assert_file "$root/inbox/2020-03-01-open-questions.md" "inbox file written regardless"

  rm -rf "$root"
}

test_notify_dryrun(){
  echo "# notify.sh dry run reports the count without writing, posting, or opening anything"
  local NOTIFY="$REPO/bin/notify.sh"
  [ -x "$NOTIFY" ] || { no "notify.sh executable"; return 0; }
  local root; root=$(mktemp -d "${TMPDIR:-/tmp}/ccad.XXXXXX")
  # Deliberately NO stub notifier here. That is the whole point: a real sweep pointed
  # AUTODREAM_DIR at a temp dir and assumed that was enough, but with no branded bundle
  # present the resolution falls through to a system terminal-notifier and posts for
  # real. Dry run has to be safe without any stubbing at all.
  printf '#!/bin/sh\necho "$@" >> "%s/opened.log"\n' "$root" > "$root/fake-editor"
  chmod +x "$root/fake-editor"
  printf '# Autodream — 2020-04-01\n\n## Open questions for the user\n1. One?\n2. Two?\n\n<!-- autodream:open-questions=2 -->\n' \
    > "$root/2020-04-01.md"

  local out; out=$(AUTODREAM_DIR="$root" AUTODREAM_NOTIFY_DRYRUN=1 AUTODREAM_OPEN="$root/fake-editor" \
    "$NOTIFY" "$root/2020-04-01.md" 2>&1)
  printf '%s' "$out" > "$root/dry.out"
  assert_grep    "$root/dry.out" 'dry run'          "says it was a dry run"
  assert_grep    "$root/dry.out" '2 open questions' "still reports the real count"
  assert_no_file "$root/inbox/2020-04-01-open-questions.md" "dry run writes no inbox file"
  assert_no_file "$root/opened.log"                 "dry run opens nothing"

  # And the same report without the flag DOES do the work, so the guard isn't just off.
  # NOW seed the stub notifier: this call reaches the posting code, and without a stub at
  # the branded path the resolution falls through to a system terminal-notifier and fires
  # a real banner. That is the very accident this feature exists to prevent, and writing
  # the test without the stub reproduced it — the suite posted a live notification for a
  # fixture dated 2020-04-01. The dry-run assertions above stay stub-free on purpose.
  mkdir -p "$root/cc-autodream.app/Contents/MacOS"
  printf '#!/bin/sh\nexit 0\n' > "$root/cc-autodream.app/Contents/MacOS/terminal-notifier"
  chmod +x "$root/cc-autodream.app/Contents/MacOS/terminal-notifier"
  AUTODREAM_DIR="$root" AUTODREAM_NOTIFY_OSA_BACKUP=0 AUTODREAM_OPEN="$root/fake-editor" \
    "$NOTIFY" "$root/2020-04-01.md" > "$root/wet.out" 2>&1
  assert_file "$root/inbox/2020-04-01-open-questions.md" "without the flag the inbox file is written"
  assert_file "$root/opened.log"                         "without the flag the open command runs"

  # A zero-question report is quiet either way, and must not claim to be a dry run.
  printf '# Autodream — 2020-04-02\n\n## Open questions for the user\nNone that clear the gate.\n\n<!-- autodream:open-questions=0 -->\n' \
    > "$root/2020-04-02.md"
  out=$(AUTODREAM_DIR="$root" AUTODREAM_NOTIFY_DRYRUN=1 "$NOTIFY" "$root/2020-04-02.md" 2>&1)
  printf '%s' "$out" > "$root/dry0.out"
  assert_grep   "$root/dry0.out" '0 open questions' "zero-count report still reports zero"
  assert_nogrep "$root/dry0.out" 'dry run'          "the zero path exits before the dry-run notice"

  rm -rf "$root"
}

test_runner_dirty_ignores_untracked(){
  echo "# runner_dirty (#29 follow-up): an untracked scratch file is not a dirty runner"
  local root; root=$(setup_env); mk_session "$root" sess1
  # A clean checkout with a stray untracked file reported runner_dirty: yes on the first
  # production run. Only tracked modifications mean "code that exists in nobody's history".
  local repo="$root/repo"; mkdir -p "$repo"
  cp -R "$REPO/bin" "$repo/bin"; cp -R "$REPO/prompts" "$repo/prompts"
  git -C "$repo" init -q 2>/dev/null
  git -C "$repo" add -A 2>/dev/null
  git -C "$repo" -c user.email=t@t -c user.name=t commit -qm init 2>/dev/null
  printf 'scratch\n' > "$repo/untracked-scratch.txt"
  AUTODREAM_CHANGELOG=0 CLAUDE_BIN="$MOCK" \
  AUTODREAM_NETCHECK=0 AUTODREAM_RETRY_WAIT=0 AUTODREAM_L1_ROUNDS=2 \
  PROJECTS_DIR="$root/projects" AUTODREAM_DIR="$root/autodream" DREAMS_DIR="$root/dreams" \
  bash "$repo/bin/run.sh" "$DATE" > "$root/run.out" 2>&1
  local stats="$(fdir "$root")/run-stats.txt"
  assert_grep "$stats" 'runner_dirty: no' "an untracked file alone does not mark the runner dirty"

  # A tracked modification still does.
  printf '\n# tracked edit\n' >> "$repo/bin/session-stats.sh"
  rm -rf "$(fdir "$root")" "$root/dreams/$DATE.md"
  AUTODREAM_CHANGELOG=0 CLAUDE_BIN="$MOCK" \
  AUTODREAM_NETCHECK=0 AUTODREAM_RETRY_WAIT=0 AUTODREAM_L1_ROUNDS=2 \
  PROJECTS_DIR="$root/projects" AUTODREAM_DIR="$root/autodream" DREAMS_DIR="$root/dreams" \
  bash "$repo/bin/run.sh" "$DATE" > "$root/run2.out" 2>&1
  assert_grep "$(fdir "$root")/run-stats.txt" 'runner_dirty: yes' "a tracked modification still marks the runner dirty"
  rm -rf "$root"
}

test_overlap_pair(){
  echo "# overlap (#14): two alternating-close sessions count as ONE pair regardless of qualifying turn-pairs"
  local root; root=$(setup_env)
  # A: 10:00, 10:20   B: 10:05, 10:25 — every A/B turn combo is within 30 min
  # (A0-B0=5m, A0-B1=25m, A1-B0=15m, A1-B1=5m), so four turn-pairs qualify but
  # the {A,B} pair must be counted exactly once.
  mk_timed_session "$root" sessA "2026-07-20T10:00:00Z" "2026-07-20T10:20:00Z"
  mk_timed_session "$root" sessB "2026-07-20T10:05:00Z" "2026-07-20T10:25:00Z"
  run_dream "$root"
  local stats="$(fdir "$root")/run-stats.txt"
  assert_grep "$stats" 'overlap_measured: yes'     "a real overlap measurement happened"
  assert_grep "$stats" 'overlap_events: 1'         "exactly one distinct pair counted"
  assert_grep "$stats" 'sessions_with_overlap: 2'  "both sessions counted as involved"
  rm -rf "$root"
}

test_overlap_triple(){
  echo "# overlap (#14): three pairwise-overlapping sessions -> 3 pairs, 3 sessions"
  local root; root=$(setup_env)
  # A@10:00, B@10:10, C@10:20 — every pair (A-B=10m, B-C=10m, A-C=20m) is within 30 min.
  mk_timed_session "$root" sessA "2026-07-20T10:00:00Z"
  mk_timed_session "$root" sessB "2026-07-20T10:10:00Z"
  mk_timed_session "$root" sessC "2026-07-20T10:20:00Z"
  run_dream "$root"
  local stats="$(fdir "$root")/run-stats.txt"
  assert_grep "$stats" 'overlap_measured: yes'     "a real overlap measurement happened"
  assert_grep "$stats" 'overlap_events: 3'         "all three pairs counted"
  assert_grep "$stats" 'sessions_with_overlap: 3'  "all three sessions counted as involved"
  rm -rf "$root"
}

test_overlap_none(){
  echo "# overlap (#14): sessions more than 30 minutes apart -> both stats 0, keys still present"
  local root; root=$(setup_env)
  mk_timed_session "$root" sessA "2026-07-20T10:00:00Z"
  mk_timed_session "$root" sessB "2026-07-20T11:00:00Z"
  run_dream "$root"
  local stats="$(fdir "$root")/run-stats.txt"
  # This is the genuine-zero case (#26): the pass DID run, it just found nothing to
  # pair. overlap_measured must positively say so — that's the whole point of the fix,
  # distinguishing this from a pass that never ran.
  assert_grep "$stats" 'overlap_measured: yes'     "genuine zero overlap is still a real measurement"
  assert_grep "$stats" 'overlap_events: 0'         "no pairs when sessions are far apart"
  assert_grep "$stats" 'sessions_with_overlap: 0'  "no sessions involved when sessions are far apart"
  rm -rf "$root"
}

test_overlap_not_measured_missing_bin(){
  echo "# overlap (#26): AUTODREAM_OVERLAP_BIN pointed at a nonexistent path -> not measured, counts still 0"
  local root; root=$(setup_env)
  mk_timed_session "$root" sessA "2026-07-20T10:00:00Z"
  mk_timed_session "$root" sessB "2026-07-20T10:05:00Z"
  export AUTODREAM_OVERLAP_BIN="$root/does-not-exist.sh"; run_dream "$root"; unset AUTODREAM_OVERLAP_BIN
  local stats="$(fdir "$root")/run-stats.txt"
  assert_grep "$stats" 'overlap_measured: no'      "missing overlap-stats.sh binary is not a measurement"
  assert_grep "$stats" 'overlap_events: 0'          "count key still present at 0"
  assert_grep "$stats" 'sessions_with_overlap: 0'   "count key still present at 0"
  rm -rf "$root"
}

test_overlap_not_measured_empty_output(){
  echo "# overlap (#26): overlap-stats.sh stub that prints nothing -> not measured"
  local root; root=$(setup_env)
  mk_timed_session "$root" sessA "2026-07-20T10:00:00Z"
  mk_timed_session "$root" sessB "2026-07-20T10:05:00Z"
  local stub="$root/overlap-empty.sh"
  printf '#!/bin/bash\nexit 0\n' > "$stub"
  chmod +x "$stub"
  export AUTODREAM_OVERLAP_BIN="$stub"; run_dream "$root"; unset AUTODREAM_OVERLAP_BIN
  local stats="$(fdir "$root")/run-stats.txt"
  assert_grep "$stats" 'overlap_measured: no'      "empty overlap-stats.sh output is not a measurement"
  assert_grep "$stats" 'overlap_events: 0'          "count key still present at 0"
  assert_grep "$stats" 'sessions_with_overlap: 0'   "count key still present at 0"
  rm -rf "$root"
}

test_overlap_not_measured_malformed_output(){
  echo "# overlap (#26): overlap-stats.sh stub that prints non-JSON -> not measured"
  local root; root=$(setup_env)
  mk_timed_session "$root" sessA "2026-07-20T10:00:00Z"
  mk_timed_session "$root" sessB "2026-07-20T10:05:00Z"
  local stub="$root/overlap-malformed.sh"
  printf '#!/bin/bash\necho "not json at all"\n' > "$stub"
  chmod +x "$stub"
  export AUTODREAM_OVERLAP_BIN="$stub"; run_dream "$root"; unset AUTODREAM_OVERLAP_BIN
  local stats="$(fdir "$root")/run-stats.txt"
  assert_grep "$stats" 'overlap_measured: no'      "malformed overlap-stats.sh output is not a measurement"
  assert_grep "$stats" 'overlap_events: 0'          "count key still present at 0"
  assert_grep "$stats" 'sessions_with_overlap: 0'   "count key still present at 0"
  rm -rf "$root"
}

# ---------------------------------------------------------------------------

[ -x "$RUN" ]  || { echo "FATAL: $RUN not executable"; exit 1; }
[ -x "$MOCK" ] || { echo "FATAL: $MOCK not executable"; exit 1; }

echo "cc-autodream integration tests (mock claude)"
echo
test_happy
test_session_stats
test_unreadable
test_incomplete
test_idempotent
test_revalidates_garbage
test_no_sessions
test_l2_uses_the_default_model
test_l2_model_pin_is_honoured

# ---- L1 invocation lives in bin/l1-invoke.sh: pin the exact argv and prompt framing ----
test_l1_invocation_argv_and_prompt(){
  echo "# L1: exact argv and prompt framing from the shared invocation"
  unset AUTODREAM_L1_MODEL AUTODREAM_L1_EFFORT
  local root; root=$(setup_env); mk_session "$root" sess1
  export FANOUT=1 MOCK_CAPTURE_DIR="$root/cap"
  run_dream "$root"
  unset FANOUT MOCK_CAPTURE_DIR
  local expected
  expected=$(cat <<'ARGV'
--print
--permission-mode
bypassPermissions
--model
claude-haiku-4-5
--no-session-persistence
--tools
Read
Write
--disable-slash-commands
--strict-mcp-config
--settings
{"disableAllHooks":true}
--append-system-prompt
Headless triage worker. Read the session transcript and write exactly one findings JSON object, via the Write tool, to the literal output path given on line 2 of the prompt. Those paths are literal strings, not shell variables — never $-expand them. Print only the literal word done and exit.
ARGV
)
  assert_eq "$(cat "$root/cap/l1-args.txt")" "$expected" "L1 argv is exactly the production command (no --effort by default)"
  local in="$root/cap/l1-stdin.txt"
  assert_grep "$in" '^Session transcript to analyze (literal absolute path): /' "prompt line 1 is the transcript path"
  assert_grep "$in" '^Write your findings JSON to this literal absolute path: /' "prompt line 2 is the output path"
  assert_eq "$(sed -n 3p "$in")" "" "a blank line separates the header from the triage prompt"
  assert_eq "$(sed -n 4p "$in")" "$(sed -n 1p "$REPO/prompts/SESSION_TRIAGE.md")" "the triage prompt follows verbatim"
  assert_grep "$in" '^## Precomputed session stats (authoritative' "the stats block is appended when a sidecar exists"
  rm -rf "$root"
}

test_l1_model_and_effort_overrides(){
  echo "# L1: AUTODREAM_L1_MODEL and AUTODREAM_L1_EFFORT reach the CLI"
  local root; root=$(setup_env); mk_session "$root" sess1
  export FANOUT=1 MOCK_CAPTURE_DIR="$root/cap" AUTODREAM_L1_MODEL=claude-opus-5-5 AUTODREAM_L1_EFFORT=high
  run_dream "$root"
  unset FANOUT MOCK_CAPTURE_DIR AUTODREAM_L1_MODEL AUTODREAM_L1_EFFORT
  assert_eq "$(sed -n 4,7p "$root/cap/l1-args.txt" | tr '\n' ' ')" "--model claude-opus-5-5 --effort high " "model then effort, in that order"
  assert_grep "$root/cap/l1-args.txt" '^--no-session-persistence$' "the rest of the argv is unchanged"
  rm -rf "$root"
}

test_l1_invocation_argv_and_prompt
test_l1_model_and_effort_overrides

test_l1_overrides_are_documented_in_the_header(){
  echo "# L1: the overrides are documented in run.sh's header (the README points there)"
  assert_grep "$RUN" '^#   AUTODREAM_L1_MODEL ' "header documents AUTODREAM_L1_MODEL"
  assert_grep "$RUN" '^#   AUTODREAM_L1_EFFORT ' "header documents AUTODREAM_L1_EFFORT"
}
test_l1_overrides_are_documented_in_the_header
test_framing
test_changelog
test_prune_helper
test_self_session_excluded
test_skip_empty_sessions
test_skip_empty_disabled
test_l1_retry
test_idempotency_guard
test_self_audit_stats
test_self_audit_stats_failure_denominator
test_self_audit_stats_precached_disambiguation
test_normalize_project
test_slim_transcript
test_facet_fields_plumbed
test_noise_gate_trivial
test_noise_gate_short_duration
test_noise_gate_subagent_carveout
test_noise_gate_stats
test_noise_gate_env_override
test_oversized_gate_zero
test_oversized_gate_total
test_oversized_gate_errored
test_stats_sidecar_ok
test_stats_sidecar_missing_counted
test_stats_sidecar_missing_keeps_oversized_count
test_stats_sidecar_malformed_counted
test_stats_sidecar_non_numeric_counted
test_runner_provenance
test_runner_provenance_no_git
test_runner_provenance_through_symlink
test_runner_provenance_relative_symlink
test_runner_provenance_unresolvable_chain
test_oversized_gate_script
test_oversized_gate_script_open
test_oversized_gate_script_empty
test_oversized_gate_script_args
test_notify_count
test_notify_open_command
test_notify_dryrun
test_runner_dirty_ignores_untracked
test_overlap_pair
test_overlap_triple
test_overlap_none
test_overlap_not_measured_missing_bin
test_overlap_not_measured_empty_output
test_overlap_not_measured_malformed_output
test_notes_no_surfaces
test_notes_from_notes_file
test_notes_from_vault_inbox
test_notes_vault_expired_dropped
test_notes_vault_archived_after_report
test_notes_vault_not_archived_without_report
test_notes_vault_report_published
test_notes_vault_unreadable_note_stays
test_config_file_sourced
test_config_env_wins_over_config
test_notes_header_only_file_does_not_abort
test_notes_icloud_placeholder_is_counted
test_notes_placeholder_and_real_file_counted_once
test_notes_expiry_uses_report_date
test_force_rebuild_failed_l2_does_not_consume
test_unmovable_stale_report_disarms_consuming
test_partial_report_does_not_consume
test_partial_report_keeps_previous
test_partial_report_does_not_block_retry
test_complete_report_retires_partials
test_dead_stdout_does_not_kill_the_run
test_unassembled_dates_are_surfaced
test_unassembled_ignores_a_finished_date
test_no_sessions_stub_carries_marker
test_old_date_reprocess_does_not_consume
test_config_unbound_var_does_not_kill_run
# ---- Multi-root session scanning (SESSION_ROOTS) + root-probe ----

# A run that scans more than one projects dir: primary + one alt, both holding sessions
# touched into the target day. Works by NOT exporting PROJECTS_DIR (so autodetect runs)
# and overriding HOME into the sandbox so root-probe discovers the sandbox's claude dirs
# rather than the host's.
run_dream_autodetect(){ # $1=root — like run_dream but with HOME inside the sandbox, no PROJECTS_DIR
  AUTODREAM_CHANGELOG=0 CLAUDE_BIN="$MOCK" \
  AUTODREAM_CONFIG="$1/autodream/config" \
  AUTODREAM_CONSUME_DATE="$DATE" \
  AUTODREAM_NETCHECK=0 AUTODREAM_RETRY_WAIT=0 AUTODREAM_L1_ROUNDS=2 \
  HOME="$1/home" AUTODREAM_DIR="$1/autodream" DREAMS_DIR="$1/dreams" \
  bash "$RUN" "$DATE" > "$1/run.out" 2>&1
  cat "$1/autodream/logs/run-$DATE.log" >> "$1/run.out" 2>/dev/null || true
}
setup_env_altroot(){ # like setup_env, but with HOME inside the sandbox (no $1/projects); echoes the root
  local root; root=$(mktemp -d "${TMPDIR:-/tmp}/ccad.XXXXXX")
  mkdir -p "$root/home/.claude/projects/proj-a" \
           "$root/home/.claude-ds4/projects/proj-a" \
           "$root/autodream" "$root/dreams" "$root/cap"
  cp "$REPO/prompts/SESSION_TRIAGE.md" "$root/autodream/SESSION_TRIAGE.md"
  cp "$REPO/prompts/PROMPT.md"         "$root/autodream/PROMPT.md"
  printf '%s' "$root"
}
mk_session_in(){ # $1=dir $2=name
  local f="$1/$2.jsonl"
  printf '%s\n' \
    '{"type":"user","cwd":"/tmp/proj-a","message":{"content":"start the task"}}' \
    '{"type":"user","message":{"content":"keep going"}}' \
    '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read"}]}}' \
    > "$f"
  touch -t "$STAMP" "$f"
}

# Mark an alt root as decided-index so probe_roots scans it.
decide_index(){ # $1=root-dir — writes $AUTODREAM_DIR/root-choices.conf
  mkdir -p "$1/autodream"
  printf '%s=index\n' "$2" >> "$1/autodream/root-choices.conf"
}

test_multiroot_triages_alt_root(){
  echo "# multi-root: sessions in a second (decided) claude dir get triaged too"
  local root; root=$(setup_env_altroot)
  decide_index "$root" "$root/home/.claude-ds4/projects"
  mk_session_in "$root/home/.claude/projects/proj-a" s1
  mk_session_in "$root/home/.claude-ds4/projects/proj-a" s2
  run_dream_autodetect "$root"
  local fdir="$root/autodream/findings/$DATE"
  assert_grep "$root/run.out" "session roots:" "probe_roots logged the resolved roots"
  assert_file "$fdir/$(printf '%s' "$root/home/.claude/projects/proj-a/s1.jsonl" | shasum | cut -c1-12).json" "primary-root session has a findings JSON"
  assert_file "$fdir/$(printf '%s' "$root/home/.claude-ds4/projects/proj-a/s2.jsonl" | shasum | cut -c1-12).json" "decided alt-root session has a findings JSON"
  assert_grep "$root/autodream/findings/$DATE/sessions.txt.raw" "$root/home/.claude/projects/proj-a/s1.jsonl" "primary session enumerated"
  assert_grep "$root/autodream/findings/$DATE/sessions.txt.raw" "$root/home/.claude-ds4/projects/proj-a/s2.jsonl" "decided alt session enumerated"
  assert_grep "$root/autodream/findings/$DATE/run-stats.txt" "session_roots: 2" "run-stats reports 2 roots scanned"
  # A decided-index root is not flagged.
  assert_nogrep "$root/autodream/findings/$DATE/unindexed-roots.txt" "$root/home/.claude-ds4/projects" "a decided-index root is not flagged"
  rm -rf "$root"
}

test_multiroot_heldout_and_dedup(){
  echo "# multi-root: undecided dirs are held out (flagged, not triaged); a file reachable via symlink from two roots is triaged once"
  local root; root=$(setup_env_altroot)
  decide_index "$root" "$root/home/.claude-ds4/projects"
  # An undecided third dir (present, no choice recorded).
  mkdir -p "$root/home/.claude-sigint/projects/proj-a"
  mk_session_in "$root/home/.claude-sigint/projects/proj-a" s9
  mk_session_in "$root/home/.claude/projects/proj-a" s1
  # The same transcript reachable from both decided roots: a symlink in the alt root
  # pointing at the primary's file. `find -type f` follows the link and reports the
  # target path, so the two roots yield the SAME path and sort -u must collapse it.
  mk_session_in "$root/home/.claude/projects/proj-a" s2
  ln -s "$root/home/.claude/projects/proj-a/s2.jsonl" "$root/home/.claude-ds4/projects/proj-a/s2.jsonl"
  run_dream_autodetect "$root"
  local fdir="$root/autodream/findings/$DATE"
  # Held-out: sigint is flagged and its session is NOT triaged.
  assert_grep "$fdir/unindexed-roots.txt" "$root/home/.claude-sigint/projects" "the undecided sigint dir is flagged"
  assert_nogrep "$fdir/sessions.txt.raw" "$root/home/.claude-sigint/projects/proj-a/s9.jsonl" "the undecided sigint session is NOT triaged"
  # Dedup: the symlinked path appears exactly once in sessions.txt.raw.
  local n; n=$(grep -c "$root/home/.claude/projects/proj-a/s2.jsonl" "$fdir/sessions.txt.raw")
  assert_eq "$n" "1" "the symlinked path appears once in sessions.txt.raw"
  local p; p=$(printf '%s' "$root/home/.claude/projects/proj-a/s2.jsonl" | shasum | cut -c1-12)
  assert_file "$fdir/$p.json" "the one overlapping session has a findings JSON"
  rm -rf "$root"
}

test_multiroot_flags_unindexed(){
  echo "# multi-root: claude dirs that exist but are not indexed are flagged for the report"
  local root; root=$(setup_env_altroot)
  # Third dir, present, not indexed, not in root-choices.conf.
  mkdir -p "$root/home/.claude-sigint/projects/proj-a"
  : > "$root/home/.claude-sigint/projects/proj-a/s9.jsonl"; touch -t "$STAMP" "$root/home/.claude-sigint/projects/proj-a/s9.jsonl"
  mk_session_in "$root/home/.claude/projects/proj-a" s1
  # The ds4 dir (from setup) is also present and undecided.
  mk_session_in "$root/home/.claude-ds4/projects/proj-a" s2
  run_dream_autodetect "$root"
  local flag="$root/autodream/findings/$DATE/unindexed-roots.txt"
  assert_file "$flag" "unindexed-roots.txt written"
  assert_grep "$flag" "$root/home/.claude-sigint/projects" "the sigint dir is named"
  assert_grep "$flag" "$root/home/.claude-ds4/projects" "the ds4 dir is named too"
  assert_nogrep "$flag" "$root/home/.claude/projects" "the primary dir is never flagged"
  # Neither undecided dir is triaged — they're held out until decided.
  assert_nogrep "$root/autodream/findings/$DATE/sessions.txt.raw" "$root/home/.claude-sigint/projects/proj-a/s9.jsonl" "sigint session is not triaged"
  assert_nogrep "$root/autodream/findings/$DATE/sessions.txt.raw" "$root/home/.claude-ds4/projects/proj-a/s2.jsonl" "ds4 session is not triaged"
  rm -rf "$root"
}

# ---- root-probe.sh unit tests (no run.sh) ----
rp(){ AUTODREAM_DIR="$T/ad" HOME="$T/home" "$REPO/bin/root-probe.sh" "$@"; }

test_rootprobe_remembers_choice(){
  echo "# root-probe: --default-index records the choice once and stops re-asking"
  local T; T=$(mktemp -d "${TMPDIR:-/tmp}/ccad.XXXXXX")
  mkdir -p "$T/home/.claude/projects" "$T/home/.claude-ds4/projects" "$T/ad"
  rp --default-index >/dev/null 2>&1
  assert_grep "$T/ad/root-choices.conf" "$T/home/.claude-ds4/projects=index" "unasked alt root recorded as index"
  # Second invocation with a NEW unasked dir: only the new one gets a line.
  mkdir -p "$T/home/.claude-sigint/projects"
  rp --default-index >/dev/null 2>&1
  local n; n=$(grep -c '^.*=index' "$T/ad/root-choices.conf")
  assert_eq "$n" "2" "second run records only the newly-unasked root"
  assert_nogrep "$T/ad/root-choices.conf" "$T/home/.claude-sigint/projects=ignore" "new root not ignored"
  rm -rf "$T"
}

test_rootprobe_no_write_mode_flags_but_does_not_write(){
  echo "# root-probe: nightly mode (no --ask/--default-index) flags but never writes choices"
  local T; T=$(mktemp -d "${TMPDIR:-/tmp}/ccad.XXXXXX")
  mkdir -p "$T/home/.claude/projects" "$T/home/.claude-ds4/projects" "$T/ad"
  rp --unindexed >/dev/null 2>&1 || true
  assert_no_file "$T/ad/root-choices.conf" "no choice file written by a nightly-mode run"
  rm -rf "$T"
}

test_rootprobe_empty_home(){
  echo "# root-probe: a machine with no claude dirs at all must not abort (empty roots, set -u)"
  local T; T=$(mktemp -d "${TMPDIR:-/tmp}/ccad.XXXXXX")
  mkdir -p "$T/home" "$T/ad"
  # Capture the exit code before any `|| true` swallows it.
  local out rc
  out=$(HOME="$T/home" AUTODREAM_DIR="$T/ad" "$REPO/bin/root-probe.sh" --list 2>&1)
  rc=$?
  assert_eq "$rc" "0" "root-probe --list exits 0 with no claude dirs (got $rc)"
  local n; n=$(printf '%s\n' "$out" | grep -c .)
  assert_eq "$n" "0" "no roots are listed (got $n)"
  out=$(HOME="$T/home" AUTODREAM_DIR="$T/ad" "$REPO/bin/root-probe.sh" --consolidated 2>&1)
  rc=$?
  assert_eq "$rc" "0" "root-probe --consolidated exits 0 with no claude dirs (got $rc)"
  rm -rf "$T"
}

# ---- Enumeration transport: a path a line-based artifact cannot hold ----------
# sessions.txt is line-delimited and STAYS that way: the hash assignment in l1_missing_count() and :540 key
# each artifact by sha1 of the whole line, oversized-gate.sh's hash recomputation recomputes
# that same hash from the file, and every archived findings dir depends on it.
# So a path containing a newline cannot be represented, and today it is worse
# than unrepresentable — `find` writes it as two lines and the runner invents a
# second session that does not exist. Reject it at enumeration instead.
test_newline_path_is_rejected_not_split(){
  echo "# enumeration: a path containing a newline is rejected, never split into two"
  local root; root=$(setup_env)
  mk_session "$root" good
  # Some filesystems refuse a newline in a name; if this one does, there is
  # nothing to reject and the test says so rather than passing vacuously.
  local bad; bad=$(printf '%s/projects/proj-a/ba\nd.jsonl' "$root")
  if ! printf '%s\n' '{"type":"user","cwd":"/tmp/proj-a","message":{"content":"x"}}' > "$bad" 2>/dev/null; then
    ok "the filesystem refuses newline filenames; nothing to reject here"
    rm -rf "$root"; return 0
  fi
  touch -t "$STAMP" "$bad"
  run_dream "$root"
  local f; f=$(fdir "$root")
  assert_eq "$(grep -c . "$f/sessions.txt.raw")" "1" "only the representable session is enumerated"
  assert_grep "$f/run-stats.txt" 'sessions_rejected_path: 1' "the rejection is counted in run-stats"
  assert_grep "$root/run.out" 'cannot carry' "the log says why the path was refused"
  rm -rf "$root"
}

# ---- Adapter-aware enumeration: source provenance and the artifact contract ----
# Source is carried in a sidecar keyed by the artifact hash, NOT tagged into
# sessions.txt. Four consumers derive the artifact key or a filesystem path from
# a whole line of that file, so adding a field to it would silently invalidate
# every archived findings dir along with bin/oversized-gate.sh.
test_source_sidecar_is_written(){
  echo "# union: every enumerated session gets a source sidecar line keyed by hash"
  local root; root=$(setup_env)
  mk_session "$root" a
  run_dream "$root"
  local f; f=$(fdir "$root")
  assert_file "$f/sessions-source.txt" "the sidecar exists"
  local sp h
  sp=$(head -1 "$f/sessions.txt")
  h=$(printf '%s' "$sp" | shasum -a 1 | cut -c1-12)
  assert_grep "$f/sessions-source.txt" "^$h	claude$" "the hash maps to its source"
  assert_grep "$f/run-stats.txt" 'sessions_by_source: claude=' "per-source counts are recorded"
  assert_grep "$f/run-stats.txt" 'adapters_enabled: claude' "the enabled adapter set is recorded"
  rm -rf "$root"
}

test_artifact_hash_contract_is_unchanged(){
  echo "# union: the artifact key is still sha1 of the bare path, so archived dirs keep working"
  local root; root=$(setup_env)
  mk_session "$root" a
  run_dream "$root"
  local f; f=$(fdir "$root")
  local sp h
  sp=$(head -1 "$f/sessions.txt")
  h=$(printf '%s' "$sp" | shasum -a 1 | cut -c1-12)
  assert_file "$f/$h.json" "the findings record is keyed by sha1 of the bare path"
  # A tab in sessions.txt would mean the line stopped being a bare path, which is
  # the change that breaks oversized-gate.sh's hash recomputation and every archived dir.
  assert_nogrep "$f/sessions.txt" '	' "sessions.txt carries no tab-delimited fields"
  rm -rf "$root"
}

test_preflight_stops_a_run_missing_a_dependency(){
  echo "# preflight: a missing shared dependency stops the run before anything is enumerated"
  local root; root=$(setup_env)
  mk_session "$root" a
  # An empty PATH dir hides shasum, whose absence silently empties the artifact
  # hash so every session in the night targets one findings filename.
  local empty; empty=$(mktemp -d "${TMPDIR:-/tmp}/nopath.XXXXXX")
  PATH="$empty:/usr/bin:/bin" AUTODREAM_CHANGELOG=0 CLAUDE_BIN="$MOCK"     AUTODREAM_CONFIG="$root/autodream/config" AUTODREAM_CONSUME_DATE="$DATE"     AUTODREAM_NETCHECK=0 AUTODREAM_RETRY_WAIT=0 AUTODREAM_L1_ROUNDS=1     AUTODREAM_PREFLIGHT_FORCE_MISSING=shasum     PROJECTS_DIR="$root/projects" AUTODREAM_DIR="$root/autodream" DREAMS_DIR="$root/dreams"     bash "$RUN" "$DATE" > "$root/run.out" 2>&1 || true
  cat "$root/autodream/logs/run-$DATE.log" >> "$root/run.out" 2>/dev/null || true
  assert_no_file "$(fdir "$root")/sessions.txt" "nothing was enumerated"
  assert_grep "$root/run.out" 'preflight' "the log says preflight stopped it"
  rm -rf "$root" "$empty"
}

# ---- The installed tree must actually contain the adapter runtime ----------
# install.sh has an EXPLICIT link list. The first version of the adapter change
# added four new runtime files and none of them to that list, so every
# documented nightly install would have silently taken the legacy enumeration
# path with no preflight — while still printing adapters_enabled: claude. It
# ships broken to the only place that matters and reports success, which is the
# exact failure shape this repo already has a memory note about.
test_install_deploys_the_adapter_runtime(){
  # SIDE EFFECT, deliberate and pre-existing: install.sh's chmod +x step runs
  # `chmod +x "$REPO_DIR/bin/"*.sh`, so this test makes every bin script
  # executable in the working tree. That is the repo's own convention, but it
  # means a `git stash` taken across a suite run can refuse to pop on a bare
  # mode change. Restore with `git checkout -- bin/` if that happens.
  echo "# install: the adapter runtime is installed, not just committed"
  local T; T=$(mktemp -d "${TMPDIR:-/tmp}/ccad.XXXXXX")
  mkdir -p "$T/home"
  HOME="$T/home" AUTODREAM_DIR="$T/home/.claude/autodream" \
    bash "$REPO/install.sh" --no-schedule > "$T/install.out" 2>&1 || true
  local target="$T/home/.claude/autodream"
  assert_file "$target/lib-project.sh" "lib-project.sh is installed"
  assert_file "$target/adapters.sh"    "adapters.sh is installed"
  assert_file "$target/preflight.sh"   "preflight.sh is installed"
  [ -e "$target/adapters/claude/adapter.sh" ] \
    && ok "the adapters tree is reachable from the install target" \
    || no "the adapters tree is reachable from the install target"
  # And the installed runner must resolve its adapters through the FLAT layout,
  # where adapters/ sits beside adapters.sh rather than one level up.
  local got
  got=$(cd "$target" && bash -c '. ./adapters.sh; adapters_list' 2>/dev/null)
  assert_eq "$got" "claude" "the installed runner resolves the claude adapter"
  # Resolving the adapter is not the same as being able to RUN it. The installed
  # adapter finds its helper scripts through a relative path, so exercise a
  # subcommand that actually shells out to one rather than stopping at discovery.
  local sess="$T/s.jsonl" out="$T/s.stats.json"
  mkdir -p "$T/proj"
  printf '%s\n' "{\"type\":\"user\",\"cwd\":\"$T/proj\",\"message\":{\"content\":\"x\"}}" > "$sess"
  if "$target/adapters/claude/adapter.sh" stats "$sess" "$out" 2>/dev/null && [ -s "$out" ]; then
    ok "an installed adapter subcommand reaches its helper scripts"
  else
    no "an installed adapter subcommand reaches its helper scripts"
  fi
  assert_eq "$("$target/adapters/claude/adapter.sh" project "$sess" 2>/dev/null)" \
            "$(cd "$T/proj" && pwd -P)" "the installed adapter resolves a project cwd"
  rm -rf "$T"
}

# ---- Characters the artifact list or the L1 fan-out cannot carry -----------
# Verified on this host against the real consumer rather than assumed: with
# `xargs -I {}` a tab becomes a space, a backslash is deleted, and a quote kills
# the whole dispatch with "unterminated quote". An earlier draft accepted tabs
# because sessions.txt and the hash tolerate them — those two consumers were
# checked and the fan-out was not.
test_unrepresentable_characters_are_refused(){
  echo "# enumeration: characters the fan-out would corrupt are refused, not accepted"
  local root; root=$(setup_env)
  mk_session "$root" good
  local n=0 p
  local -a bads
  bads=( "$(printf 'ta\tb')" 'back\slash' 'quo"te' )
  local bad
  for bad in "${bads[@]}"; do
    p="$root/projects/proj-a/$bad.jsonl"
    printf '%s\n' '{"type":"user","cwd":"/tmp/proj-a","message":{"content":"x"}}' > "$p" 2>/dev/null || continue
    touch -t "$STAMP" "$p" 2>/dev/null || continue
    n=$((n + 1))
  done
  if [ "$n" -eq 0 ]; then ok "the filesystem refuses these names; nothing to test"; rm -rf "$root"; return 0; fi
  run_dream "$root"
  local f; f=$(fdir "$root")
  assert_eq "$(grep -c . "$f/sessions.txt.raw")" "1" "only the representable session survives enumeration"
  assert_grep "$f/run-stats.txt" "sessions_rejected_path: $n" "every refusal is counted"
  # The whole point: the run still completes. A quoted path used to abort the
  # entire xargs fan-out rather than skipping one session.
  assert_nonempty "$root/dreams/$DATE.md" "the run still produced a report"
  rm -rf "$root"
}

# ---- A failing enumerator must abort, not report over an unread corpus -------
# This is the test whose ABSENCE let 306 assertions pass over a broken fix. The
# runner staged enumeration to a file and checked its exit status, but the
# enumerate_for wrapper ended in a literal `return 0`, so the check received
# success every time. Nothing exercised an adapter whose enumerate fails, so
# nothing noticed. A run that cannot read its corpus must fail loudly rather
# than finalise a cheerful "no sessions" report.
test_failing_enumerator_aborts_the_run(){
  echo "# enumeration: an adapter whose enumerate fails costs its root, not the night"
  local root; root=$(setup_env)
  mk_session "$root" a
  # A private adapters tree holding one adapter that always fails to enumerate.
  local ad="$root/adapters"; mkdir -p "$ad/claude"
  printf '{"name":"claude","engine_bin":"true","writes_memory":true}\n' > "$ad/claude/manifest.json"
  printf '#!/bin/bash\ncase "${1:-}" in enumerate) exit 3 ;; *) exit 2 ;; esac\n' > "$ad/claude/adapter.sh"
  chmod +x "$ad/claude/adapter.sh"
  ADAPTERS_ROOT="$ad" AUTODREAM_CHANGELOG=0 CLAUDE_BIN="$MOCK" \
    AUTODREAM_CONFIG="$root/autodream/config" AUTODREAM_CONSUME_DATE="$DATE" \
    AUTODREAM_NETCHECK=0 AUTODREAM_RETRY_WAIT=0 AUTODREAM_L1_ROUNDS=1 \
    PROJECTS_DIR="$root/projects" AUTODREAM_DIR="$root/autodream" DREAMS_DIR="$root/dreams" \
    bash "$RUN" "$DATE" > "$root/run.out" 2>&1
  local rc=$?
  cat "$root/autodream/logs/run-$DATE.log" >> "$root/run.out" 2>/dev/null || true
  # This used to assert the run ABORTS. It no longer does, and the change was
  # deliberate: on a single-root host — the default install — "enumerator exited
  # nonzero and returned nothing" is also the shape of a quiet date plus a
  # transient find error, so aborting cost a night whose honest answer was the
  # empty-night stub. What replaced the abort is a refusal to LIE: the run
  # completes, roots_failed counts it, and the stub says the store was not fully
  # read rather than claiming no files were modified.
  assert_eq "$rc" "0" "the run completes rather than losing the night"
  assert_grep "$root/run.out" 'contributes NO sessions' "the log names the enumeration failure"
  assert_grep "$root/autodream/findings/$DATE/run-stats.txt" '^roots_failed: 1$' \
    "roots_failed records it"
  assert_grep "$root/dreams/$DATE.md" 'did not read the whole store' \
    "the report refuses to call this an empty night"
  assert_nogrep "$root/dreams/$DATE.md" 'No session files were modified' \
    "and does not state the claim it cannot support"
  rm -rf "$root"
}

# ---- One bad root must not take the night with it --------------------------
# find exits 1 for ANY unreadable directory in the walk, match or no match —
# verified on this host: an unreadable sibling makes it exit 1 both with and
# without matches, and exit 0 without one. A secondary root legitimately matches
# nothing on a given date, so treating "nonzero exit, no output" as fatal for the
# whole run meant one permission-denied directory under a quiet secondary root
# killed a night on which the primary had a full corpus — and killed it
# invisibly, because run() returned before notify.sh and no findings JSONs
# existed for unassembled_dates() to see.
test_one_failed_root_does_not_kill_the_night(){
  echo "# roots: one root that fails to enumerate does not discard the roots that worked"
  local root; root=$(setup_env)
  mk_session "$root" a
  # A second root that exists, holds no matching file, and contains a directory
  # find cannot read. That combination is exit 1 with empty output.
  local bad="$root/badroot"; mkdir -p "$bad/locked"
  chmod 000 "$bad/locked"
  SESSION_ROOTS="$root/projects:$bad" AUTODREAM_CHANGELOG=0 CLAUDE_BIN="$MOCK" \
    AUTODREAM_CONFIG="$root/autodream/config" AUTODREAM_CONSUME_DATE="$DATE" \
    AUTODREAM_NETCHECK=0 AUTODREAM_RETRY_WAIT=0 AUTODREAM_L1_ROUNDS=1 \
    AUTODREAM_DIR="$root/autodream" DREAMS_DIR="$root/dreams" \
    bash "$RUN" "$DATE" > "$root/run.out" 2>&1
  local rc=$?
  chmod 755 "$bad/locked"
  cat "$root/autodream/logs/run-$DATE.log" >> "$root/run.out" 2>/dev/null || true
  assert_eq "$rc" "0" "the run survives one failed root"
  assert_nonempty "$root/dreams/$DATE.md" "the healthy root's corpus still produced a report"
  assert_grep "$root/run.out" 'contributes NO sessions' "the failed root is named in the log"
  assert_grep "$root/autodream/findings/$DATE/run-stats.txt" '^roots_failed: 1$' \
    "roots_failed counts it, so a shrinking corpus is visible rather than silent"
  rm -rf "$root"
}

# ---- A corpus that exists but yields nothing is not an empty night ----------
# COUNT=0 has three distinct causes and they used to read identically: no files
# at all, every file an autodream worker transcript, or every file an empty
# shell. The stub said "No session files were modified" for all three, and the
# zero-session run-stats omitted the two counters that would have said otherwise.
test_all_excluded_corpus_says_so(){
  echo "# zero sessions: an all-excluded corpus reports why, not 'nothing was modified'"
  local root; root=$(setup_env)
  # One autodream worker transcript, nothing else. RAW is 1, COUNT is 0.
  local f="$root/projects/proj-a/worker.jsonl"
  printf '%s\n' '{"type":"user","message":{"content":"Session transcript to analyze (literal absolute path): /x"}}' > "$f"
  touch -t "$STAMP" "$f"
  run_dream "$root"
  local d; d=$(fdir "$root")
  assert_file "$d/run-stats.txt" "run-stats is written for a zero-session night"
  assert_grep "$d/run-stats.txt" 'self_sessions_excluded: 1' "the self-exclusion is counted"
  assert_grep "$d/run-stats.txt" 'sessions_found_raw: 1' "the raw count shows a file WAS there"
  assert_nogrep "$root/dreams/$DATE.md" 'No session files were modified' "the stub does not claim an empty night"
  assert_grep "$root/dreams/$DATE.md" 'autodream-own' "the stub names why nothing was triaged"
  rm -rf "$root"
}

# ---- A PARTIAL enumeration must not throw away the corpus it did read -------
# The existing failing-enumerator test uses an adapter that returns NOTHING, so
# it would pass under the old fatal-on-any-nonzero code too — it could not tell
# the regression from the fix. This one is the actual case: BSD find exits 1 when
# one subdirectory is unreadable or vanishes mid-walk WHILE still printing every
# other match. Treating that as fatal produced no report on a night the old code
# reported in full, which is worse than the silent zero the check exists to catch.
test_partial_enumeration_keeps_what_it_read(){
  echo "# enumeration: an enumerator that returns data AND fails continues, loudly"
  local root; root=$(setup_env)
  mk_session "$root" a
  local sess="$root/projects/proj-a/a.jsonl"
  local ad="$root/adapters"; mkdir -p "$ad/claude"
  printf '{"name":"claude","engine_bin":"true","writes_memory":true}\n' > "$ad/claude/manifest.json"
  # Emits one real NUL-delimited path, then exits nonzero — exactly find's shape.
  { printf '#!/bin/bash\n'
    printf 'case "${1:-}" in\n'
    printf '  enumerate) printf "%%s\\0" "%s"; exit 1 ;;\n' "$sess"
    printf '  project) printf "/tmp/proj-a" ;;\n'
    printf '  memory-root) cd "$(dirname "$2")/../.." 2>/dev/null && pwd -P ;;\n'
    printf '  normalize|slim) cp "$2" "$3" ;;\n'
    printf '  stats) "%s/bin/session-stats.sh" "$2" "$3" ;;\n' "$REPO"
    printf '  is-self) exit 1 ;;\n'
    printf '  *) exit 2 ;;\n'
    printf 'esac\n'
  } > "$ad/claude/adapter.sh"
  chmod +x "$ad/claude/adapter.sh"
  ADAPTERS_ROOT="$ad" AUTODREAM_CHANGELOG=0 CLAUDE_BIN="$MOCK" \
    AUTODREAM_CONFIG="$root/autodream/config" AUTODREAM_CONSUME_DATE="$DATE" \
    AUTODREAM_NETCHECK=0 AUTODREAM_RETRY_WAIT=0 AUTODREAM_L1_ROUNDS=1 \
    PROJECTS_DIR="$root/projects" AUTODREAM_DIR="$root/autodream" DREAMS_DIR="$root/dreams" \
    bash "$RUN" "$DATE" > "$root/run.out" 2>&1
  local rc=$?
  cat "$root/autodream/logs/run-$DATE.log" >> "$root/run.out" 2>/dev/null || true
  local d; d=$(fdir "$root")
  assert_eq "$rc" "0" "the run completes despite the enumerator failing"
  assert_grep "$root/run.out" 'INCOMPLETE' "the log warns the corpus may be short"
  assert_grep "$d/run-stats.txt" 'roots_partially_enumerated: 1' "the partial walk is counted"
  assert_grep "$d/sessions.txt.raw" 'a.jsonl' "the path it DID return was kept"
  assert_nonempty "$root/dreams/$DATE.md" "a report is still produced"
  rm -rf "$root"
}

# ---- Every configured root unreachable is a failure, not a quiet night ------
# scan_roots warned and skipped a non-directory root, so a broken SESSION_ROOTS
# or a vanished store produced RAW=0 with every shortfall counter at 0 and a
# stub saying no files were modified. A fresh host with NO roots configured is a
# different thing and must stay legitimate.
test_all_roots_unavailable_fails(){
  echo "# roots: all configured roots unreachable fails rather than reporting empty"
  local root; root=$(setup_env)
  mk_session "$root" a
  SESSION_ROOTS="$root/does-not-exist-a:$root/does-not-exist-b" \
    AUTODREAM_CHANGELOG=0 CLAUDE_BIN="$MOCK" \
    AUTODREAM_CONFIG="$root/autodream/config" AUTODREAM_CONSUME_DATE="$DATE" \
    AUTODREAM_NETCHECK=0 AUTODREAM_RETRY_WAIT=0 AUTODREAM_L1_ROUNDS=1 \
    AUTODREAM_DIR="$root/autodream" DREAMS_DIR="$root/dreams" \
    bash "$RUN" "$DATE" > "$root/run.out" 2>&1
  local rc=$?
  cat "$root/autodream/logs/run-$DATE.log" >> "$root/run.out" 2>/dev/null || true
  assert_eq "$rc" "1" "the run fails when no configured root is reachable"
  assert_grep "$root/run.out" 'all .* configured session root' "the log names the cause"
  assert_no_file "$root/dreams/$DATE.md" "no empty-night report is written"
  rm -rf "$root"
}

# ---- A fresh host with no store is a quiet night, not a failure -------------
# probe_roots falls back to $HOME/.claude/projects when discovery finds nothing.
# The all-roots-unavailable fatal counted that fallback as a configured root and
# aborted, so a machine that has simply never run Claude Code failed instead of
# reporting an empty night. The fatal must fire only on roots someone actually
# asked for.
test_fresh_host_with_no_store_is_not_a_failure(){
  echo "# roots: a fresh host with no session store reports empty, it does not fail"
  local T; T=$(mktemp -d "${TMPDIR:-/tmp}/ccad.XXXXXX")
  mkdir -p "$T/home" "$T/autodream" "$T/dreams"
  cp "$REPO/prompts/SESSION_TRIAGE.md" "$T/autodream/SESSION_TRIAGE.md"
  cp "$REPO/prompts/PROMPT.md"         "$T/autodream/PROMPT.md"
  # No SESSION_ROOTS, no PROJECTS_DIR, and a HOME with no .claude at all.
  HOME="$T/home" AUTODREAM_CHANGELOG=0 CLAUDE_BIN="$MOCK" \
    AUTODREAM_CONFIG="$T/autodream/config" AUTODREAM_CONSUME_DATE="$DATE" \
    AUTODREAM_NETCHECK=0 AUTODREAM_RETRY_WAIT=0 AUTODREAM_L1_ROUNDS=1 \
    AUTODREAM_DIR="$T/autodream" DREAMS_DIR="$T/dreams" \
    bash "$RUN" "$DATE" > "$T/run.out" 2>&1
  local rc=$?
  cat "$T/autodream/logs/run-$DATE.log" >> "$T/run.out" 2>/dev/null || true
  assert_eq "$rc" "0" "a fresh host exits 0"
  assert_nonempty "$T/dreams/$DATE.md" "a fresh host still gets a report"
  assert_nogrep "$T/run.out" 'configured session root' "no all-roots-unavailable fatal fires"
  rm -rf "$T"
}

# ---- A fatal must not vandalise a date that already succeeded ---------------
# fatal_exit truncates run-stats.txt and posts a FAILED banner. AUTODREAM_FORCE
# bypasses the idempotency guard by design — it is the documented
# `autodream-now.sh <date> --force` path — so any fatal under it would overwrite
# that date's full L1/L2 telemetry with a five-line stub and announce a failure
# for a night whose report is sitting right there. unassembled_dates() would not
# catch it either, because the report exists.
test_fatal_does_not_clobber_a_complete_date(){
  echo "# fatal: a forced rerun that dies leaves the completed date's stats alone"
  local root; root=$(setup_env)
  mk_session "$root" a
  local env_common=(AUTODREAM_CHANGELOG=0 AUTODREAM_NETCHECK=0
                    AUTODREAM_RETRY_WAIT=0 AUTODREAM_L1_ROUNDS=1)
  # A good night first.
  env "${env_common[@]}" CLAUDE_BIN="$MOCK" AUTODREAM_CONFIG="$root/autodream/config" \
    AUTODREAM_CONSUME_DATE="$DATE" PROJECTS_DIR="$root/projects" \
    AUTODREAM_DIR="$root/autodream" DREAMS_DIR="$root/dreams" \
    bash "$RUN" "$DATE" > "$root/run1.out" 2>&1
  assert_nonempty "$root/dreams/$DATE.md" "the first run produced a report"
  local before; before=$(wc -l < "$root/autodream/findings/$DATE/run-stats.txt" | tr -d ' ')
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/notify-args.txt"\n' "$root" \
    > "$root/autodream/notify.sh"
  chmod +x "$root/autodream/notify.sh"
  # Now force a rerun that dies: every configured root unavailable.
  env "${env_common[@]}" CLAUDE_BIN="$MOCK" AUTODREAM_CONFIG="$root/autodream/config" \
    AUTODREAM_CONSUME_DATE="$DATE" AUTODREAM_FORCE=1 \
    SESSION_ROOTS="$root/gone-a:$root/gone-b" \
    AUTODREAM_DIR="$root/autodream" DREAMS_DIR="$root/dreams" \
    bash "$RUN" "$DATE" > "$root/run2.out" 2>&1
  local after; after=$(wc -l < "$root/autodream/findings/$DATE/run-stats.txt" | tr -d ' ')
  assert_eq "$after" "$before" "the completed date's run-stats.txt is untouched"
  assert_grep "$root/autodream/findings/$DATE/run-stats.txt" '^sessions_triaged: [1-9]' \
    "and still carries the real triage count, not a stub zero"
  # The banner MUST still fire. An earlier version of this test asserted the
  # opposite and passed, which is how the guard came to suppress it: the run-stats
  # write is what must not clobber a complete date, and the banner got taken down
  # with it by being inside the same `return`. This branch is reachable only under
  # AUTODREAM_FORCE, i.e. `autodream-now.sh <date> --force`, which runs detached
  # under launchd — where a silent death leaves the operator polling
  # dreams/<date>.md, finding the OLD report, and reading the failed rebuild as a
  # success.
  assert_file "$root/notify-args.txt" \
    "a failed --force rebuild still posts a banner even though the date has a report"
  assert_grep "$root/notify-args.txt" '[-][-]failure' "and posts it in failure mode"
  assert_grep "$root/notify-args.txt" 'existing report' \
    "and says the standing report is the OLD one, not this run's output"
  rm -rf "$root"
}

# ---- A total outage must leave a trace ------------------------------------
# adapters/claude/adapter.sh losing its exec bit is a mundane accident — a
# tarball copy, a restrictive umask, core.fileMode=false — and _adapter_ok
# demands -x. The loader then accepts nothing, scan_roots goes fatal, and run()
# returns ~600 lines before notify.sh with no findings JSON and no run-stats.txt.
# A host that reported fine last night reports nothing, every night, and the only
# record is a log line nobody reads.
test_no_usable_adapter_leaves_a_trace(){
  echo "# adapters: a total outage writes a fatal marker the next night can see"
  local root; root=$(setup_env)
  mk_session "$root" a
  local ad="$root/adapters"; mkdir -p "$ad/claude"
  printf '{"name":"claude","engine_bin":"true","writes_memory":true}\n' > "$ad/claude/manifest.json"
  cp "$REPO/adapters/claude/adapter.sh" "$ad/claude/adapter.sh"
  chmod -x "$ad/claude/adapter.sh"          # the whole trigger
  # A notify.sh that records how it was called. fatal_exit gates on -x, so without
  # one installed the failure-notification step is skipped and unobservable.
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/notify-args.txt"\n' "$root" \
    > "$root/autodream/notify.sh"
  chmod +x "$root/autodream/notify.sh"
  ADAPTERS_ROOT="$ad" AUTODREAM_CHANGELOG=0 CLAUDE_BIN="$MOCK" \
    AUTODREAM_CONFIG="$root/autodream/config" AUTODREAM_CONSUME_DATE="$DATE" \
    AUTODREAM_NETCHECK=0 AUTODREAM_RETRY_WAIT=0 AUTODREAM_L1_ROUNDS=1 \
    PROJECTS_DIR="$root/projects" AUTODREAM_DIR="$root/autodream" DREAMS_DIR="$root/dreams" \
    bash "$RUN" "$DATE" > "$root/run.out" 2>&1
  local rc=$?
  assert_eq "$rc" "1" "the run still refuses to scan"
  assert_grep "$root/autodream/findings/$DATE/run-stats.txt" '^fatal: ' \
    "a fatal marker is left behind rather than nothing at all"
  # The marker alone is not enough for a PERSISTENT cause. A lost exec bit repeats
  # every night, so no later run ever succeeds to read the marker and report it —
  # the surface that works tonight is the banner. The stub records its arguments.
  assert_file "$root/notify-args.txt" "notify.sh was invoked on the fatal path"
  # Bracket the dashes. assert_grep takes (file, pattern, message) and passes the
  # pattern straight to grep, so a literal `--failure` reads as end-of-options and
  # an inserted `--` becomes the pattern — which is what the first version did.
  assert_grep "$root/notify-args.txt" '[-][-]failure' "and invoked in failure mode"
  assert_grep "$root/notify-args.txt" "$DATE" "naming the date that died"
  # And the next night must surface it. Run a LATER date and check it names this one.
  local later=2020-01-03
  mk_session_dated "$root" b "$later" 2>/dev/null || true
  chmod +x "$ad/claude/adapter.sh"
  ADAPTERS_ROOT="$ad" AUTODREAM_CHANGELOG=0 CLAUDE_BIN="$MOCK" \
    AUTODREAM_CONFIG="$root/autodream/config" AUTODREAM_CONSUME_DATE="$later" \
    AUTODREAM_NETCHECK=0 AUTODREAM_RETRY_WAIT=0 AUTODREAM_L1_ROUNDS=1 \
    PROJECTS_DIR="$root/projects" AUTODREAM_DIR="$root/autodream" DREAMS_DIR="$root/dreams" \
    bash "$RUN" "$later" > "$root/run2.out" 2>&1
  cat "$root/autodream/logs/run-$later.log" >> "$root/run2.out" 2>/dev/null || true
  assert_grep "$root/run2.out" "$DATE" "the next night's run names the date that died"
  rm -rf "$root"
}

# ---- The adapter set is resolved once, not once per caller ------------------
# The first attempt at this was a memoised enabled_adapters that every caller
# invoked as $(enabled_adapters), so the cache assignment died with the subshell
# and the loader re-ran on every call — the exact trap adapters.sh's header
# documents.
#
# What this test pins is the user-visible shape: the not-adapter-aware warning
# appears once. It does NOT discriminate against that subshell bug — checked, by
# restoring the broken memo and re-running, and it still passed. The bug is a
# repeated INVOCATION, and the second invocation happens on a path whose warning
# does not reach the log a second time, so no assertion over log content can see
# it. Measuring it needs the function instrumented, which a test cannot do to a
# script it invokes rather than sources; it was measured that way by hand
# instead — 2 invocations before the fix, 1 after.
#
# Left in because the warning multiplying IS worth pinning, and said plainly so
# the next reader does not mistake this for coverage of the subshell trap.
test_enabled_adapters_resolves_once(){
  echo "# adapters: a second installed adapter warns once per run, not once per caller"
  local root; root=$(setup_env)
  mk_session "$root" a
  local ad="$root/adapters"
  mkdir -p "$ad/claude" "$ad/other"
  printf '{"name":"claude","engine_bin":"true","writes_memory":true}\n' > "$ad/claude/manifest.json"
  cp "$REPO/adapters/claude/adapter.sh" "$ad/claude/adapter.sh"
  chmod +x "$ad/claude/adapter.sh"
  printf '{"name":"other","engine_bin":"true","writes_memory":false}\n' > "$ad/other/manifest.json"
  printf '#!/bin/bash\nexit 2\n' > "$ad/other/adapter.sh"; chmod +x "$ad/other/adapter.sh"
  ADAPTERS_ROOT="$ad" AUTODREAM_CHANGELOG=0 CLAUDE_BIN="$MOCK" \
    AUTODREAM_CONFIG="$root/autodream/config" AUTODREAM_CONSUME_DATE="$DATE" \
    AUTODREAM_NETCHECK=0 AUTODREAM_RETRY_WAIT=0 AUTODREAM_L1_ROUNDS=1 \
    PROJECTS_DIR="$root/projects" AUTODREAM_DIR="$root/autodream" DREAMS_DIR="$root/dreams" \
    bash "$RUN" "$DATE" > "$root/run.out" 2>&1
  cat "$root/autodream/logs/run-$DATE.log" >> "$root/run.out" 2>/dev/null || true
  local n
  n=$(grep -c "is enabled but per-session dispatch" "$root/run.out" 2>/dev/null || true)
  n=${n:-0}
  assert_eq "$n" "1" "the not-adapter-aware warning is emitted exactly once"
  assert_nonempty "$root/dreams/$DATE.md" "the run still produced a report"
  rm -rf "$root"
}

# ---- Upgrade lag: run.sh is a symlink, the libraries are not there yet -------
# The live install symlinks each script individually into ~/.claude/autodream, so
# merging a branch changes run.sh the instant it lands while lib-project.sh,
# adapters.sh, preflight.sh and adapters/ only appear when install.sh is re-run.
# Every other test invokes $REPO/bin/run.sh directly, where the libraries sit
# right beside it, so 358 green assertions all ran with them present and none of
# them exercised the shape the nightly actually has.
test_upgrade_lag_install_still_produces_a_report(){
  echo "# upgrade lag: run.sh symlinked into an install dir with no libraries still reports"
  local T; T=$(mktemp -d "${TMPDIR:-/tmp}/ccad.XXXXXX")
  mkdir -p "$T/home/.claude/projects/proj-a" "$T/autodream" "$T/dreams"
  cp "$REPO/prompts/SESSION_TRIAGE.md" "$T/autodream/SESSION_TRIAGE.md"
  cp "$REPO/prompts/PROMPT.md"         "$T/autodream/PROMPT.md"
  # Exactly what a pre-adapter install left behind: the helper scripts, and
  # run.sh as a symlink into the repo. Deliberately NOT lib-project.sh,
  # adapters.sh, preflight.sh or adapters/.
  local h
  for h in prune-self-sessions.sh root-probe.sh slim-transcript.sh session-stats.sh \
           overlap-stats.sh vault-notes.sh x-bookmarks.sh notify.sh; do
    [ -f "$REPO/bin/$h" ] && ln -s "$REPO/bin/$h" "$T/autodream/$h"
  done
  ln -s "$REPO/bin/run.sh" "$T/autodream/run.sh"
  mk_session_in "$T/home/.claude/projects/proj-a" s1
  HOME="$T/home" AUTODREAM_CHANGELOG=0 CLAUDE_BIN="$MOCK" \
    AUTODREAM_CONFIG="$T/autodream/config" AUTODREAM_CONSUME_DATE="$DATE" \
    AUTODREAM_NETCHECK=0 AUTODREAM_RETRY_WAIT=0 AUTODREAM_L1_ROUNDS=1 \
    AUTODREAM_DIR="$T/autodream" DREAMS_DIR="$T/dreams" \
    bash "$T/autodream/run.sh" "$DATE" > "$T/run.out" 2>&1
  local rc=$?
  cat "$T/autodream/logs/run-$DATE.log" >> "$T/run.out" 2>/dev/null || true
  assert_eq "$rc" "0" "a symlinked runner with no installed libraries exits 0"
  assert_nogrep "$T/run.out" 'session_hash: command not found' "session_hash resolved"
  assert_nonempty "$T/dreams/$DATE.md" "the upgrade-lag install still produced a report"
  rm -rf "$T"
}

# ---- Forced hash collision: the branch four review rounds kept touching -----
# A natural 48-bit collision cannot be produced in a test, so the hash is stubbed:
# a fake `shasum` returning a constant makes every session collide. Without this,
# every assertion passes whether the collision handling works or not — which is
# exactly what happened while this branch was patched across four review rounds.
#
# The stub goes in $HOME/.local/bin because run.sh hard-overrides PATH to a fixed
# list ("$HOME/.cargo/bin:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:...").
# A stub anywhere else is simply not seen — the first version of this test put it
# in a temp dir on PATH and silently measured nothing.
collision_sandbox(){ # -> a root whose HOME holds a constant-hash shasum stub
  local root; root=$(setup_env)
  mkdir -p "$root/home/.local/bin"
  printf '#!/bin/bash\ncat >/dev/null 2>&1\nprintf "%%s  -\\n" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"\n' \
    > "$root/home/.local/bin/shasum"
  chmod +x "$root/home/.local/bin/shasum"
  printf '%s' "$root"
}
run_dream_collision(){ # $1=root
  HOME="$1/home" AUTODREAM_CHANGELOG=0 CLAUDE_BIN="$MOCK" \
    AUTODREAM_CONFIG="$1/autodream/config" AUTODREAM_CONSUME_DATE="$DATE" \
    AUTODREAM_NETCHECK=0 AUTODREAM_RETRY_WAIT=0 AUTODREAM_L1_ROUNDS=1 \
    PROJECTS_DIR="$1/projects" AUTODREAM_DIR="$1/autodream" DREAMS_DIR="$1/dreams" \
    bash "$RUN" "$DATE" > "$1/run.out" 2>&1
  local rc=$?
  cat "$1/autodream/logs/run-$DATE.log" >> "$1/run.out" 2>/dev/null || true
  return $rc
}

test_forced_hash_collision_drops_both(){
  echo "# collision: two paths on one hash drop BOTH and never reach dispatch"
  local root; root=$(collision_sandbox)
  mk_session "$root" one
  mk_session "$root" two
  run_dream_collision "$root"
  local rc=$?
  local d; d=$(fdir "$root")
  assert_eq "$rc" "0" "a handled collision is not a run failure"
  assert_grep "$root/run.out" 'COLLISION' "the collision is detected and logged"
  # The design requires this explicitly: neither session may reach the artifact
  # they would have shared. Asserting the counters without asserting this would
  # have let the drop be bookkeeping only.
  assert_no_file "$d/aaaaaaaaaaaa.json" "the shared artifact is never written"
  assert_no_file "$d/aaaaaaaaaaaa.stats.json" "nor its stats sidecar"
  assert_grep "$d/run-stats.txt" 'sessions_found_raw: 2' "RAW still reports what was ENUMERATED"
  assert_grep "$d/run-stats.txt" 'sessions_dropped_to_collision: 2' "both dropped paths are counted"
  assert_grep "$d/run-stats.txt" 'self_sessions_excluded: 0' "collided files are NOT called autodream-own"
  assert_grep "$d/run-stats.txt" 'sessions_hash_collision: 1' "the collision is counted"
  # BOTH paths gone. This is the assertion that would have caught the branch
  # logging "skipping both" while skipping neither.
  assert_eq "$(grep -c . "$d/sessions.txt.raw" 2>/dev/null || true)" "0" \
    "both colliding paths are removed from the worklist"
  assert_eq "$(grep -c . "$d/sessions-source.txt" 2>/dev/null || true)" "0" \
    "no provenance row survives for a dropped session"
  rm -rf "$root"
}

test_collision_worklist_failure_aborts(){
  echo "# collision: a worklist rewrite that cannot happen fails closed"
  local root; root=$(collision_sandbox)
  mk_session "$root" one
  mk_session "$root" two
  # A grep that answers the membership probe normally so detection still runs,
  # then fails hard on the -vxF worklist rewrite — the path that must abort
  # rather than dispatch two sessions onto one artifact.
  { printf '#!/bin/bash\n'
    printf 'for a in "$@"; do case "$a" in -vxF) exit 2 ;; esac; done\n'
    printf 'exec /usr/bin/grep "$@"\n'
  } > "$root/home/.local/bin/grep"
  chmod +x "$root/home/.local/bin/grep"
  run_dream_collision "$root"
  local rc=$?
  assert_eq "$rc" "1" "the run fails closed when the worklist cannot be rewritten"
  assert_grep "$root/run.out" 'refusing to dispatch two sessions onto one artifact' \
    "the log says why it refused"
  assert_no_file "$root/dreams/$DATE.md" "no report is produced over a corrupted worklist"
  rm -rf "$root"
}

test_collision_membership_probe_failure_aborts(){
  echo "# collision: a failing membership probe fails closed, it does not skip the row"
  local root; root=$(collision_sandbox)
  mk_session "$root" one
  mk_session "$root" two
  # Fail ONLY the -qxF membership probe. The previous fixture failed the -vxF
  # rewrite instead, so reverting the probe to `|| continue` would have left the
  # whole suite green — a fail-open on the way IN to the check that fails closed
  # on the way out.
  { printf '#!/bin/bash\n'
    printf 'for a in "$@"; do case "$a" in -qxF) exit 2 ;; esac; done\n'
    printf 'exec /usr/bin/grep "$@"\n'
  } > "$root/home/.local/bin/grep"
  chmod +x "$root/home/.local/bin/grep"
  run_dream_collision "$root"
  local rc=$?
  assert_eq "$rc" "1" "the run fails closed when the membership probe errors"
  assert_grep "$root/run.out" 'refusing to build provenance over an unreadable list' \
    "the log names the unreadable worklist"
  assert_no_file "$root/dreams/$DATE.md" "no report is produced"
  rm -rf "$root"
}

test_three_way_collision_counts_paths_not_lines(){
  echo "# collision: three paths on one hash count as three drops, not four"
  local root; root=$(collision_sandbox)
  mk_session "$root" one
  mk_session "$root" two
  mk_session "$root" three
  run_dream_collision "$root"
  local d; d=$(fdir "$root")
  # The earlier path is re-appended for every LATER collision, so the drop file
  # reads A,B,A,C for three paths. Counting lines reported four drops for three.
  assert_grep "$d/run-stats.txt" 'sessions_dropped_to_collision: 3' "three paths count as three"
  assert_grep "$d/run-stats.txt" 'sessions_found_raw: 3' "and all three were enumerated"
  # Deliberate drops are not failures and are not autodream-own.
  assert_grep "$d/run-stats.txt" 'self_sessions_excluded: 0' "collision drops are not charged to self-exclusion"
  rm -rf "$root"
}

# A MIXED run — some collide, one survives — is the case that reaches the normal
# run-stats writer. The all-collide fixtures above take the zero-session path,
# which emits a reduced key set, so neither of them can prove that the normal
# writer carries the collision keys or that deliberate drops stay out of the
# failure denominator.
test_mixed_collision_run_attributes_correctly(){
  echo "# collision: a mixed run keeps drops out of the failure count"
  local root; root=$(collision_sandbox)
  mk_session "$root" one
  mk_session "$root" two
  mk_session "$root" solo
  # Collide everything EXCEPT the path containing "solo", which keeps its real
  # hash and survives to be triaged normally.
  { printf '#!/bin/bash\n'
    printf 'in=$(cat)\n'
    printf 'case "$in" in\n'
    printf '  *solo*) printf "%%s  -\\n" "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ;;\n'
    printf '  *) printf "%%s  -\\n" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ;;\n'
    printf 'esac\n'
  } > "$root/home/.local/bin/shasum"
  chmod +x "$root/home/.local/bin/shasum"
  run_dream_collision "$root"
  local rc=$?
  local d; d=$(fdir "$root")
  assert_eq "$rc" "0" "the run completes with one surviving session"
  assert_grep "$d/run-stats.txt" 'sessions_found_raw: 3' "all three were enumerated"
  assert_grep "$d/run-stats.txt" 'sessions_triaged: 1' "one survived to triage"
  # The keys that existed only in the zero-session writer until now.
  assert_grep "$d/run-stats.txt" 'sessions_dropped_to_collision: 2' "the normal writer carries the collision count"
  assert_grep "$d/run-stats.txt" 'sidecar_stale_rows: 0' "and the stale-row count"
  # The attribution that was wrong: deliberate drops are neither self-sessions
  # nor failures.
  assert_grep "$d/run-stats.txt" 'self_sessions_excluded: 0' "drops are not autodream-own"
  assert_grep "$d/run-stats.txt" 'sessions_dropped_after_failures: 0' "drops are not failures"
  rm -rf "$root"
}

test_persistent_sidecar_failure_counts_rows_not_attempts(){
  echo "# collision: a persistently unwritable sidecar counts ROWS, not attempts"
  local root; root=$(collision_sandbox)
  mk_session "$root" one
  mk_session "$root" two
  # Fail only the sidecar rewrite (-v "^<hash>\t"), leaving the worklist filter
  # (-vxF) and the membership probe (-qxF) working. One provenance row is then
  # permanently stale. Counting ATTEMPTS reported 3 for it: one at detection plus
  # the same hash seen once per dropped path.
  { printf '#!/bin/bash\n'
    printf 'prev=""\n'
    printf 'for a in "$@"; do\n'
    printf '  if [ "$prev" = "-v" ]; then case "$a" in ^*) exit 2 ;; esac; fi\n'
    printf '  prev="$a"\n'
    printf 'done\n'
    printf 'exec /usr/bin/grep "$@"\n'
  } > "$root/home/.local/bin/grep"
  chmod +x "$root/home/.local/bin/grep"
  run_dream_collision "$root" || true
  local d; d=$(fdir "$root")
  assert_grep "$d/run-stats.txt" 'sidecar_stale_rows: 1' "one stale ROW is reported, not three attempts"
  assert_grep "$d/run-stats.txt" 'sessions_dropped_to_collision: 2' "the drop count is unaffected"
  rm -rf "$root"
}

test_unwritable_collision_index_fails_closed(){
  echo "# collision: an unwritable bookkeeping file stops the run, it does not detect blind"
  local root; root=$(collision_sandbox)
  mk_session "$root" one
  mk_session "$root" two
  # The findings dir exists but cannot be written into. The invariant under test
  # is that this stops the run rather than proceeding blind: if the collision
  # index cannot be written, every path looks unseen, no collision is ever
  # DETECTED, and both sessions reach dispatch onto one artifact.
  #
  # In practice an unwritable findings dir is caught one layer earlier, when
  # enumeration cannot be staged, so the assertion is on the invariant (fail
  # closed, say so, write nothing) rather than on which guard fires. The
  # bookkeeping guard covers the narrower case where the dir is writable but
  # those specific files are not.
  local d="$root/autodream/findings/$DATE"
  mkdir -p "$d"; chmod 500 "$d"
  run_dream_collision "$root"
  local rc=$?
  chmod 700 "$d" 2>/dev/null || true
  assert_eq "$rc" "1" "the run fails closed when the findings dir cannot be written"
  assert_grep "$root/run.out" 'FATAL' "the log says it stopped rather than continuing"
  assert_no_file "$root/dreams/$DATE.md" "no report is produced"
  rm -rf "$root"
}

test_broken_shasum_never_collapses_sessions(){
  echo "# hash: a shasum that fails at runtime must not send every session to one artifact"
  local root; root=$(collision_sandbox)
  mk_session "$root" one
  mk_session "$root" two
  # Preflight only checks that shasum EXISTS. This one exists and fails, which
  # used to yield an empty hash — and an empty hash means every session in the
  # night targets ".json", the silent overwrite reached from the other direction.
  printf '#!/bin/bash\nexit 3\n' > "$root/home/.local/bin/shasum"
  chmod +x "$root/home/.local/bin/shasum"
  run_dream_collision "$root" || true
  local d; d=$(fdir "$root")
  assert_no_file "$d/.json" "no artifact is written under an empty hash"
  # Whatever else happens, two sessions must never share one findings record.
  local n; n=$(find "$d" -maxdepth 1 -name '*.json' ! -name '*.stats.json' ! -name 'memory-candidates.json' 2>/dev/null | wc -l | tr -d ' ')
  [ "${n:-0}" -le 2 ] && ok "no more than one record per session" || no "no more than one record per session (got $n)"
  rm -rf "$root"
}

# ---- Candidates remain proposals; session provenance is deterministic ----
# shellcheck source=/dev/null
. "$REPO/bin/lib-project.sh"
mk_session_with_cwd(){ # $1=root $2=name $3=cwd [$4=bucket, default: the cwd's own]
  local b="${4:-$(encode_project "$3")}"
  mkdir -p "$1/projects/$b"
  local f="$1/projects/$b/$2.jsonl"
  printf '%s\n' \
    "{\"type\":\"user\",\"cwd\":\"$3\",\"message\":{\"content\":\"start the task\"}}" \
    '{"type":"user","message":{"content":"keep going"}}' \
    '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read"}]}}' \
    > "$f"
  touch -t "$STAMP" "$f"
}
candidate_run(){
  SHARED_MEMORY_BIN="$HERE/mock-shared-memory.sh" SHARED_MEMORY="$HERE/mock-shared-memory.sh" \
    MOCK_SM_LOG="$1/sm-calls.jsonl" run_dream "$1"
}

test_nightly_candidates_are_never_promoted(){
  echo "# a complete report leaves candidates for human review, never memory writes"
  local root; root=$(setup_env); mkdir -p "$root/work"
  local cwd; cwd=$(cd "$root/work" && pwd -P)
  mk_session_with_cwd "$root" s1 "$cwd"
  local d; d=$(fdir "$root"); mkdir -p "$d"
  # Even legacy output and an installed old applier cannot reopen automatic promotion.
  printf '{"project":"proj-a","title":"Legacy","body":"Not approved","kind":"correction"}\n' > "$d/pins.jsonl"
  printf '#!/bin/bash\ntouch "%s/unapproved-apply"\n' "$root" > "$root/autodream/apply-pins.sh"
  printf '#!/bin/bash\ntouch "%s/unapproved-promote"\n' "$root" > "$root/autodream/promote.sh"
  chmod +x "$root/autodream/apply-pins.sh" "$root/autodream/promote.sh"
  export MOCK_MODE=candidates MOCK_CANDIDATE_CWD="$cwd"
  candidate_run "$root"
  unset MOCK_MODE MOCK_CANDIDATE_CWD
  assert_nonempty "$root/dreams/$DATE.md" "the report is produced"
  assert_eq "$(jq -r '.[0].content' "$d/memory-candidates.json")" "Mock lesson" "the proposal remains available for review"
  assert_no_file "$root/sm-calls.jsonl" "no shared-memory call"
  assert_no_file "$root/unapproved-apply" "the legacy applier is never invoked"
  assert_no_file "$root/unapproved-promote" "the manual promoter is never invoked"
  assert_no_file "$d/memory-promoted.jsonl" "no candidate is marked approved"
  rm -rf "$root"
}

test_candidate_rebuild_preserves_old_proposals(){
  echo "# forced rebuilds preserve earlier candidates but never present them as new"
  local root; root=$(setup_env); mk_session "$root" s1
  local d; d=$(fdir "$root"); mkdir -p "$d"
  printf '[{"cwd":"/old","content":"Old lesson","kind":"correction","evidence":[]}]\n' > "$d/memory-candidates.json"
  cp "$d/memory-candidates.json" "$root/old-candidates.json"
  printf '# old report\n<!-- autodream:open-questions=0 -->\n' > "$root/dreams/$DATE.md"
  export AUTODREAM_FORCE=1; candidate_run "$root"; unset AUTODREAM_FORCE
  assert_eq "$(jq -c . "$d/memory-candidates.json")" '[]' "new report has only its own empty proposal list"
  local old
  for old in "$d"/memory-candidates.json.stale-*; do
    if cmp -s "$old" "$root/old-candidates.json"; then ok "old proposals remain recoverable"; else no "old proposals remain recoverable"; fi
  done
  assert_no_file "$root/sm-calls.jsonl" "rebuilding never writes memory"
  rm -rf "$root"
}

test_candidate_move_failure_stops_aggregation(){
  echo "# an unmovable candidate sidecar cannot be paired with a fresh report"
  local root; root=$(setup_env); mk_session "$root" s1
  local d; d=$(fdir "$root")
  mkdir -p "$d/memory-candidates.json/sub"
  export MOCK_CAPTURE_DIR="$root/cap"
  candidate_run "$root"; local rc=$?
  unset MOCK_CAPTURE_DIR
  assert_eq "$rc" "1" "the run fails instead of presenting stale proposals"
  assert_no_file "$root/cap/l2-args.txt" "no aggregator runs after the failed move"
  assert_no_file "$root/dreams/$DATE.md" "no fresh report claims the old candidates"
  assert_no_file "$root/sm-calls.jsonl" "no memory call"
  rm -rf "$root"
}

test_session_provenance_ignores_forged_findings(){
  echo "# project and candidate cwd come from the actual session, not model-written paths"
  local mode
  for mode in l1_forged l1_tamper; do
    local root; root=$(setup_env); mkdir -p "$root/work-a" "$root/work-b"
    local ca cb; ca=$(cd "$root/work-a" && pwd -P); cb=$(cd "$root/work-b" && pwd -P)
    local ba bb; ba=$(encode_project "$ca"); bb=$(encode_project "$cb")
    mk_session_with_cwd "$root" s1 "$ca"
    mkdir -p "$root/projects/$bb"
    local other="$root/projects/$bb/other.jsonl"
    printf '{"type":"user","cwd":"%s","message":{"content":"x"}}\n' "$cb" > "$other"
    export MOCK_MODE="$mode" MOCK_FORGED_SESSION="$other"
    run_dream "$root"
    unset MOCK_MODE MOCK_FORGED_SESSION
    local record="$(fdir "$root")/$(hash_of "$root/projects/$ba/s1.jsonl").json"
    assert_eq "$(jq -r .project "$record")" "$ba" "model cannot reassign the finding's project ($mode)"
    assert_eq "$(jq -r .cwd "$record")" "$ca" "model cannot reassign the candidate's cwd ($mode)"
    rm -rf "$root"
  done
}

test_subagent_sessions_keep_their_project(){
  echo "# nested agents belong to their real bucket, even when the bucket is named subagents"
  local root; root=$(setup_env); mkdir -p "$root/work"
  local cwd; cwd=$(cd "$root/work" && pwd -P)
  mk_session_with_cwd "$root" s1 "$cwd" "subagents"
  local wf="$root/projects/subagents/uuid/subagents/workflows/wf_abc"
  mkdir -p "$wf"
  cp "$root/projects/subagents/s1.jsonl" "$wf/agent-1.jsonl"
  touch -t "$STAMP" "$wf/agent-1.jsonl"
  export MOCK_MODE=l1_badproject; run_dream "$root"; unset MOCK_MODE
  local s record
  for s in "$root/projects/subagents/s1.jsonl" "$wf/agent-1.jsonl"; do
    record="$(fdir "$root")/$(hash_of "$s").json"
    assert_eq "$(jq -r .project "$record")" "subagents" "project normalization uses the root bucket at every depth"
    assert_eq "$(jq -r .cwd "$record")" "$cwd" "candidate cwd comes from the agent's session"
  done
  rm -rf "$root"
}

test_unusable_session_cwd_is_not_a_candidate_scope(){
  echo "# an encoded bucket and mismatched cwd cannot scope a memory candidate"
  local root; root=$(setup_env); mkdir -p "$root/work-a" "$root/work-b"
  local ca cb; ca=$(cd "$root/work-a" && pwd -P); cb=$(cd "$root/work-b" && pwd -P)
  local ba; ba=$(encode_project "$ca")
  mk_session_with_cwd "$root" s1 "$cb" "$ba"
  export MOCK_MODE=l1_forged MOCK_FORGED_SESSION="/forged/session"
  run_dream "$root"; unset MOCK_MODE MOCK_FORGED_SESSION
  local record="$(fdir "$root")/$(hash_of "$root/projects/$ba/s1.jsonl").json"
  assert_eq "$(jq -r .cwd "$record")" "null" "a model-written cwd cannot rescue an invalid scope"
  assert_eq "$(jq -r .project "$record")" "$ba" "the project still names its actual bucket"
  rm -rf "$root"
}

# ---- run the new tests ----
test_nightly_candidates_are_never_promoted
test_candidate_rebuild_preserves_old_proposals
test_candidate_move_failure_stops_aggregation
test_session_provenance_ignores_forged_findings
test_subagent_sessions_keep_their_project
test_unusable_session_cwd_is_not_a_candidate_scope
test_multiroot_triages_alt_root
test_multiroot_heldout_and_dedup
test_multiroot_flags_unindexed
test_rootprobe_remembers_choice
test_rootprobe_no_write_mode_flags_but_does_not_write
test_rootprobe_empty_home
test_newline_path_is_rejected_not_split
test_source_sidecar_is_written
test_artifact_hash_contract_is_unchanged
test_preflight_stops_a_run_missing_a_dependency
test_install_deploys_the_adapter_runtime
test_unrepresentable_characters_are_refused
test_failing_enumerator_aborts_the_run
test_one_failed_root_does_not_kill_the_night
test_enabled_adapters_resolves_once
test_no_usable_adapter_leaves_a_trace
test_fatal_does_not_clobber_a_complete_date
test_partial_enumeration_keeps_what_it_read
test_all_roots_unavailable_fails
test_fresh_host_with_no_store_is_not_a_failure
test_upgrade_lag_install_still_produces_a_report
test_forced_hash_collision_drops_both
test_collision_worklist_failure_aborts
test_collision_membership_probe_failure_aborts
test_three_way_collision_counts_paths_not_lines
test_mixed_collision_run_attributes_correctly
test_persistent_sidecar_failure_counts_rows_not_attempts
test_unwritable_collision_index_fails_closed
test_broken_shasum_never_collapses_sessions
test_all_excluded_corpus_says_so

# ---- The unit suites, run here and not only in CI ---------------------------
# AGENTS.md tells contributors "run tests/run-all.sh after any run.sh/prompt
# change", and these five were wired into the workflow only — so a local pre-push
# run skipped adapter containment, the manifest-name check and the entire
# contract suite, which is the gap the CI step's own comment says it closes.
# Their counts fold into the totals below, so a red unit suite fails this script.
echo
echo "===== unit suites ====="
for _suite in lib-project preflight adapters adapter-claude adapter-contract slim-transcript promote; do
  _out=$(bash "$HERE/$_suite.sh" 2>&1)
  _rc=$?
  _p=$(printf '%s\n' "$_out" | sed -n 's/^passed: *\([0-9][0-9]*\).*/\1/p' | tail -1)
  _f=$(printf '%s\n' "$_out" | sed -n 's/.*failed: *\([0-9][0-9]*\).*/\1/p' | tail -1)
  pass=$((pass + ${_p:-0}))
  fail=$((fail + ${_f:-0}))
  if [ "$_rc" -ne 0 ] || [ "${_f:-0}" -ne 0 ]; then
    printf '  FAIL - unit suite %s\n' "$_suite"
    printf '%s\n' "$_out" | grep 'FAIL' | head -5
    # A suite that dies before printing a total reports no failures at all, so
    # count one rather than letting a crash read as green.
    [ -n "$_f" ] && [ "$_f" -ne 0 ] || fail=$((fail + 1))
  else
    printf '  ok   - unit suite %-18s (%s assertions)\n' "$_suite" "${_p:-0}"
  fi
done

test_shared_drift_check_from_a_worktree(){
  echo "# check-shared-drift.sh names the repo by its main checkout, so a git worktree still finds the sibling"
  command -v git >/dev/null 2>&1 || { echo "  skip - git not available"; return 0; }
  # Physical path: on macOS mktemp hands back /var/..., git reports /private/var/..., and the
  # sibling path the script prints comes from git.
  local T; T=$(cd "$(mktemp -d)" && pwd -P)
  # A worktree gets its own directory name (cc-autodream-pr25), and inferring the sibling
  # from that name exited 2 and failed the whole suite in every worktree.
  mkdir -p "$T/cc-autodream/bin" "$T/omp-autodream/bin"
  cp "$REPO/bin/check-shared-drift.sh" "$T/cc-autodream/bin/"
  printf 'bin/a.sh\n' > "$T/cc-autodream/shared-with-sibling.txt"
  printf 'echo same\n' > "$T/cc-autodream/bin/a.sh"
  printf 'echo same\n' > "$T/omp-autodream/bin/a.sh"
  ( cd "$T/cc-autodream" && git init -q && git config user.email t@t.invalid && git config user.name t \
      && git add -A && git commit -q -m init && git worktree add -q "$T/cc-autodream-feature" 2>/dev/null )
  local out rc
  out=$(env -u AUTODREAM_SIBLING_REPO bash "$T/cc-autodream-feature/bin/check-shared-drift.sh" 2>&1); rc=$?
  assert_eq "$rc" "0" "a worktree with a matching sibling exits 0"
  case "$out" in *"ok — 1 shared file(s) match $T/omp-autodream"*) ok "and it compared against the sibling next to the main checkout" ;;
    *) no "and it compared against the sibling next to the main checkout (got [$out])" ;; esac
  printf 'echo drifted\n' > "$T/omp-autodream/bin/a.sh"
  env -u AUTODREAM_SIBLING_REPO bash "$T/cc-autodream-feature/bin/check-shared-drift.sh" >/dev/null 2>&1; rc=$?
  assert_eq "$rc" "1" "real drift seen from the worktree still fails"
  # A checkout with a name the script does not know and no git is a degraded measurement:
  # say SKIPPED and exit 0, the same contract as a sibling that is not on disk.
  mkdir -p "$T/elsewhere/bin"; cp "$REPO/bin/check-shared-drift.sh" "$T/elsewhere/bin/"
  printf 'bin/a.sh\n' > "$T/elsewhere/shared-with-sibling.txt"
  out=$(env -u AUTODREAM_SIBLING_REPO bash "$T/elsewhere/bin/check-shared-drift.sh" 2>&1); rc=$?
  assert_eq "$rc" "0" "an unrecognised checkout name skips instead of failing the suite"
  case "$out" in *SKIPPED*) ok "and says it skipped" ;; *) no "and says it skipped (got [$out])" ;; esac
  # Two unreadable copies used to strip to two empty files and compare equal (Codex review
  # of 232c94c). A file the check cannot read has not been verified, so it is drift.
  printf 'echo same\n' > "$T/omp-autodream/bin/a.sh"
  chmod 000 "$T/cc-autodream-feature/bin/a.sh" "$T/omp-autodream/bin/a.sh"
  env -u AUTODREAM_SIBLING_REPO bash "$T/cc-autodream-feature/bin/check-shared-drift.sh" >/dev/null 2>&1; rc=$?
  chmod 644 "$T/cc-autodream-feature/bin/a.sh" "$T/omp-autodream/bin/a.sh"
  assert_eq "$rc" "1" "an unreadable shared file is drift, not a match"
  rm -rf "$T"
}

test_shared_drift_check_from_a_worktree

streak_rows(){ awk '!/^#/ && NF' "$1" 2>/dev/null | wc -l | tr -d ' '; }

test_question_streaks_state_lives_with_the_install(){
  echo "# question streaks: the store is the install's, one file holds the watermark, clear takes the lock"
  local root; root=$(setup_env)
  local QS="$REPO/bin/question-streaks.sh"
  [ -x "$QS" ] || { no "question-streaks.sh executable"; return 0; }
  mkdir -p "$root/home"
  : > "$root/autodream/config"
  local f; for f in "$REPO"/bin/*.sh; do ln -sf "$f" "$root/autodream/$(basename "$f")"; done
  printf 'abc123def456\t2\t2019-12-30\t2019-12-31\tStale question?\n' > "$root/autodream/question-streaks.tsv"

  # Run with no AUTODREAM_DIR at all, the documented no-environment invocation. The helper
  # used to fall back to ~/.claude/autodream and never see this install's store.
  local out
  out=$(env -u AUTODREAM_DIR -u AUTODREAM_QUESTION_STATE HOME="$root/home" bash "$root/autodream/question-streaks.sh" status 2>&1)
  case "$out" in *"Stale question?"*) ok "status run through the install link reads the install's store" ;; *) no "status run through the install link reads the install's store (got: $out)" ;; esac

  # A night with no sessions writes a question-free report and must clear that store. This
  # run.sh takes its install dir from AUTODREAM_DIR (default ~/.claude/autodream) rather than
  # from its own location, so the sandbox install is named explicitly. When the value comes
  # from that default instead, it is not exported on the early path, which is why both call
  # sites pass it to the helper.
  env HOME="$root/home" AUTODREAM_DIR="$root/autodream" AUTODREAM_CHANGELOG=0 AUTODREAM_GC=0 CLAUDE_BIN="$MOCK" \
    AUTODREAM_CONFIG="$root/autodream/config" AUTODREAM_CONSUME_DATE="$DATE" \
    AUTODREAM_NETCHECK=0 AUTODREAM_RETRY_WAIT=0 AUTODREAM_NOTIFY_DRYRUN=1 \
    PROJECTS_DIR="$root/projects" DREAMS_DIR="$root/dreams" \
    bash "$root/autodream/run.sh" "$DATE" > "$root/run.out" 2>&1
  assert_file "$root/dreams/$DATE.md" "precondition: the empty night wrote its report"
  assert_eq "$(streak_rows "$root/autodream/question-streaks.tsv")" "0" "the empty night clears the install's streak store"

  # Clearing the board must not erase the watermark: rebuilding an older report afterwards
  # would otherwise re-enter history as a new night and grow a false streak.
  local st="$root/w.tsv"; : > "$st"
  qsw(){ AUTODREAM_QUESTION_STATE="$st" AUTODREAM_NOTIFY_DRYRUN=1 bash "$QS" "$@" 2>&1; }
  printf '## Open questions for the user\n\n1. **Recurring?** body\n\n<!-- autodream:open-questions=1 -->\n' > "$root/2026-03-01.md"
  printf '## Open questions for the user\n\nNone.\n\n<!-- autodream:open-questions=0 -->\n' > "$root/2026-03-02.md"
  qsw update "$root/2026-03-01.md" >/dev/null
  qsw update "$root/2026-03-02.md" >/dev/null
  out=$(qsw update "$root/2026-03-01.md")
  case "$out" in *"older than the last counted report"*) ok "an older rebuild after a cleared board is still refused" ;; *) no "an older rebuild after a cleared board is still refused (got: $out)" ;; esac
  assert_eq "$(streak_rows "$st")" "0" "and the cleared board stays clear"
  # One file, one write. The watermark used to live beside the state, and three reviews in
  # a row found an order of writes between the two files that let history back in.
  assert_eq "$(head -1 "$st")" "$(printf '#last\t2026-03-02')" "the watermark is the first line of the state file"
  assert_no_file "$st.last" "and no second watermark file is written"

  # clear takes the same lock as update, or an update that already read the old state puts
  # the cleared streak back when it writes.
  printf 'k\t1\t2026-03-03\t2026-03-03\tHeld?\n' > "$st"
  mkdir "$st.lock"
  AUTODREAM_QUESTION_STATE="$st" bash "$QS" clear all >/dev/null 2>&1; local rc=$?
  rmdir "$st.lock" 2>/dev/null
  assert_eq "$rc" "1" "clear fails while an update holds the lock"
  assert_eq "$(streak_rows "$st")" "1" "and leaves the state for that update"

  # An EMPTY board is not a reason to skip the lock: an update holding it may be about to
  # write the first streak, which clear would then report as cleared (Codex review of 4eea84d).
  : > "$st"
  mkdir "$st.lock"
  AUTODREAM_QUESTION_STATE="$st" bash "$QS" clear all >/dev/null 2>&1; rc=$?
  rmdir "$st.lock" 2>/dev/null
  assert_eq "$rc" "1" "clear on an empty board still waits for the lock and fails while it is held"

  # A state file that exists but cannot be read is not an empty board. Reading it as empty
  # restarts every streak and drops the watermark with it. Write-only, so a write would land.
  local st2="$root/w2.tsv"; : > "$st2"
  qs2(){ AUTODREAM_QUESTION_STATE="$st2" AUTODREAM_NOTIFY_DRYRUN=1 bash "$QS" "$@" 2>&1; }
  printf '## Open questions for the user\n\n1. **Recurring?** body\n\n<!-- autodream:open-questions=1 -->\n' > "$root/2026-03-04.md"
  qs2 update "$root/2026-03-01.md" >/dev/null
  cp "$st2" "$root/w2.before"
  chmod 200 "$st2"
  qs2 update "$root/2026-03-04.md" >/dev/null
  chmod 644 "$st2"
  if cmp -s "$st2" "$root/w2.before"; then ok "an unreadable state file refuses the update instead of restarting every streak"; else no "an unreadable state file refuses the update instead of restarting every streak"; fi

  # A state directory that cannot take a temp file leaves the state as it was.
  mkdir -p "$root/ro"; local st3="$root/ro/w3.tsv"
  AUTODREAM_QUESTION_STATE="$st3" AUTODREAM_NOTIFY_DRYRUN=1 bash "$QS" update "$root/2026-03-01.md" >/dev/null 2>&1
  cp "$st3" "$root/w3.before"
  chmod 500 "$root/ro"
  AUTODREAM_QUESTION_STATE="$st3" AUTODREAM_NOTIFY_DRYRUN=1 bash "$QS" update "$root/2026-03-04.md" >/dev/null 2>&1
  chmod 700 "$root/ro"
  if cmp -s "$st3" "$root/w3.before"; then ok "a state directory that refuses a temp file leaves state untouched"; else no "a state directory that refuses a temp file leaves state untouched"; fi

  # clear all forgets the streaks and keeps the watermark, so an older rebuild afterwards is
  # still refused. status never prints the watermark line as a streak.
  local st6="$root/w6.tsv"; : > "$st6"
  qs6(){ AUTODREAM_QUESTION_STATE="$st6" AUTODREAM_NOTIFY_DRYRUN=1 bash "$QS" "$@" 2>&1; }
  qs6 update "$root/2026-03-04.md" >/dev/null
  out=$(qs6 status)
  case "$out" in *"#last"*) no "status does not print the watermark line (got: $out)" ;; *"Recurring?"*) ok "status does not print the watermark line" ;; *) no "status does not print the watermark line (got: $out)" ;; esac
  qs6 clear all >/dev/null
  assert_eq "$(head -1 "$st6")" "$(printf '#last\t2026-03-04')" "clear all keeps the watermark"
  out=$(qs6 update "$root/2026-03-01.md")
  case "$out" in *"older than the last counted report"*) ok "and an older rebuild after clear all is refused" ;; *) no "and an older rebuild after clear all is refused (got: $out)" ;; esac

  # A state path whose directory does not exist yet. The lock lives beside the state, so
  # the directory has to exist before the lock is taken, or every update reads as a held
  # lock and exits without ever creating the state (Codex review of b72f0e4).
  local nested="$root/new/nested/question-streaks.tsv"
  AUTODREAM_QUESTION_STATE="$nested" AUTODREAM_NOTIFY_DRYRUN=1 bash "$QS" update "$root/2026-03-04.md" >/dev/null 2>&1
  assert_eq "$(streak_rows "$nested")" "1" "the first update on a new state directory creates the state"

  # The final rename can fail. The whole state is one temp file renamed into place, so a
  # failed rename leaves the old file whole: board and watermark together.
  local st4="$root/w4.tsv"; : > "$st4"
  mkdir -p "$root/failmv"
  printf '#!/bin/sh\nexit 1\n' > "$root/failmv/mv"; chmod +x "$root/failmv/mv"
  printf '## Open questions for the user\n\n1. **Another?** body\n\n<!-- autodream:open-questions=1 -->\n' > "$root/2026-03-03.md"
  AUTODREAM_QUESTION_STATE="$st4" AUTODREAM_NOTIFY_DRYRUN=1 bash "$QS" update "$root/2026-03-01.md" >/dev/null 2>&1
  cp "$st4" "$root/w4.before"
  PATH="$root/failmv:$PATH" AUTODREAM_QUESTION_STATE="$st4" AUTODREAM_NOTIFY_DRYRUN=1 bash "$QS" update "$root/2026-03-02.md" >/dev/null 2>&1
  if cmp -s "$st4" "$root/w4.before"; then ok "a failed watermark move on a question-free report leaves the board as it was"; else no "a failed watermark move on a question-free report leaves the board as it was"; fi
  PATH="$root/failmv:$PATH" AUTODREAM_QUESTION_STATE="$st4" AUTODREAM_NOTIFY_DRYRUN=1 bash "$QS" update "$root/2026-03-03.md" >/dev/null 2>&1
  if cmp -s "$st4" "$root/w4.before"; then ok "a failed watermark move on a report with questions leaves the board as it was"; else no "a failed watermark move on a report with questions leaves the board as it was"; fi
  rm -rf "$root"
}

test_question_streaks(){
  echo "# question streaks: count repeats across reports and escalate the stale ones"
  local root; root=$(setup_env)
  local QS="$REPO/bin/question-streaks.sh"
  [ -x "$QS" ] || { no "question-streaks.sh executable"; return 0; }
  local st="$root/streaks.tsv"; : > "$st"
  local out
  qs(){ AUTODREAM_QUESTION_STATE="$st" AUTODREAM_NOTIFY_DRYRUN=1 bash "$QS" "$@" 2>&1; }

  mk_report(){ # $1=date  $2..=bold titles
    local d="$1"; shift
    { printf '## Open questions for the user\n\n'
      local i=1
      for t in "$@"; do printf '%d. **%s** body text that is rewritten every night\n' "$i" "$t"; i=$(( i + 1 )); done
      printf '\n<!-- autodream:open-questions=%d -->\n' "$#"
    } > "$root/$d.md"
  }

  # The real shape this was built from: the title is byte-identical night to night while
  # the body prose is rewritten, so an exact key on the title is enough.
  mk_report 2026-01-01 "Fix the X bookmarks walker, or turn the feature off?" "Something else?"
  mk_report 2026-01-02 "Fix the X bookmarks walker, or turn the feature off?"
  mk_report 2026-01-03 "Fix the X bookmarks walker, or turn the feature off?"

  out=$(qs update "$root/2026-01-01.md")
  assert_eq "$(printf '%s' "$out" | grep -c 'past 3 consecutive')" "1" "night 1 reports its count"
  case "$out" in *"0 at or past"*) ok "night 1 escalates nothing" ;; *) no "night 1 escalates nothing (got: $out)" ;; esac

  out=$(qs update "$root/2026-01-02.md")
  case "$out" in *"0 at or past"*) ok "night 2 still escalates nothing" ;; *) no "night 2 still escalates nothing" ;; esac
  # The question that vanished must stop counting rather than linger forever.
  assert_eq "$(grep -c 'Something else' "$st")" "0" "a question absent from a later report is dropped"

  out=$(qs update "$root/2026-01-03.md")
  case "$out" in
    *"3 consecutive reports"*) ok "night 3 escalates the repeated question" ;;
    *) no "night 3 escalates the repeated question (got: $out)" ;;
  esac
  case "$out" in *"Fix the X bookmarks walker"*) ok "the escalation names the question" ;; *) no "the escalation names the question" ;; esac

  # Streaks count consecutive REPORTS, not calendar days — a night that produced no report
  # must not reset one, since surviving failing nights is the whole point.
  mk_report 2026-01-09 "Fix the X bookmarks walker, or turn the feature off?"
  out=$(qs update "$root/2026-01-09.md")
  case "$out" in *"4 consecutive reports"*) ok "a date gap does not reset the streak" ;; *) no "a date gap does not reset the streak (got: $out)" ;; esac

  # A report with genuinely zero questions clears the board.
  printf '## Open questions for the user\n\nNone.\n\n<!-- autodream:open-questions=0 -->\n' > "$root/2026-01-10.md"
  qs update "$root/2026-01-10.md" >/dev/null
  # wc -l, not `grep -c . || echo 0`: grep -c prints 0 AND exits 1 on no match, so the
  # fallback fires too and the value is "0\n0". That trap is documented in this repo and
  # it still caught this test on the first run.
  assert_eq "$(streak_rows "$st")" "0" "a question-free report clears every streak"

  # A marker that promises questions while none parse means the format moved. That must be
  # reported, never silently counted as zero — the quiet version would freeze every streak
  # at its last value and the escalation would never fire again.
  printf '## Open questions for the user\n\n1. no bold title here?\n\n<!-- autodream:open-questions=1 -->\n' > "$root/2026-01-11.md"
  out=$(qs update "$root/2026-01-11.md")
  case "$out" in *"title format changed"*) ok "a changed title format warns instead of counting zero" ;; *) no "a changed title format warns instead of counting zero (got: $out)" ;; esac

  rm -rf "$root"
}

test_question_streaks_reruns_and_mismatch(){
  echo "# question streaks: reruns, backwards rebuilds, count mismatch, clear failure"
  local root; root=$(setup_env)
  local QS="$REPO/bin/question-streaks.sh"
  [ -x "$QS" ] || { no "question-streaks.sh executable"; return 0; }
  local st="$root/streaks.tsv"; : > "$st"
  local out
  qs(){ AUTODREAM_QUESTION_STATE="$st" AUTODREAM_NOTIFY_DRYRUN=1 bash "$QS" "$@" 2>&1; }
  mk(){ # $1=date $2=marker $3..=titles
    local d="$1" m="$2"; shift 2
    { printf '## Open questions for the user\n\n'
      local i=1
      for t in "$@"; do printf '%d. **%s** nightly-rewritten body\n' "$i" "$t"; i=$(( i + 1 )); done
      printf '\n<!-- autodream:open-questions=%d -->\n' "$m"
    } > "$root/$d.md"
  }

  mk 2026-02-01 1 "Recurring question?"
  mk 2026-02-02 1 "Recurring question?"
  qs update "$root/2026-02-01.md" >/dev/null
  qs update "$root/2026-02-02.md" >/dev/null
  assert_eq "$(awk -F'\t' '!/^#/ {print $2}' "$st")" "2" "two distinct reports count two"

  # AUTODREAM_FORCE=1 rebuilds the same report. Counting it again would manufacture an
  # escalation out of a rerun.
  qs update "$root/2026-02-02.md" >/dev/null
  assert_eq "$(awk -F'\t' '!/^#/ {print $2}' "$st")" "2" "rebuilding the same report does not advance the streak"

  # A rebuild of an OLDER date must not rewrite live state with history: 02-01 does not
  # know about anything that happened on 02-02.
  out=$(qs update "$root/2026-02-01.md")
  case "$out" in *"older than the last counted report"*) ok "an older rebuild is refused" ;; *) no "an older rebuild is refused (got: $out)" ;; esac
  assert_eq "$(awk -F'\t' '!/^#/ {print $4}' "$st")" "2026-02-02" "and the live last-seen date is untouched"

  # The marker is the report's own count. Disagreement means questions parsed as nothing;
  # touching state would silently drop a streak or freeze them all.
  mk 2026-02-03 2 "Recurring question?"   # marker says 2, only 1 bold title present
  out=$(qs update "$root/2026-02-03.md")
  case "$out" in *"but 1 parsed"*) ok "a parsed-vs-marker mismatch warns" ;; *) no "a parsed-vs-marker mismatch warns (got: $out)" ;; esac
  assert_eq "$(awk -F'\t' '!/^#/ {print $2}' "$st")" "2" "and refuses to change state"

  # A report with no count marker is incomplete: an L2 run truncated before the Open
  # questions section, left in place when run.sh could not move it aside. Parsing it as
  # zero questions cleared every streak and advanced the watermark (Codex review of b72f0e4).
  printf '# Autodream\n\n## Activity snapshot\n- 7 sessions\n' > "$root/2026-02-05.md"
  printf '## Open questions for the user\n\n1. **Recurring question?** body cut off mid-' > "$root/2026-02-06.md"
  cp "$st" "$root/st.before"
  out=$(qs update "$root/2026-02-05.md")
  case "$out" in *"no open-questions marker"*) ok "a report truncated before its questions is refused as incomplete" ;; *) no "a report truncated before its questions is refused as incomplete (got: $out)" ;; esac
  if cmp -s "$st" "$root/st.before"; then ok "and does not clear the board"; else no "and does not clear the board"; fi
  qs update "$root/2026-02-06.md" >/dev/null
  if cmp -s "$st" "$root/st.before"; then ok "a report truncated after a question title is refused too"; else no "a report truncated after a question title is refused too"; fi

  # clear with a key no streak carries printed "cleared" and exited 0, so a mistyped key left
  # the streak escalating after the operator was told it was forgotten (#32).
  local krc
  out=$(qs clear deadbeef0000); krc=$?
  assert_eq "$krc" "1" "clear with an unknown key fails"
  case "$out" in *"no streak with key deadbeef0000"*) ok "and names the key it could not find" ;; *) no "and names the key it could not find (got: $out)" ;; esac
  if cmp -s "$st" "$root/st.before"; then ok "and leaves the state untouched"; else no "and leaves the state untouched"; fi
  # Keys are hex, so a key can be all digits. awk compares two numeric-looking strings as
  # numbers, so `clear 89709551468` matched the row `089709551468` and cleared the wrong
  # streak (Codex review of omp-autodream 5f7ddaa). Keys compare as strings.
  printf '#last\t2026-02-02\n089709551468\t2\t2026-02-01\t2026-02-02\tDigits only?\n' > "$root/num.tsv"
  cp "$root/num.tsv" "$root/num.before"
  AUTODREAM_QUESTION_STATE="$root/num.tsv" bash "$QS" clear 89709551468 >/dev/null 2>&1; krc=$?
  assert_eq "$krc" "1" "clear with a key that only equals a row key numerically fails"
  if cmp -s "$root/num.tsv" "$root/num.before"; then ok "and does not clear the numerically equal streak"; else no "and does not clear the numerically equal streak"; fi
  # awk -v also decodes backslash escapes, so `\060...` became `0...` and matched a real key
  # (Codex review of omp-autodream b67c2f1). A key is 12 lowercase hex characters; anything
  # else is refused before awk sees it.
  printf '#last\t2026-02-02\n080dd5de4c18\t2\t2026-02-01\t2026-02-02\tEscaped?\n' > "$root/esc.tsv"
  cp "$root/esc.tsv" "$root/esc.before"
  out=$(AUTODREAM_QUESTION_STATE="$root/esc.tsv" bash "$QS" clear '\06080dd5de4c18' 2>&1); krc=$?
  assert_eq "$krc" "1" "clear with an escaped key that decodes to a real key fails"
  case "$out" in *"not a streak key"*) ok "and says it is not a streak key" ;; *) no "and says it is not a streak key (got: $out)" ;; esac
  if cmp -s "$root/esc.tsv" "$root/esc.before"; then ok "and does not clear the streak the escape decodes to"; else no "and does not clear the streak the escape decodes to"; fi

  # clear must not claim success it did not achieve.
  chmod 500 "$root" 2>/dev/null
  out=$(AUTODREAM_QUESTION_STATE="$root/nope/state.tsv" bash "$QS" clear all 2>&1); local rc=$?
  chmod 700 "$root" 2>/dev/null
  assert_eq "$rc" "0" "clear on a missing state file is a no-op, not an error"

  rm -rf "$root"
}

test_question_streaks
test_question_streaks_reruns_and_mismatch
test_question_streaks_state_lives_with_the_install

echo
echo "# bench: model benchmark unit tests"
if python3 -m unittest discover -s "$REPO/bench/tests" >/dev/null 2>&1; then
  ok "bench unit tests pass"
else
  no "bench unit tests failed (run: python3 -m unittest discover -s bench/tests)"
fi

# Cross-repo drift, last. It is not a unit test — it inspects the sibling checkout, so it
# can only run on a machine holding both — but it belongs in the same command as the rest,
# because the failure it catches is one no amount of in-repo testing can see. Both repos
# passed their own suites for the ten nights this repo's bookmark walk was broken while
# omp-autodream's identical copy had been fixed. SKIPPED (no sibling) exits 0 and says so;
# drift exits 1 and counts as a failure here.
echo
echo "# cross-repo: shared files must not drift from the sibling autodream repo"
if bash "$REPO/bin/check-shared-drift.sh"; then
  ok "shared files match the sibling repo (or the check skipped and said so)"
else
  no "shared files have drifted from the sibling repo"
fi

echo
echo "----------------------------------------"
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]
