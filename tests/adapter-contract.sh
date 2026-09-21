#!/bin/bash
# THE adapter contract, run against every adapter rather than described once.
#
# The same assertions execute for `claude` and for `_fixture`. That is the whole
# point: a contract that only ever runs against the adapter it was written
# alongside is a description of that adapter, and it will keep passing on the
# day someone adds a Claude-shaped assumption to shared code. `_fixture` uses a
# session format resembling neither real harness, so an assumption that leaked
# in fails here immediately.
#
# When a third adapter arrives (omp, codex, pi), add one `run_contract` line.
# If that is all it takes, the seam is real.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)

pass=0; fail=0
ok(){ printf '  ok   - %s\n' "$1"; pass=$((pass + 1)); }
no(){ printf '  FAIL - %s\n' "$1"; fail=$((fail + 1)); }
assert_eq(){ [ "$1" = "$2" ] && ok "$3" || no "$3 (got [$1] want [$2])"; }

# --- per-adapter fixture makers -------------------------------------------
# Each prints a session path for its harness's own format into $1.
mk_session_claude(){ # $1=dir $2=cwd
  mkdir -p "$1/root/projects/-bucket"
  local f="$1/root/projects/-bucket/s.jsonl"
  printf '%s\n' "{\"type\":\"user\",\"cwd\":\"$2\",\"message\":{\"content\":\"hi\"}}" > "$f"
  printf '%s' "$f"
}
mk_session__fixture(){ # $1=dir $2=cwd
  mkdir -p "$1/store"
  local f="$1/store/s.fixture"
  printf '{"cwd":"%s","turns":2}\n' "$2" > "$f"
  printf '%s' "$f"
}

run_contract(){ # $1=adapter name
  local name="$1"
  local A="$REPO/adapters/$name/adapter.sh"
  echo "# contract [$name]"

  if [ ! -x "$A" ]; then no "[$name] adapter.sh exists and is executable"; return; fi
  ok "[$name] adapter.sh exists and is executable"

  # The manifest is data and must parse, and its name must match the directory.
  if jq -e . "$REPO/adapters/$name/manifest.json" >/dev/null 2>&1; then
    ok "[$name] manifest.json is valid JSON"
  else no "[$name] manifest.json is valid JSON"; fi
  assert_eq "$(jq -r .name "$REPO/adapters/$name/manifest.json")" "$name" "[$name] manifest name matches its directory"
  if [ -s "$REPO/adapters/$name/facts.md" ]; then
    ok "[$name] facts.md exists and is non-empty"
  else no "[$name] facts.md exists and is non-empty"; fi

  local tmp proj projreal S
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/contract.XXXXXX")
  proj="$tmp/work dir"; mkdir -p "$proj"          # a space: NUL transport must allow it
  projreal=$(cd "$proj" && pwd -P)
  S=$("mk_session_$name" "$tmp" "$projreal")

  # --- project ---
  assert_eq "$("$A" project "$S")" "$projreal" "[$name] project prints the resolved cwd"
  if "$A" project "$tmp/nope" >/dev/null 2>&1; then
    no "[$name] project on a missing session exits nonzero"
  else ok "[$name] project on a missing session exits nonzero"; fi

  # --- normalize: atomic, and nothing left behind on failure ---
  if "$A" normalize "$S" "$tmp/n.out" 2>/dev/null; then ok "[$name] normalize exits 0"
  else no "[$name] normalize exits 0"; fi
  if [ -s "$tmp/n.out" ]; then ok "[$name] normalize wrote output"; else no "[$name] normalize wrote output"; fi
  # Glob, not a literal. The temp is `<out>.tmp.XXXXXX`, so a check for exactly
  # `<out>.tmp` matches nothing that is ever created and passes against an
  # implementation leaking a temp on every call. `set --` then `-e "$1"` is the
  # bash-3.2-safe way to ask whether a glob matched anything.
  #
  # `.tmp*`, NOT `.tmp.*`. The first correction here swapped one blind spot for
  # another: a glob anchored on `.tmp.` stops seeing an adapter that leaks the
  # bare `<out>.tmp`, which is the name the contract prose uses and therefore
  # the likeliest one a new adapter picks.
  set -- "$tmp"/n.out.tmp*
  if [ -e "$1" ]; then no "[$name] normalize left no temp (found $(basename "$1"))"; else ok "[$name] normalize left no temp"; fi
  if "$A" normalize "$tmp/nope" "$tmp/bad.out" 2>/dev/null; then
    no "[$name] normalize on bad input exits nonzero"
  else ok "[$name] normalize on bad input exits nonzero"; fi
  if [ -e "$tmp/bad.out" ]; then no "[$name] no partial output on failure"; else ok "[$name] no partial output on failure"; fi

  # --- stats: a sidecar file with a numeric transcript_bytes ---
  if "$A" stats "$S" "$tmp/s.stats.json" 2>/dev/null; then ok "[$name] stats exits 0"
  else no "[$name] stats exits 0"; fi
  if jq -e '.transcript_bytes | numbers' "$tmp/s.stats.json" >/dev/null 2>&1; then
    ok "[$name] the sidecar carries a numeric transcript_bytes"
  else no "[$name] the sidecar carries a numeric transcript_bytes"; fi
  # stats writes a temp exactly as normalize and slim do, and was the only one of
  # the three with no cleanup assertion. A valid sidecar plus a leaked temp on
  # every session passed the entire contract.
  set -- "$tmp"/s.stats.json.tmp*
  if [ -e "$1" ]; then no "[$name] stats left no temp (found $(basename "$1"))"; else ok "[$name] stats left no temp"; fi

  # --- slim ---
  if "$A" slim "$S" "$tmp/sl.out" 2>/dev/null; then ok "[$name] slim exits 0"; else no "[$name] slim exits 0"; fi
  if [ -s "$tmp/sl.out" ]; then ok "[$name] slim wrote output"; else no "[$name] slim wrote output"; fi
  set -- "$tmp"/sl.out.tmp*
  if [ -e "$1" ]; then no "[$name] slim left no temp (found $(basename "$1"))"; else ok "[$name] slim left no temp"; fi

  # --- a directory destination is refused, not written into ---
  # `mv -f "$t" "$2"` with an existing directory at $2 moves the temp INSIDE it
  # and returns success, so the adapter reports a write it did not perform and
  # plants a randomly-named file in a directory the caller chose. The delegates
  # used to reject this on their own, because a `>` redirection to a directory
  # fails; wrapping them removed that and the wrap has to restore it.
  mkdir -p "$tmp/destdir"
  local subc
  for subc in normalize slim stats; do
    if "$A" "$subc" "$S" "$tmp/destdir" >/dev/null 2>&1; then
      no "[$name] $subc must refuse a directory destination"
    else
      ok "[$name] $subc refuses a directory destination"
    fi
  done
  if [ -z "$(ls -A "$tmp/destdir" 2>/dev/null)" ]; then
    ok "[$name] nothing was planted inside the directory destination"
  else
    no "[$name] a file was planted inside the directory destination: $(ls -A "$tmp/destdir" | head -1)"
  fi

  # --- slim and stats do not write the destination directly ---
  # The design doc requires this of EVERY subcommand that writes a file
  # (docs/design/unify-harness-adapters-2026-08-23.md:131), and the earlier
  # contract asserted it only for `normalize`. The claude adapter then handed
  # `slim` and `stats` straight to scripts that write the destination directly,
  # so an interrupted slim left a non-empty footer-less transcript that the
  # caller's `-s` check accepts and sends to L1 as a whole session.
  #
  # The interrupt window itself cannot be opened from a unit test. What CAN be
  # tested is a property that closes it, using a read-only destination directory.
  # Exactly what that does and does not prove is spelled out at the assertions
  # below, deliberately, because two review seats independently read a stronger
  # guarantee into this paragraph than the test delivers.
  local rodir
  rodir="$tmp/ro"; mkdir -p "$rodir"
  if [ "$(id -u)" = "0" ]; then
    ok "[$name] running as root, so a read-only dir proves nothing; skipped"
  else
    local sub
    for sub in slim stats; do
      printf 'SENTINEL\n' > "$rodir/$sub.out"
      chmod 500 "$rodir"
      "$A" "$sub" "$S" "$rodir/$sub.out" >/dev/null 2>&1
      rrc=$?
      chmod 700 "$rodir"
      # BOTH halves, and what they prove together is narrower than the section
      # heading suggests. The sentinel rules out a DIRECT writer: truncating an
      # existing file in place needs no directory write, so a direct writer
      # clobbers it here while a temp-and-rename writer cannot create its temp.
      # The status rules out reporting success while writing nothing.
      #
      # What neither rules out is an implementation that rejects an unwritable
      # destination up front without attempting a temp at all. That is fine —
      # such an implementation satisfies the contract this test exists to defend
      # (no partial write, no false success), so the distinction has no
      # behavioural consequence. Saying so here rather than letting the next
      # reader infer a stronger guarantee from the name.
      if [ "$rrc" -ne 0 ]; then
        ok "[$name] $sub failed rather than writing when its temp could not be created"
      else
        no "[$name] $sub reported success with an unwritable destination directory"
      fi
      if [ "$(cat "$rodir/$sub.out" 2>/dev/null)" = "SENTINEL" ]; then
        ok "[$name] $sub could not write its temp, so it left the old output intact"
      else
        no "[$name] $sub wrote the destination directly instead of through a temp"
      fi
    done
  fi

  # --- is-self: must answer, and must not claim an ordinary session ---
  "$A" is-self "$S" >/dev/null 2>&1
  local rc=$?
  if [ "$rc" -eq 0 ] || [ "$rc" -eq 1 ]; then ok "[$name] is-self answers 0 or 1"
  else no "[$name] is-self answers 0 or 1 (got $rc)"; fi
  if "$A" is-self "$S" >/dev/null 2>&1; then
    no "[$name] an ordinary session is not claimed as ours"
  else ok "[$name] an ordinary session is not claimed as ours"; fi
  # A session that cannot be READ must not answer "not ours". The predicate greps
  # with stderr discarded and returns 1 for a missing file, which is the same
  # answer a genuine user session gives — so a vanished transcript silently
  # became someone else's problem. Every sibling subcommand has this guard; this
  # one did not, and the contract had no way to say "I could not read it".
  "$A" is-self "$tmp/definitely-not-here.jsonl" >/dev/null 2>&1
  local selfrc=$?
  if [ "$selfrc" -eq 0 ] || [ "$selfrc" -eq 1 ]; then
    no "[$name] an unreadable session must not answer 0 or 1 (got $selfrc)"
  else
    ok "[$name] an unreadable session is distinguishable from a real answer"
  fi

  # --- memory-root: empty is legal ONLY for a non-writing adapter ---
  local writes mr
  writes=$(jq -r '.writes_memory' "$REPO/adapters/$name/manifest.json")
  mr=$("$A" memory-root "$S" 2>/dev/null || true)
  if [ "$writes" = "true" ]; then
    case "$mr" in
      /*) ok "[$name] writes_memory:true, so memory-root is absolute" ;;
      *)  no "[$name] writes_memory:true, so memory-root is absolute (got: [$mr])" ;;
    esac
    assert_eq "$mr" "$(realpath "$mr" 2>/dev/null)" "[$name] memory-root is canonical"
  else
    assert_eq "$mr" "" "[$name] writes_memory:false, so memory-root is empty"
  fi

  # --- enumerate: the only subcommand production actually calls, and the one
  #     with the subtlest contract (NUL delimiting, and a status the caller now
  #     depends on). It was the untested surface while being the riskiest.
  # Pin the session to a fixed day and ask for exactly that day. A wide range
  # like 1970..2999 is not portable: BSD find fails to parse -newermt at that
  # far end, errors out, and the assertions below would have been measuring the
  # date parser rather than the contract.
  local root_dir n
  root_dir=$(dirname "$S")
  touch -t 202001021200 "$S"
  n=$("$A" enumerate "$root_dir" 2020-01-02 2020-01-03 2>/dev/null | tr -cd '\0' | wc -c | tr -d ' ')
  if [ "${n:-0}" -ge 1 ]; then ok "[$name] enumerate emits NUL-delimited output"
  else no "[$name] enumerate emits NUL-delimited output (got $n NULs)"; fi
  if "$A" enumerate "$root_dir" 2020-01-02 2020-01-03 >/dev/null 2>&1; then
    ok "[$name] enumerate exits 0 on a readable root"
  else no "[$name] enumerate exits 0 on a readable root"; fi
  if "$A" enumerate "$root_dir" 2020-01-02 2020-01-03 2>/dev/null | tr '\0' '\n' | grep -qxF "$S"; then
    ok "[$name] enumerate returns the session path verbatim"
  else no "[$name] enumerate returns the session path verbatim"; fi

  # --- unknown subcommand ---
  "$A" not-a-subcommand >/dev/null 2>&1
  assert_eq "$?" "2" "[$name] an unknown subcommand exits 2"

  rm -rf "$tmp"
}

run_contract claude
run_contract _fixture

printf '\npassed: %s   failed: %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
