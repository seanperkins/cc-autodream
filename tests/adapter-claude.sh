#!/bin/bash
# Contract tests for the claude adapter.
#
# This adapter invents no behavior — every subcommand delegates to the script
# that already implements it. What these tests pin is the CONTRACT: exit codes,
# atomic output, and the two path shapes a Claude session can have.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
A="$REPO/adapters/claude/adapter.sh"

pass=0; fail=0
ok(){ printf '  ok   - %s\n' "$1"; pass=$((pass + 1)); }
no(){ printf '  FAIL - %s\n' "$1"; fail=$((fail + 1)); }
assert_eq(){ [ "$1" = "$2" ] && ok "$3" || no "$3 (got [$1] want [$2])"; }

[ -x "$A" ] || { printf '  FAIL - adapters/claude/adapter.sh missing or not executable\n'
                 printf '\npassed: 0   failed: 1\n'; exit 1; }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/adclaude.XXXXXX")

# Cleanup lives in a trap because this suite parks a process that blocks forever
# on purpose. The FIFO test below starts a `slim` whose first read waits for a
# writer that never comes. Both cleanups used to sit on the last lines of the
# file, so a run that ended any other way — Ctrl-C, a harness timeout, an early
# exit — reached neither, and the delegate was reparented to init and blocked
# for good.
#
# Measured, not hypothesised: 22 interrupted runs over about 90 minutes on
# 2026-08-26 left 66 slim-transcript.sh processes alive. They were still there
# nine days later, each holding a FIFO open in a temp directory that had already
# been deleted.
#
# A trap is safe HERE in a way it is not in adapters/claude/adapter.sh, which
# documents the opposite conclusion and issue #57 explains at length. The
# difference is not that this suite is interruptible and that one is not. Bash
# defers a trapped signal until the FOREGROUND child returns in both, and a
# foreground `sleep` is NOT interruptible — measured on bash 5.3.15 and on
# /bin/bash 3.2.57, a trapped TERM sent 1s into `sleep 5` fires at t=5, while
# the same signal during `wait` fires at t=1.
#
# The difference is that the deferral is BOUNDED here and unbounded there. Every
# foreground child in this file is a `sleep 0.05` or faster, so the worst case
# is a signal handled 50ms late. adapter.sh's foreground child is the delegate
# itself, which blocks forever on the FIFO, so a trap there converts a prompt
# death into a hang.
# Reap by PROCESS GROUP, never by name. Two rounds of #62 review went into this
# and both were spent on `pkill -f`, which is the wrong tool twice over: it
# matches an unanchored REGEX, so an interpolated $TMPDIR of /tmp/a[b] silently
# matched nothing, and once $TMPDIR was out of the pattern the mktemp suffix
# still identified the run only probabilistically. A pattern names processes by
# what they look like; the group names exactly the ones this run started.
#
# `set -m` around the launch puts the adapter in its own process group, so the
# delegate and the two bash subshells beneath it inherit that pgid. Killing the
# negative pid reaches all of them in one call, and it keeps working after the
# adapter dies: a reparented child keeps its process group.
reap_delegate() {
  [ -n "${slim_pgid:-}" ] || return 0
  kill -TERM -"$slim_pgid" 2>/dev/null
  kill -KILL -"$slim_pgid" 2>/dev/null
  return 0
}

cleanup() {
  # Both guards below default under `set -u`: the FIFO branch may never have run
  # (no mkfifo), leaving $slim_pgid unset, and the trap is armed before $tmp is
  # guaranteed populated.
  reap_delegate
  [ -n "${tmp:-}" ] && [ -d "${tmp:-}" ] && rm -rf "$tmp"
  return 0
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

# A real cwd to resolve against, created inside the sandbox so the test owns it.
proj="$tmp/proj a"          # a space, because NUL transport is supposed to allow it
mkdir -p "$proj"
projreal=$(cd "$proj" && pwd -P)

# Session at the normal depth: <root>/projects/<bucket>/<file>.jsonl
mkdir -p "$tmp/root/projects/-bucket"
S="$tmp/root/projects/-bucket/s1.jsonl"
printf '%s\n' \
  "{\"type\":\"user\",\"cwd\":\"$projreal\",\"message\":{\"content\":\"hello\"}}" \
  '{"type":"assistant","message":{"content":[{"type":"text","text":"hi"}]}}' > "$S"

# Subagent transcript, which sits two levels deeper. CLAUDE.md is explicit that
# these are legitimate sessions to triage, so memory-root must handle both.
mkdir -p "$tmp/root/projects/-bucket/s1/subagents"
SUB="$tmp/root/projects/-bucket/s1/subagents/agent-x.jsonl"
printf '%s\n' "{\"type\":\"user\",\"cwd\":\"$projreal\",\"message\":{\"content\":\"sub\"}}" > "$SUB"

echo "# claude adapter: project returns the resolved cwd, not the bucket name"
assert_eq "$("$A" project "$S")" "$projreal" "resolved cwd from the transcript"
if "$A" project "$tmp/root/projects/-bucket/nope.jsonl" >/dev/null 2>&1; then
  no "a missing session exits nonzero"
else ok "a missing session exits nonzero"; fi

echo "# claude adapter: normalize is a verbatim copy for this harness"
out="$tmp/norm.jsonl"
if "$A" normalize "$S" "$out"; then ok "normalize exits 0"; else no "normalize exits 0"; fi
if cmp -s "$S" "$out"; then ok "normalize copied the file verbatim"; else no "normalize copied the file verbatim"; fi
# Glob, not a literal. mktemp creates `<out>.tmp.XXXXXX`, so `<out>.tmp` names a
# path nothing ever creates and the assertion passed against a leaking
# implementation. This was the third copy of that same mistake — the two in
# adapter-contract.sh were fixed a commit earlier and this one was missed,
# because it was the assertion nobody had reason to re-read.
set -- "$out".tmp*
if [ -e "$1" ]; then no "no temp left behind (found $(basename "$1"))"; else ok "no temp left behind"; fi

echo "# claude adapter: a failed normalize leaves no partial output"
if "$A" normalize "$tmp/missing.jsonl" "$tmp/partial.jsonl" 2>/dev/null; then
  no "missing input exits nonzero"
else ok "missing input exits nonzero"; fi
if [ -e "$tmp/partial.jsonl" ]; then no "no partial output on failure"; else ok "no partial output on failure"; fi

echo "# claude adapter: memory-root walks up to the config dir, at either depth"
assert_eq "$("$A" memory-root "$S")"   "$(cd "$tmp/root" && pwd -P)" "normal session resolves to the root"
assert_eq "$("$A" memory-root "$SUB")" "$(cd "$tmp/root" && pwd -P)" "subagent transcript resolves to the same root"
if "$A" memory-root "$tmp/loose.jsonl" >/dev/null 2>&1; then
  no "a path with no projects/ ancestor exits nonzero"
else ok "a path with no projects/ ancestor exits nonzero"; fi

echo "# claude adapter: memory-root output is absolute and canonical"
mr=$("$A" memory-root "$S")
case "$mr" in /*) ok "memory-root is absolute" ;; *) no "memory-root is absolute (got: $mr)" ;; esac
assert_eq "$mr" "$(realpath "$mr")" "memory-root is already canonical"

echo "# claude adapter: stats writes a sidecar with numeric transcript_bytes"
if "$A" stats "$S" "$tmp/s1.stats.json" 2>/dev/null; then ok "stats exits 0"; else no "stats exits 0"; fi
if jq -e '.transcript_bytes | numbers' "$tmp/s1.stats.json" >/dev/null 2>&1; then
  ok "the sidecar has a numeric transcript_bytes"
else no "the sidecar has a numeric transcript_bytes"; fi
# stats was the one writing subcommand with no cleanup assertion at all, in
# either suite. normalize and slim each got one; stats writes a temp exactly the
# same way and nothing looked for it, so it could produce a valid sidecar and
# leak its temp on every session with the whole suite green.
set -- "$tmp"/s1.stats.json.tmp*
if [ -e "$1" ]; then no "stats left no temp (found $(basename "$1"))"; else ok "stats left no temp"; fi

echo "# claude adapter: slim writes a reduced copy"
if "$A" slim "$S" "$tmp/slim.jsonl" 2>/dev/null; then ok "slim exits 0"; else no "slim exits 0"; fi
if [ -s "$tmp/slim.jsonl" ]; then ok "slim wrote output"; else no "slim wrote output"; fi

echo "# claude adapter: a signalled slim dies promptly and writes no destination"
# Two properties, and the second one is here because trying to add a third broke
# it. The temp-and-rename wrap must keep a partial write out of the destination
# when a run is killed, AND the adapter must still die when signalled.
#
# It does NOT assert the temp is cleaned up. That would demand a signal trap, and
# a trap makes this worse: bash defers a trapped signal until the foreground
# child returns, so the adapter ignores SIGTERM for as long as the delegate runs.
# The version of this test that asserted temp cleanup hung for the full timeout
# against exactly that fix and left orphaned delegates behind. The stale temp is
# tracked as an issue; the responsiveness assertion below is what stops a future
# reader from "fixing" the leak the obvious way.
#
# The interrupt is made deterministic with a FIFO. `[ -r ]` on it succeeds, so
# the delegate starts and its first read blocks forever with no writer, which
# parks the adapter at a known point AFTER mktemp and BEFORE the rename.
fifodir="$tmp/fifo"; mkdir -p "$fifodir"
mkfifo "$fifodir/src.jsonl" 2>/dev/null
if [ -p "$fifodir/src.jsonl" ]; then
  # Monitor mode only around the launch: it gives this job its own process group
  # (pgid == pid) so reap_delegate can signal the whole tree. Restored right
  # after, because job control changes behaviour for everything that follows.
  set -m
  "$A" slim "$fifodir/src.jsonl" "$fifodir/out.jsonl" >/dev/null 2>&1 &
  slim_pid=$!
  set +m
  slim_pgid=$slim_pid
  # Wait for the temp to APPEAR before signalling. A busy spin returns long
  # before the adapter has reached mktemp, and killing it that early makes the
  # assertion below vacuous — it passed against the untrapped code exactly once,
  # for that reason. Poll on a real interval and assert the temp existed, so a
  # test that never opened the window fails instead of reporting success.
  waited=0; saw_tmp=0
  while [ "$waited" -lt 100 ]; do
    set -- "$fifodir"/out.jsonl.tmp*
    if [ -e "$1" ]; then saw_tmp=1; break; fi
    sleep 0.05
    waited=$((waited + 1))
  done
  if [ "$saw_tmp" = "1" ]; then ok "the temp was observed before signalling"
  else no "the temp never appeared, so the interrupt assertions prove nothing"; fi
  kill -TERM "$slim_pid" 2>/dev/null
  # Poll for the adapter to actually go away rather than blocking in `wait`. A
  # bare `wait` on a process that ignores the signal hangs the suite instead of
  # failing it, which is how the trapped version presented.
  # Read the process STATE, not `kill -0`. A background child that has exited
  # stays a zombie until the shell reaps it, and `kill -0` succeeds on a zombie —
  # so a `kill -0` poll here reports "did not terminate" for a process that
  # already did, depending entirely on when bash got round to reaping. That is a
  # test that fails on a busy CI machine and passes locally. An empty state means
  # gone; Z means exited and not yet reaped. Both are termination.
  died=0; waited=0
  while [ "$waited" -lt 60 ]; do
    st=$(ps -o state= -p "$slim_pid" 2>/dev/null | tr -d ' ')
    case "$st" in ""|Z*) died=1; break ;; esac
    sleep 0.05
    waited=$((waited + 1))
  done
  if [ "$died" = "1" ]; then
    ok "a signalled slim terminates instead of ignoring SIGTERM"
  else
    no "a signalled slim did not terminate within 3s"
    kill -9 "$slim_pid" 2>/dev/null
  fi
  wait "$slim_pid" 2>/dev/null
  reap_delegate
  if [ -e "$fifodir/out.jsonl" ]; then
    no "a signalled slim wrote no destination file"
  else
    ok "a signalled slim wrote no destination file"
  fi
else
  ok "mkfifo unavailable here; skipped the interrupt test"
fi

echo "# claude adapter: is-self defers to the one self-pollution predicate"
W="$tmp/root/projects/-bucket/worker.jsonl"
printf '%s\n' '{"type":"user","message":{"content":"Session transcript to analyze (literal absolute path): /x"}}' > "$W"
if "$A" is-self "$W"; then ok "an autodream worker transcript is ours"; else no "an autodream worker transcript is ours"; fi
if "$A" is-self "$S"; then no "a real session is not ours"; else ok "a real session is not ours"; fi

echo "# claude adapter: an unknown subcommand exits 2, never 0"
"$A" not-a-subcommand >/dev/null 2>&1; assert_eq "$?" "2" "unknown subcommand exits 2"

# $tmp and any parked delegate are removed by the EXIT trap, which also covers
# the paths that never reach this line.
printf '\npassed: %s   failed: %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
