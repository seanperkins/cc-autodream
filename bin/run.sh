#!/bin/bash
# Autodream runner — invoked by launchd at ~3am local time.
#
# Two-layer pipeline:
#   L1: For each of yesterday's session JSONLs, spawn a parallel `claude` (AUTODREAM_L1_MODEL, default claude-haiku-4-5)
#       running SESSION_TRIAGE.md → writes one findings.json per session.
#   L2: One `claude --model claude-opus-5-5` running PROMPT.md → reads all findings JSONs,
#       writes $DREAMS_DIR/YYYY-MM-DD.md plus a memory-candidates.json sidecar
#       (proposals only; bin/promote.sh writes accepted ones to Mnemopi).
#
# Usage:
#   ./run.sh             # process yesterday
#   ./run.sh 2026-05-24  # process a specific date
#   FANOUT=4 ./run.sh    # tune L1 parallelism (default 8)
#
# Environment overrides (all optional):
#   CLAUDE_BIN     path to claude CLI                   default: $HOME/.local/bin/claude
#   PROJECTS_DIR   single root: where session JSONLs live (kept for compat; one root)
#                  default: $HOME/.claude/projects
#   SESSION_ROOTS  colon-separated dirs to scan for session JSONLs. Takes precedence
#                  over PROJECTS_DIR. If neither is set, every $HOME/.claude*/projects
#                  that exists is scanned (primary always first) — each CLAUDE_CONFIG_DIR
#                  profile keeps its own projects/ bucket, so one-dir scanning silently
#                  missed sessions recorded under ~/.claude-nous, ~/.claude-ds4, ...
#   AUTODREAM_DIR  scripts + prompts + state           default: $HOME/.claude/autodream
#   DREAMS_DIR     where final reports are written     default: $HOME/.claude/dreams
#   FANOUT         L1 parallelism                      default: 8
#   AUTODREAM_CHANGELOG  set 0 to skip the upstream-changelog check  default: 1
#   CLAUDE_CODE_REPO     persistent cache for the claude-code clone  default: $AUTODREAM_DIR/cache/claude-code
#   CHANGELOG_REMOTE     git remote to clone/pull       default: https://github.com/anthropics/claude-code.git
#   AUTODREAM_L1_ROUNDS  max L1 retry rounds for missing sessions    default: 5
#   AUTODREAM_L2_ATTEMPTS max L2 attempts to produce a report        default: 3
#   AUTODREAM_RETRY_WAIT seconds to pause between retry rounds       default: 60
#   AUTODREAM_NETCHECK   set 0 to skip waiting-for-network on retry  default: 1
#   AUTODREAM_FORCE      set 1 to rebuild even if a report exists    default: 0
#   AUTODREAM_SLIM_BYTES sessions larger than this are slimmed for L1  default: 262144
#   AUTODREAM_L1_MODEL   override the L1 triage model                 default: claude-haiku-4-5
#   AUTODREAM_L1_EFFORT  --effort for the L1 worker (Haiku 4.5 rejects
#                        it; use with Sonnet/Opus/Fable models)       default: unset
#   AUTODREAM_L2_MODEL   override the L2 aggregator model            default: claude-opus-5-5
#   AUTODREAM_L1_CHUNK_BYTES  max bytes of slimmed transcript per L1 worker; a bigger
#                        one is split at line boundaries and merged back. 0 turns
#                        chunking off (head/tail elision).                    default: 300000
#   AUTODREAM_L1_MAX_CHUNKS   over this many chunks the middle is dropped; recorded in the
#                        findings meta and counted as l1_chunks_elided in run-stats  default: 8
#   AUTODREAM_L1_ESCALATE     off | friction | all: which sessions get the stronger
#                        L1 model                                            default: friction
#   AUTODREAM_L1_ESCALATE_MIN    friction score bar (errors + 3 * permission denials)  default: 8
#   AUTODREAM_L1_ESCALATE_MAX    sessions per run, hottest first (friction mode); the cost
#                        ceiling is this times MAX_CHUNKS Opus calls, 6 x 8 by default   default: 6
#   AUTODREAM_L1_ESCALATE_MODEL  model for an escalated session           default: claude-opus-5-5
#   AUTODREAM_MIN_USER_TURNS  noise-gate floor on user_message_count  default: 2
#   AUTODREAM_MIN_MINUTES     noise-gate floor on duration_minutes    default: 1
#   AUTODREAM_STATS_BIN       override the resolved session-stats.sh path, authoritative
#                             (no existability fallback — lets tests force missing or
#                             malformed stats sidecars)                default: unset
#   AUTODREAM_OVERLAP_BIN     override the resolved overlap-stats.sh path, authoritative
#                             (no existability fallback — lets tests force the "not
#                             measured" paths)                        default: unset
#   AUTODREAM_CONFIG     path to the sourced config file             default: $AUTODREAM_DIR/config
#   AUTODREAM_VAULT_DIR  autodream folder inside an Obsidian/synced vault; enables the
#                        inbox note surface + report publishing       default: unset (off)
#   AUTODREAM_VAULT_BIN  override the resolved vault-notes.sh path, authoritative
#   AUTODREAM_XBOOKMARKS_BIN override the resolved x-bookmarks.sh path, authoritative

set -u

CLAUDE_BIN="${CLAUDE_BIN:-$HOME/.local/bin/claude}"
# PROJECTS_DIR's default is applied here AND its explicit-ness is recorded, because the
# resolution order is SESSION_ROOTS > PROJECTS_DIR(explicit) > autodetect. `:-` can't
# tell "unset" from "set to the default", and treating the always-present default as
# explicit would make autodetect unreachable.
PROJECTS_DIR_EXPLICIT=0
if [ -n "${PROJECTS_DIR+x}" ]; then
  PROJECTS_DIR_EXPLICIT=1
  PROJECTS_DIR="${PROJECTS_DIR:-$HOME/.claude/projects}"
else
  PROJECTS_DIR="$HOME/.claude/projects"
fi
AUTODREAM_DIR="${AUTODREAM_DIR:-$HOME/.claude/autodream}"

# ---- Config file ----
# run.sh historically ignored ~/.claude/autodream/config; only review.sh sourced it. That
# was fine while every key it held was review-only, and stopped being fine the moment a
# key had to reach the nightly run (AUTODREAM_VAULT_DIR). Sourced here, after AUTODREAM_DIR
# is resolved — so AUTODREAM_DIR itself must come from the environment, not the config.
#
# The env-wins dance matters: the config uses plain `KEY=value`, so a bare `.` would let
# the file clobber a variable the caller deliberately exported (tests set env, and a run
# invoked as `AUTODREAM_VAULT_DIR= run.sh` to disable the vault must actually disable it).
# Snapshot the exported environment, source, then replay the snapshot: names the caller
# set win, names only the config sets survive.
#
# `set -a` around the source is the other half: the helper scripts below are separate
# processes, so a config key that stays an unexported shell variable reaches nothing.
#
# This whole script runs under `set -u` (top of file), and sourcing a user-edited file
# under nounset means ANY unbound reference in it (e.g. a typo'd
# X_CREDS_FILE=$AUTODREAM_HOME/x-credentials, meaning AUTODREAM_DIR) aborts the shell
# outright — before LOG_DIR or the log() function exist, so nothing reaches the run log
# and no report is produced. The `|| echo WARNING ...` below can't catch that: nounset
# kills the shell rather than making `.` return non-zero. run.sh never sourced this file
# before the vault-notes feature, so a typo that used to be harmless now silently costs
# a night. Two passes fix it without losing the config-key-name diagnostic:
#   1. A throwaway subshell probe sources the config under the SAME `set -u` this
#      script runs under, purely so bash's own error message (which names the exact
#      unbound variable) can be surfaced as a WARNING. A subshell dying from `set -u`
#      does not kill this shell, and nothing it does touches real state.
#   2. The real source runs with nounset OFF, so a bad reference can't abort us — it
#      degrades to an empty expansion for that one reference, and every other key
#      (before or after the bad line) still gets set and exported normally.
AUTODREAM_CONFIG="${AUTODREAM_CONFIG:-$AUTODREAM_DIR/config}"
if [ -f "$AUTODREAM_CONFIG" ]; then
  _env_snapshot=$(export -p)

  # shellcheck disable=SC1090
  _config_probe_err=$(set -a; set -u; . "$AUTODREAM_CONFIG" 2>&1 1>/dev/null)
  if [ -n "$_config_probe_err" ]; then
    echo "WARNING: $AUTODREAM_CONFIG has an unbound variable reference (continuing without it): $_config_probe_err" >&2
  fi

  set +u
  set -a
  # shellcheck disable=SC1090
  . "$AUTODREAM_CONFIG" || echo "WARNING: failed to source $AUTODREAM_CONFIG (continuing)" >&2
  set +a
  set -u
  eval "$_env_snapshot"
  unset _env_snapshot _config_probe_err
fi
DREAMS_DIR="${DREAMS_DIR:-$HOME/.claude/dreams}"
LOG_DIR="$AUTODREAM_DIR/logs"
FANOUT="${FANOUT:-8}"

# Isolated cwd for every `claude --print` worker (see "AI-title stubs" below). The
# workers all read/write by ABSOLUTE path, so their cwd is functionally irrelevant —
# we point it at a dedicated dir purely to redirect Claude Code's session bucket.
# Claude maps the launch cwd to ~/.claude/projects/<cwd with / and . replaced by ->,
# so running from here lands any stray stub in an isolated bucket we own and wipe,
# instead of polluting the user's real -Users-<you> session history.
WORK_DIR="$AUTODREAM_DIR/work"
WORK_BUCKET="$PROJECTS_DIR/$(printf '%s' "$WORK_DIR" | sed 's#[/.]#-#g')"

TARGET_DATE="${1:-$(date -v-1d +%Y-%m-%d)}"
NEXT_DATE=$(date -j -f %Y-%m-%d -v+1d "$TARGET_DATE" +%Y-%m-%d)

FINDINGS_DIR="$AUTODREAM_DIR/findings/$TARGET_DATE"
REPORT_PATH="$DREAMS_DIR/$TARGET_DATE.md"
RUN_LOG="$LOG_DIR/run-$TARGET_DATE.log"
SESSIONS_LIST="$FINDINGS_DIR/sessions.txt"
ESCALATE_LIST="$FINDINGS_DIR/escalate.txt"   # hashes the L1 fan-out sends to the escalation model
ESCALATED=0

# Self-session prune helper — single source of truth for "is this autodream's own
# transcript?". Resolve it next to this script first (works for the repo copy and the
# ~/.claude/autodream symlink), then fall back to the install dir.
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

RUNNER_SRC="${BASH_SOURCE[0]}"
runner_hops=0
# A symlink can point at another symlink, and a target can be relative to the link's own
# directory rather than to $PWD. The hop cap keeps a cycle from hanging the run.
# 8 rather than a bigger round number so the cap is reachable in a test: macOS refuses to
# execute anything behind 16+ links (ELOOP), so a cap at or above that could never fire on
# a script that got far enough to run this code, and an untestable guard is a guess. Linux
# allows 40, where it can genuinely fire. A real install is one hop.
while [ -L "$RUNNER_SRC" ] && [ "$runner_hops" -lt 8 ]; do
  runner_link_dir=$(cd "$(dirname "$RUNNER_SRC")" && pwd) || break
  RUNNER_SRC=$(readlink "$RUNNER_SRC") || break
  case $RUNNER_SRC in /*) ;; *) RUNNER_SRC="$runner_link_dir/$RUNNER_SRC" ;; esac
  runner_hops=$((runner_hops + 1))
done

# Where to look for the libraries below, and it is NOT just SCRIPT_DIR. install.sh
# symlinks each script into ~/.claude/autodream individually, so a merge swaps the
# run.sh those links point at instantly while lib-project.sh, adapters.sh,
# preflight.sh and adapters/ stay missing until install.sh is re-run. Sourcing only
# from SCRIPT_DIR then skips them in silence and the run dies later on
# `session_hash: command not found`, with no report and nothing saying why.
#
# The walk above already resolved this script to its real location, so the repo's
# own bin/ is the fallback. Installed dir first, because that is the layout the
# nightly is supposed to have and the one whose files are meant to win.
RUNNER_BIN_DIR=""
if [ ! -L "$RUNNER_SRC" ]; then
  RUNNER_BIN_DIR=$(cd "$(dirname "$RUNNER_SRC")" 2>/dev/null && pwd) || RUNNER_BIN_DIR=""
fi
# $1=basename -> prints the first readable copy, or nothing.
find_lib() {
  if [ -r "$SCRIPT_DIR/$1" ]; then printf '%s' "$SCRIPT_DIR/$1"; return 0; fi
  if [ -n "$RUNNER_BIN_DIR" ] && [ -r "$RUNNER_BIN_DIR/$1" ]; then
    printf '%s' "$RUNNER_BIN_DIR/$1"; return 0
  fi
  return 1
}

# Harness adapters. run.sh no longer knows which harness it is talking to: it
# asks the adapter to enumerate, normalise, parse and identify. lib-project.sh
# holds the one project encoding every adapter must agree on.
_lib=$(find_lib lib-project.sh) && { # shellcheck source=/dev/null
  . "$_lib"; }
_lib=$(find_lib adapters.sh) && { # shellcheck source=/dev/null
  . "$_lib"; }
PREFLIGHT=$(find_lib preflight.sh) || PREFLIGHT="$SCRIPT_DIR/preflight.sh"
# Shared L1 invocation (prompt assembly + the claude command). Also sourced by the model
# benchmark in bench/, so the benchmark measures this exact call. Every L1 worker needs it.
L1_INVOKE_LIB=$(find_lib l1-invoke.sh) || {
  echo "fatal: l1-invoke.sh not found in $SCRIPT_DIR or the repo bin/ (re-run install.sh)" >&2
  exit 70
}

PRUNE="$SCRIPT_DIR/prune-self-sessions.sh"
[ -x "$PRUNE" ] || PRUNE="$AUTODREAM_DIR/prune-self-sessions.sh"
# Root prober — decides which $HOME/.claude*/projects dirs to scan (see root-probe.sh).
# AUTODREAM_ROOTPROBE_BIN overrides the resolved path (no existability fallback), so
# tests can point it at a stub and exercise the scan fallbacks deterministically.
if [ -n "${AUTODREAM_ROOTPROBE_BIN:-}" ]; then
  ROOT_PROBE="$AUTODREAM_ROOTPROBE_BIN"
else
  ROOT_PROBE="$SCRIPT_DIR/root-probe.sh"
  [ -x "$ROOT_PROBE" ] || ROOT_PROBE="$AUTODREAM_DIR/root-probe.sh"
fi
# Oversized-transcript slimmer (resolved the same way; exported to the L1 workers).
SLIM="$SCRIPT_DIR/slim-transcript.sh"
[ -x "$SLIM" ] || SLIM="$AUTODREAM_DIR/slim-transcript.sh"
# L1 coverage helpers (resolved the same way): the report-day window, the chunker and
# the chunk merge. A session is selected by what is IN it, not by its file mtime, so a
# multi-day orchestrator that is still being written is reviewed one day at a time; a
# transcript too big for one worker is split at line boundaries, one worker per chunk,
# and merged back into the one findings JSON per session that L2 reads.
#
# They are ONE feature: install.sh links all three together, so the only reachable
# states are all present or none (a symlinked run.sh resolves SCRIPT_DIR to the install
# dir, which lacks them until install.sh re-runs). L1_COVERAGE is that single bit. With
# it off there is no window, no chunking and the slimmer keeps its head/tail elision,
# exactly the behaviour before this feature, and tests/run-all.sh pins that state.
SESSION_WINDOW="$SCRIPT_DIR/session-window.sh"
[ -x "$SESSION_WINDOW" ] || SESSION_WINDOW="$AUTODREAM_DIR/session-window.sh"
CHUNKER="$SCRIPT_DIR/chunk-transcript.sh"
[ -x "$CHUNKER" ] || CHUNKER="$AUTODREAM_DIR/chunk-transcript.sh"
MERGER="$SCRIPT_DIR/merge-chunks.sh"
[ -x "$MERGER" ] || MERGER="$AUTODREAM_DIR/merge-chunks.sh"
L1_COVERAGE=0
if [ -x "$SESSION_WINDOW" ] && [ -x "$CHUNKER" ] && [ -x "$MERGER" ]; then L1_COVERAGE=1; fi
# Enumeration passes the adapter an upper date. With a window active the in-transcript
# timestamps decide, so it is far in the future; without one it is the day after the
# report day, the original bounded find. Keeping this a plain argument leaves the adapter
# contract free of any knowledge of the runner window. "Far" is the report day plus five
# years, not a year-9999 sentinel: BSD find cannot parse a distant date (it fails with
# "Can't parse date/time"), which the first version of this found the hard way. If the
# date cannot be computed the window stays off and the original bounded find runs.
ENUM_END="$NEXT_DATE"
WINDOW_ON=0
unset AUTODREAM_WINDOW_START_EPOCH AUTODREAM_WINDOW_END_EPOCH
if [ "$L1_COVERAGE" = 1 ] && _wb=$("$SESSION_WINDOW" bounds "$TARGET_DATE" "$NEXT_DATE" 2>/dev/null) && [ -n "$_wb" ] \
   && _far=$(date -j -f %Y-%m-%d -v+5y "$TARGET_DATE" +%Y-%m-%d 2>/dev/null) && [ -n "$_far" ]; then
  AUTODREAM_WINDOW_START_EPOCH="${_wb%% *}"
  AUTODREAM_WINDOW_END_EPOCH="${_wb##* }"
  export AUTODREAM_WINDOW_START_EPOCH AUTODREAM_WINDOW_END_EPOCH
  WINDOW_ON=1
  ENUM_END="$_far"
fi
# Deterministic session-stat pre-pass (resolved like the other helper scripts).
# AUTODREAM_STATS_BIN overrides the resolved path outright, with no existability
# fallback, for the same reason AUTODREAM_OVERLAP_BIN does below (#26): tests need to
# force a missing or deliberately broken sidecar generator, and the `[ -x ... ] ||`
# chain would rescue a nonexistent override back to the working repo copy (#27).
if [ -n "${AUTODREAM_STATS_BIN:-}" ]; then
  STATS="$AUTODREAM_STATS_BIN"
else
  STATS="$SCRIPT_DIR/session-stats.sh"
  [ -x "$STATS" ] || STATS="$AUTODREAM_DIR/session-stats.sh"
fi
# Global cross-session overlap pass (#14; resolved like the other helper scripts).
# AUTODREAM_OVERLAP_BIN overrides the resolved path outright (no fallback) so tests can
# point it at a nonexistent or stubbed binary and exercise compute_overlap_stats' "not
# measured" paths deterministically — the normal `[ -x ... ] ||` fallback chain would
# otherwise rescue a nonexistent override back to the working repo copy and defeat the
# whole point of the override (#26).
if [ -n "${AUTODREAM_OVERLAP_BIN:-}" ]; then
  OVERLAP="$AUTODREAM_OVERLAP_BIN"
else
  OVERLAP="$SCRIPT_DIR/overlap-stats.sh"
  [ -x "$OVERLAP" ] || OVERLAP="$AUTODREAM_DIR/overlap-stats.sh"
fi
# Operator-note collector and X-bookmark fetcher. Both are context-gatherers for L2 and
# both are opt-in: vault-notes.sh degrades to the plain notes.md when no vault is set,
# x-bookmarks.sh to a "not configured" stub when no credentials exist. Overrides are
# authoritative (no existability fallback) for the same reason as STATS/OVERLAP above —
# tests need to force the missing-helper path.
if [ -n "${AUTODREAM_VAULT_BIN:-}" ]; then
  VAULT_NOTES="$AUTODREAM_VAULT_BIN"
else
  VAULT_NOTES="$SCRIPT_DIR/vault-notes.sh"
  [ -x "$VAULT_NOTES" ] || VAULT_NOTES="$AUTODREAM_DIR/vault-notes.sh"
fi
if [ -n "${AUTODREAM_XBOOKMARKS_BIN:-}" ]; then
  XBOOKMARKS="$AUTODREAM_XBOOKMARKS_BIN"
else
  XBOOKMARKS="$SCRIPT_DIR/x-bookmarks.sh"
  [ -x "$XBOOKMARKS" ] || XBOOKMARKS="$AUTODREAM_DIR/x-bookmarks.sh"
fi
# Provenance of the code actually executing (#29), stamped into run-stats.txt below.
# Resolved by walking this script's own symlink chain rather than by reusing SCRIPT_DIR,
# which is a working directory and not a checkout. install.sh symlinks each script
# individually into ~/.claude/autodream, so that directory is real and has no .git, and
# `cd "$(dirname "$0")"` resolves symlinked *directories* but not a symlinked *file* —
# it lands in the install dir every time. Six of the eight runs through 2026-08-03 wrote
# `runner_commit: unknown` for that reason alone, which is the exact blind spot #29
# existed to close. The two that did stamp a sha were launched from the repo by hand.
# SCRIPT_DIR stays as it is: helper lookup genuinely wants the install dir.
# Everything degrades to "unknown"/"no": a tarball install with no git, or no git binary
# at all, is a supported way to run this and must not fail the run.
# --untracked-files=no on the dirty check: "dirty" is meant to warn that the run used code
# that exists in nobody's history, which only tracked modifications can cause. Counting
# untracked files made the first production run report runner_dirty: yes over a stray
# scratch directory, which is exactly the kind of false alarm that gets a signal ignored.
# Still a symlink means the walk gave up (a cycle, or a chain past the cap) rather than
# arriving anywhere. Resolving the truncated path would stamp whatever checkout it happens
# to sit in, and a confidently wrong sha is worse than no sha at all — the whole point of
# #29 is that this field can be trusted when someone is chasing a bad night.
if [ -L "$RUNNER_SRC" ]; then
  RUNNER_REPO_DIR=""
else
  RUNNER_REPO_DIR=$(cd "$(dirname "$RUNNER_SRC")" && pwd) || RUNNER_REPO_DIR=""
fi
# The empty case has to short-circuit before git rather than lean on git to reject it:
# `git -C "" rev-parse HEAD` does NOT fail, it silently stays in $PWD and answers for
# whatever repo the caller happened to launch from. launchd starts this job from an
# unrelated cwd, so leaving that to git would stamp a stranger's sha and call it
# provenance.
if [ -z "$RUNNER_REPO_DIR" ]; then
  RUNNER_COMMIT=""
else
  RUNNER_COMMIT=$(git -C "$RUNNER_REPO_DIR" rev-parse --short HEAD 2>/dev/null) || RUNNER_COMMIT=""
fi
: "${RUNNER_COMMIT:=unknown}"
if [ "$RUNNER_COMMIT" = "unknown" ]; then
  RUNNER_DIRTY=no
elif [ -n "$(git -C "$RUNNER_REPO_DIR" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
  RUNNER_DIRTY=yes
else
  RUNNER_DIRTY=no
fi

mkdir -p "$FINDINGS_DIR" "$DREAMS_DIR" "$LOG_DIR" "$WORK_DIR"

export PATH="$HOME/.cargo/bin:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
cd "$HOME" || exit 1

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# Every FATAL goes through here so the reason survives to the exit path. A run
# that dies writes no report and posts no banner, and until fatal_exit existed
# that made a failed night completely silent — the log line was the only record,
# and nothing reads the log.
FATAL_REASON=""
log_fatal() { FATAL_REASON="$1"; log "FATAL: $1"; }

# The one exit for a run that cannot continue. Leaves a marker the next run can
# read AND posts a banner now, because those cover different failures: a
# transient cause is caught by the marker when a later night succeeds, while a
# persistent one — a lost exec bit, jq off the launchd PATH — never has a later
# success to be read by, so it needs the banner tonight.
#
# Deliberately NOT a stub report. A report is what the idempotency guard reads as
# "this date is complete", and it is not.
fatal_exit() {
  local reason="${FATAL_REASON:-the run stopped before it produced a report}"
  mkdir -p "$FINDINGS_DIR" 2>/dev/null || true
  # NEVER over a date that already has a report. Moving the claude check below the
  # idempotency guard fixed one call site; the destructive behaviour was still
  # here, and AUTODREAM_FORCE bypasses that guard BY DESIGN — which is the
  # documented `autodream-now.sh <date> --force` path. Any fatal under it would
  # then overwrite that date's full L1/L2 telemetry with a five-line stub and
  # announce a FAILED night while dreams/<date>.md sits there complete.
  # unassembled_dates() would not catch it either, because the report exists.
  #
  # The guard covers the WRITE, and only the write. The first version returned
  # here, which took the banner down with it — and this branch is reachable in
  # exactly one situation, the documented `autodream-now.sh <date> --force`
  # rebuild, which runs detached under launchd where the banner is the only
  # surface an operator sees. jq off the launchd PATH, preflight fatals, no
  # marker (correctly), no banner, and unassembled_dates() skips the date because
  # a report exists: the operator polls dreams/<date>.md, finds the OLD report
  # sitting there, and reads a failed rebuild as a successful one. Nothing about
  # protecting a complete date's telemetry requires staying quiet about the run
  # that just died trying to replace it.
  if [ -s "$REPORT_PATH" ]; then
    log "  not overwriting run-stats.txt: $TARGET_DATE already has a complete report"
    notify_fatal "$reason (the existing report for $TARGET_DATE is unchanged)"
    return 1
  fi
  {
    printf '# Autodream run self-audit — %s\n' "$TARGET_DATE"
    printf 'runner_commit: %s\n' "$RUNNER_COMMIT"
    printf 'runner_dirty: %s\n' "$RUNNER_DIRTY"
    printf 'fatal: %s\n' "$reason"
    printf 'sessions_triaged: 0\n'
  } > "$FINDINGS_DIR/run-stats.txt" 2>/dev/null || true
  notify_fatal "$reason"
  return 1
}

# Both fatal paths post the banner, so the posting lives in one place. Keeping
# two copies is how the guarded path lost its banner in the first place.
notify_fatal() { # $1=reason
  [ -x "$AUTODREAM_DIR/notify.sh" ] || return 0
  "$AUTODREAM_DIR/notify.sh" --failure "$TARGET_DATE" "$1" \
    || log "failure notification returned non-zero (continuing)"
}

# Wipe the isolated worker bucket. Claude Code's async AI-title generation writes a
# one-line `{"type":"ai-title",...}` stub into the launch cwd's session bucket even
# under --no-session-persistence (that flag only suppresses the full transcript). By
# running workers from $WORK_DIR those stubs land in $WORK_BUCKET, which we empty
# before and after every run so they never accumulate in the user's session history.
clean_work_bucket() { rm -rf "$WORK_BUCKET" 2>/dev/null || true; }

# ---- Session-root selection ----
# autodream scans one or more $HOME/.claude*/projects dirs. Resolution order:
#   1. SESSION_ROOTS (colon-separated, set by env/config) — authoritative.
#   2. PROJECTS_DIR — but ONLY when the caller explicitly set it (its default is applied
#      anyway at startup, so an explicit-set flag is what distinguishes a deliberate
#      single-root choice from an unset variable). Kept for backward compatibility.
#   3. Neither: autodetect every $HOME/.claude*/projects that exists, primary
#      ($HOME/.claude/projects) first, via root-probe.sh. If the probe is missing or
#      fails, fall back to the primary dir alone rather than scanning nothing.
# WORK_BUCKET stays keyed off the PRIMARY dir: the lean workers run under the default
# config, so their AI-title stubs land in the default bucket, which the isolation +
# clean_work_bucket above is built around. Scanning extra roots does not change that.
probe_roots() {
  SESSION_ROOTS="${SESSION_ROOTS:-}"
  if [ -z "$SESSION_ROOTS" ] && [ "$PROJECTS_DIR_EXPLICIT" = "1" ]; then
    SESSION_ROOTS="$PROJECTS_DIR"
  fi
  if [ -n "$SESSION_ROOTS" ]; then
    log "session roots: ${SESSION_ROOTS//:/, }"
    return 0
  fi
  if [ -x "$ROOT_PROBE" ]; then
    # Scan the decided roots only: primary + the ones root-choices.conf says index.
    # An unasked root is held out of the report until the user decides on it — that is
    # the point of the flag file (write_unindexed_flag) the report reads: "found a
    # folder we're not indexing." Scanning an undecided folder would make that flag a
    # lie. Folders the user explicitly ignored are likewise skipped.
    SESSION_ROOTS=$("$ROOT_PROBE" --consolidated 2>/dev/null) || SESSION_ROOTS=""
  fi
  # A last-resort default is NOT a configured root. Discovery returning nothing
  # means a fresh host with no store yet, and that has to stay a legitimate quiet
  # night — the all-roots-unavailable fatal below must not fire on a fallback
  # nobody asked for. This flag is what tells the two apart.
  SESSION_ROOTS_ARE_FALLBACK=0
  if [ -z "$SESSION_ROOTS" ]; then
    SESSION_ROOTS="$HOME/.claude/projects"
    SESSION_ROOTS_ARE_FALLBACK=1
  fi
  log "session roots: ${SESSION_ROOTS//:/, }"
}

# Which roots exist but are NOT indexed — written to a flag file so the morning report
# can tell the human a Claude folder appeared that setup never asked about. Never a
# prompt in the unattended run; the report is the surface.
write_unindexed_flag() {
  local flag="$FINDINGS_DIR/unindexed-roots.txt"
  : > "$flag"
  [ -x "$ROOT_PROBE" ] || { printf 'root-probe.sh not found; cannot detect unindexed claude folders\n' > "$flag"; return 0; }
  "$ROOT_PROBE" --unindexed 2>/dev/null >> "$flag" || true
  [ -s "$flag" ] || printf '(none — every $HOME/.claude*/projects dir is indexed)\n' > "$flag"
}

# Find sessions modified during the target day across every session root.
NL=$'\n'            # for the newline-in-path check below
TAB=$'\t'           # ditto; the L1 xargs -I fan-out turns a tab into a space
REJECTED_PATHS=0    # session paths a line-based sessions.txt cannot represent
OUT_OF_WINDOW=0     # files enumerated but holding no record inside the report day
PARTIAL_ROOTS=0     # roots whose enumerator failed but still returned data
ROOTS_CONFIGURED=0  # roots we were told to scan
ROOTS_SCANNED=0     # roots that existed and were walked
ROOTS_UNAVAILABLE=0 # roots that were configured but are not directories
ROOTS_FAILED=0      # roots reached but whose enumeration failed and returned nothing
SESSION_ROOTS_ARE_FALLBACK=0  # 1 when SESSION_ROOTS is the bare default nobody configured
COLLIDED_DROPPED=0  # paths removed from the worklist by collision handling
SIDECAR_STALE_ROWS=0  # provenance rows that could not be rewritten; sessions_by_source is high by this much
DUPLICATE_PATHS=0   # one path reached twice: overlapping roots, or two adapters
HASH_COLLISIONS=0   # two different paths truncating to one artifact hash
SESSIONS_BY_SOURCE=none

# Which roots an adapter scans. The claude adapter uses the roots root-probe
# resolved, because that prober is what decides which $HOME/.claude*/projects
# dirs are indexed and the user's per-folder choices live there. Any other
# adapter uses its own manifest defaults, since root-probe knows nothing about
# a second harness's store.
adapter_roots() { # $1=adapter name -> one root per line
  # Every line MUST be newline-terminated. `while read` drops a final
  # unterminated line, so a printf '%s' here silently skipped the only root on a
  # single-root host — enumeration found nothing and reported it as a quiet zero.
  if [ "$1" = "claude" ]; then
    printf '%s\n' "$SESSION_ROOTS" | tr ':' '\n'
    return 0
  fi
  local roots
  roots=$(adapter_manifest_get "$1" '.session_roots_default[]' 2>/dev/null) || return 0
  [ -n "$roots" ] || return 0
  printf '%s\n' "$roots"
}

# The adapters actually enumerated this run.
#
# The fallback fires ONLY when the adapter machinery is genuinely absent — an
# install symlinked at a tree predating adapters/ — so a partial upgrade degrades
# instead of losing a night. It must NOT fire when the loader ran and accepted
# zero adapters, because that is a refusal: a claude directory rejected for
# failing containment or carrying a mismatched manifest would otherwise be
# manufactured back into the list and executed anyway, which turns every check in
# adapters.sh into decoration.
#
# Until per-session dispatch is adapter-aware, only `claude` may be enabled. The
# rest of the pipeline — the substantive filter, the stats sidecar, the slimmer
# and the L1 engine — is still Claude-specific, so enumerating a second harness
# here would hand its sessions to a Claude parser that reads them as empty and
# drops them silently. Refusing out loud is the honest version of not supporting
# it yet.
# Resolved ONCE into a global, by a function that prints nothing.
#
# The first version of this was a memoised `enabled_adapters` that every caller
# invoked as `$(enabled_adapters)` — so the cache assignment happened inside a
# command substitution and died with the subshell, leaving ENABLED_ADAPTERS_RESOLVED
# at 0 in the parent on every call. The loader re-ran all three times and the
# duplicate warning the memo was written to stop came straight back. Reproduced
# directly: the uncached body ran 3/3 times and the cache stayed empty.
#
# That is precisely the trap adapters.sh's own header documents for
# adapters_rejected, and writing it again a few hundred lines away is why that
# header says a file crosses the boundary and a variable does not. Here the
# boundary is crossed by not creating one: resolve_enabled_adapters assigns the
# global and returns, callers read ENABLED_ADAPTERS.
ENABLED_ADAPTERS=""
ENABLED_ADAPTERS_RESOLVED=0
resolve_enabled_adapters() {
  [ "$ENABLED_ADAPTERS_RESOLVED" = "1" ] && return 0
  ENABLED_ADAPTERS=$(_enabled_adapters_uncached)
  ENABLED_ADAPTERS_RESOLVED=1
  return 0
}
_enabled_adapters_uncached() {
  # "Genuinely absent" means the loader is not sourced OR the adapters tree does
  # not exist — a tarball or partial install. That is a legacy install and it
  # falls back. It is NOT the same as a present tree from which the loader
  # accepted nothing, which is a refusal and must stop the run. Conflating the
  # two is how the first version of this both broke a non-git install test and
  # would have let a rejected adapter run anyway.
  if ! declare -F adapters_list >/dev/null 2>&1 || [ ! -d "$(adapters_root 2>/dev/null)" ]; then
    printf 'claude'; return 0
  fi
  local a
  a=$(adapters_list 2>/dev/null | tr '\n' ' ')
  a="${a% }"
  if [ -z "${a// /}" ]; then
    printf ''                        # tree present, nothing accepted: a refusal
    return 0
  fi
  local one keep=""
  for one in $a; do
    if [ "$one" = "claude" ]; then keep="claude"; else
      # stderr, NOT stdout: this function's stdout is its return channel, and
      # log() is a bare echo. Writing a diagnostic here put the log text into the
      # captured adapter list, where it was word-split into bogus adapter names
      # and also masked the empty-list abort.
      log "  adapter '$one' is enabled but per-session dispatch is not adapter-aware yet; not enumerating it" >&2
    fi
  done
  printf '%s' "$keep"
}

scan_roots() {
  # BOTH lists, checked. build_source_sidecar reads .src, so a raw worklist that
  # holds two colliding paths while .src has lost a row means detection runs over
  # an incomplete input and both paths reach dispatch — the same fail-open
  # overwrite, one stage earlier than the collision index.
  if ! { : > "$SESSIONS_LIST.raw"; } 2>/dev/null \
     || ! { : > "$SESSIONS_LIST.src"; } 2>/dev/null; then
    log_fatal "cannot write the session lists in $FINDINGS_DIR"
    return 1
  fi
  REJECTED_PATHS=0
  local src adapters
  resolve_enabled_adapters
  adapters="$ENABLED_ADAPTERS"
  # The accepted set, resolved once for enumerate_for's per-root gate.
  ACCEPTED_ADAPTERS=$(adapters_list 2>/dev/null)
  if [ -z "${adapters// /}" ]; then
    # Two distinct causes reach here and they need different messages: the
    # loader accepted nothing at all, or it accepted adapters but none of them
    # is claude. Printing the first for the second sends the reader hunting a
    # containment or manifest failure that never happened.
    local accepted; accepted=$(adapters_list 2>/dev/null | tr '\n' ',' | sed 's/,$//')
    if [ -n "$accepted" ]; then
      log_fatal "no usable adapter — accepted [$accepted] but per-session dispatch is claude-only, and claude is not among them. Refusing to scan."
    else
      log_fatal "the adapter loader ran and accepted no adapters (rejected: $(adapters_rejected 2>/dev/null)). Refusing to scan."
    fi
    RAW=0
    # This path is a TOTAL outage with a mundane trigger — adapters/claude/adapter.sh
    # losing its exec bit to a tarball copy, a restrictive umask or
    # core.fileMode=false, since _adapter_ok requires -x. A host that produced a
    # full report last night then produces nothing, every night.
    #
    # The marker and the banner come from fatal_exit in run(), which every fatal
    # path funnels through; log_fatal above is what carries the reason to it.
    return 1
  fi
  for src in $adapters; do
    scan_one_adapter "$src" || return 1
  done
  # Roots were configured and not one of them was reachable. That is a broken
  # SESSION_ROOTS or a vanished store, and it must not read as a quiet night:
  # RAW would be 0, every shortfall counter would be 0, and the stub would say
  # no files were modified. A fresh host with NO roots configured is a different
  # thing and stays legitimate.
  # The fatal is about roots that were never REACHED, and it stays that way.
  # Subtracting ROOTS_FAILED here looked symmetric and was a regression: on a
  # single-root host — the default install — "enumerator exited nonzero and
  # returned nothing" is the exact shape of a quiet date plus any transient find
  # error, a bucket vanishing mid-walk or one unreadable directory (see the note
  # at the enumeration branch). That host would then get no report at all on a
  # night whose honest answer is the empty-night stub.
  #
  # A failed root is not silent without this: it warns in the log, increments
  # roots_failed, reaches run-stats.txt on both the zero-session and full paths,
  # and PROMPT.md's Corpus integrity bullet names it in the morning report. That
  # is the right weight for "we read less than we meant to" — a caveat on the
  # night, not the loss of it.
  if [ "${SESSION_ROOTS_ARE_FALLBACK:-0}" != "1" ] \
     && [ "$ROOTS_CONFIGURED" -gt 0 ] && [ "$ROOTS_SCANNED" -eq 0 ]; then
    log_fatal "all $ROOTS_CONFIGURED configured session root(s) are unavailable; refusing to report an empty night over a store that was never reached"
    return 1
  fi

  # A transcript reachable from two roots (one dir a symlink of another) must be
  # triaged exactly once; the first source to claim a path keeps it.
  sort_unique_inplace "$SESSIONS_LIST.raw" "the session worklist" || return 1
  RAW=$(wc -l < "$SESSIONS_LIST.raw" | tr -d ' ')
}

scan_one_adapter() { # $1=adapter name
  local src="$1" r
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    # SESSION_ROOTS is colon-separated, so a root path containing ':' is unrepresentable:
    # the split above already fragmented it. Catch the symptom — a fragment that is not
    # a directory (or that was split out of one) — and say why it's being skipped rather
    # than silently scanning nothing.
    ROOTS_CONFIGURED=$((ROOTS_CONFIGURED + 1))
    if [ ! -d "$r" ]; then
      ROOTS_UNAVAILABLE=$((ROOTS_UNAVAILABLE + 1))
      log "WARNING: session root is not a directory (possible ':' in path — SESSION_ROOTS is colon-separated): $r"
      continue
    fi
    ROOTS_SCANNED=$((ROOTS_SCANNED + 1))
    # NUL transport for the fan-out, so a path carrying a space, a tab or a glob
    # character survives intact. It does NOT save a path carrying a newline:
    # sessions.txt is line-delimited and stays that way, because the hash
    # assignments in l1_missing_count() and dispatch_l1() key each artifact by
    # sha1 of the whole line, oversized-gate.sh recomputes that same hash from
    # the file, and every archived findings dir depends on the shape. Such a path is currently written as two lines and
    # the runner then invents a session that does not exist, so it is rejected
    # here — before either representation is built — rather than transported.
    # Stage enumeration to a file and CHECK its status. Reading the adapter
    # through process substitution hid the producer's exit code, so a root that
    # failed on permissions or I/O emitted nothing and the run carried on to
    # finalise a cheerful "no sessions" report over a corpus it never saw.
    local nulfile status
    nulfile=$(mktemp "$FINDINGS_DIR/.enum.XXXXXX") || { log_fatal "cannot stage enumeration in $FINDINGS_DIR"; return 1; }
    enumerate_for "$src" "$r" > "$nulfile"
    status=$?
    if [ "$status" -ne 0 ]; then
      # A nonzero status does NOT mean nothing was read. BSD find exits 1 when a
      # single subdirectory is unreadable or vanishes mid-walk while still
      # printing every other match — verified: 3 files, one locked directory,
      # exit 1, two paths printed. Treating that as fatal threw away a usable
      # corpus and produced NO report on a night that previously produced a full
      # one, which is worse than the silent-zero this check exists to catch.
      #
      # So the distinction is output, not status. Nothing read AND a failure is a
      # real enumeration failure and stops the run. Something read with a failure
      # is a partial walk: carry on with what was returned and say so loudly, so
      # a shrinking corpus is visible in the log and the counter rather than
      # being mistaken for a quiet night.
      if [ -s "$nulfile" ]; then
        PARTIAL_ROOTS=$((PARTIAL_ROOTS + 1))
        log "WARNING: enumeration for adapter '$src' at root $r exited $status but returned data; continuing with a possibly INCOMPLETE corpus for this root"
      else
        # Nothing read from THIS root. That is not a reason to throw away the
        # roots that worked. Multi-root scanning is this tool's premise, and a
        # secondary root (~/.claude-nous/projects, ~/.claude-sigint/projects)
        # legitimately matches nothing on a given date — while BSD find exits 1
        # for ANY unreadable subdirectory anywhere in the walk, match or no
        # match. Verified on this host: an unreadable sibling directory makes
        # `find` exit 1 both with and without matches; without it, exit 0. So one
        # permission-denied directory under a quiet secondary root used to kill a
        # night on which the primary root had a full corpus — and kill it
        # invisibly, because run() returned 1 before notify.sh ran and no
        # findings JSONs were written for unassembled_dates() to notice.
        #
        # Count it, say it loudly, carry on. The all-roots-failed case below is
        # what still refuses to report over a store nothing was read from.
        ROOTS_FAILED=$((ROOTS_FAILED + 1))
        log "WARNING: enumeration failed for adapter '$src' at root $r (exit $status) and returned nothing; this root contributes NO sessions to tonight's corpus"
        rm -f "$nulfile"
        continue
      fi
    fi
    while IFS= read -r -d '' sp; do
      # Reject every character the downstream artifacts cannot carry. Verified on
      # this host against the real consumers rather than assumed:
      #   newline    sessions.txt is line-delimited; find writes it as two lines
      #              and the runner then triages a session that does not exist
      #   tab        `xargs -I {}` at the L1 fan-out turns it into a space, so the
      #              worker hashes and opens a path that is not the one enumerated
      #   backslash  the same fan-out deletes it outright
      #   quote      the same fan-out dies with "unterminated quote" and takes the
      #              WHOLE night's dispatch with it, not just this session
      # The last three are a pre-existing limitation of the xargs -I transport, not
      # of this change; an earlier draft accepted tabs because the hash and
      # sessions.txt tolerate them, having checked those two consumers and not the
      # fan-out. Accepting a path the dispatcher then corrupts is worse than
      # refusing it out loud, so these are counted refusals until that transport is
      # NUL-safe.
      case "$sp" in
        *"$NL"*|*"$TAB"*|*\\*|*\"*|*\'*)
          REJECTED_PATHS=$((REJECTED_PATHS + 1))
          log "  skip: session path holds a character the artifact list or the L1 fan-out cannot carry: $(printf '%q' "$sp")"
          continue
          ;;
      esac
      # Report-day window gate. While a window is active enumeration bounds mtime only far
      # into the future, so a file modified after the day is kept only if it has a record
      # INSIDE the day (a multi-day orchestrator). exit 1 = no record in the day, or a file
      # with no clock at all that was modified after the day (its mtime decides, as the
      # bounded find used to): skipped and COUNTED, so it cannot read as a quiet night.
      # exit 0 = yes. Any other status is a helper failure: keep the session, because a
      # broken helper must cost extra work, not drop a session.
      if [ "$WINDOW_ON" = 1 ]; then
        "$SESSION_WINDOW" in-window "$sp" "$AUTODREAM_WINDOW_START_EPOCH" "$AUTODREAM_WINDOW_END_EPOCH" </dev/null >/dev/null 2>&1
        if [ "$?" -eq 1 ]; then
          OUT_OF_WINDOW=$((OUT_OF_WINDOW + 1))
          continue
        fi
      fi
      # Paired writes, both checked. Losing either half desynchronises the
      # worklist from its provenance, and the collision detector reads the
      # provenance half.
      # source FIRST: the adapter name is a validated safe identifier with no tab,
      # so `read -r src sp` lets sp absorb the whole remainder. The reverse order
      # truncated any path holding a tab and silently lost its provenance.
      if ! printf '%s\n' "$sp" >> "$SESSIONS_LIST.raw" 2>/dev/null \
         || ! printf '%s\t%s\n' "$src" "$sp" >> "$SESSIONS_LIST.src" 2>/dev/null; then
        log_fatal "could not record $sp in the session lists"
        # Remove the staging file on THIS exit too. Under AUTODREAM_FORCE=1 the
        # findings dir is reused across reruns, so repeated failures would pile up
        # .enum.* files in the directory the aggregator globs.
        rm -f "$nulfile"
        return 1
      fi
    done < "$nulfile"
    rm -f "$nulfile"
  done < <(adapter_roots "$src")
  return 0
}

# Enumeration for one adapter and one root. Delegates to the adapter when one is
# installed; the inline find is the fallback for an install whose tree predates
# adapters/, so a partial upgrade degrades rather than losing the night.
enumerate_for() { # $1=adapter $2=root -> NUL-delimited paths
  # Gated on the adapter having been ACCEPTED, not merely on adapter.sh being
  # executable: an executable check alone would run a directory that failed
  # containment.
  # ACCEPTED_ADAPTERS is assigned directly in scan_roots. This used to call
  # adapters_list per root, and that walk does two realpaths plus a jq for every
  # adapter directory — repeated work whose answer cannot change mid-run, since
  # nothing writes to adapters/ while the scan is in flight.
  if declare -F adapter_run >/dev/null 2>&1 \
     && printf '%s\n' ${ACCEPTED_ADAPTERS:-} | grep -qxF "$1" \
     && [ -x "$(adapters_root 2>/dev/null)/$1/adapter.sh" ]; then
    # Return the ADAPTER's status, not a literal 0. A `return 0` here silently
    # defeated the caller's status check: enumeration was staged to a file and
    # the exit code examined, and this wrapper handed it a success every time.
    # The suite passed 306 assertions over that, because none of them ran an
    # adapter whose enumerate fails. tests/run-all.sh now has one.
    adapter_run "$1" enumerate "$2" "$TARGET_DATE" "$ENUM_END"
    return $?
  fi
  # The fallback is CLAUDE-ONLY. It hardcodes *.jsonl, and nothing reads
  # session_glob from a manifest, so walking another harness's roots with the
  # Claude glob would return nothing and read as a quiet night — a silent wrong
  # answer rather than a loud one. Unreachable today because only claude is ever
  # enabled, but it becomes live the moment a second adapter ships alongside an
  # install whose adapters/ link is stale, which is the exact skew this fallback
  # exists for.
  if [ "$1" != "claude" ]; then
    log "  no adapter for '$1' and no fallback that knows its session format; this root contributes nothing" >&2
    return 1
  fi
  find "$2" -type f -name '*.jsonl' \
       -newermt "$TARGET_DATE 00:00:00" \
       ! -newermt "$ENUM_END 00:00:00" \
       -print0 2>/dev/null
}

# Source provenance, keyed by the artifact hash rather than tagged into
# sessions.txt. That file stays one bare path per line because the hash
# assignments in l1_missing_count() and dispatch_l1() key each artifact by sha1
# of the WHOLE line, oversized-gate.sh recomputes the same hash from it, and
# every archived findings dir depends on the shape. Adding a field would silently invalidate all of them.
#
# The hash formula is deliberately NOT changed to include the source either, for
# the same reason. Instead the two ways two adapters can land on one artifact are
# detected: the same path claimed twice (a misconfiguration — keep the first),
# and two DIFFERENT paths truncating to one hash (no sensible winner — skip both).
# Sort a file unique, in place, atomically, and report failure.
#
# `sort -u FILE -o FILE` can leave FILE empty or partial when it fails, and every
# consumer downstream then trusts that damaged file. The worklist and the
# collision drop set both used the unchecked form; the drop set was fixed first
# and the worklist was left, which is exactly the kind of half-fix this whole
# review has been catching. One helper, both callers.
sort_unique_inplace() { # $1=file $2=what (for the log)
  local f="$1" what="$2"
  if sort -u "$f" > "$f.su.$$" 2>/dev/null && mv -f "$f.su.$$" "$f" 2>/dev/null; then
    return 0
  fi
  rm -f "$f.su.$$"
  log_fatal "could not deduplicate $what; refusing to continue over a possibly damaged list"
  return 1
}

# Rewrite a file by filtering it, atomically, with EVERY failure accounted for.
#
# This exists because the same three-line pattern was patched site by site across
# four review rounds and each patch closed one hole and left another: the grep
# status was swallowed, then checked but the mv was not, then the mv was guarded
# but its failure was silent. Three copies meant three chances to get it wrong.
#
# Contract: on success the file is replaced. On ANY failure the original is left
# untouched, a reason is logged, and the caller gets a nonzero status so it can
# decide whether that is survivable. grep exit 1 means "no lines matched", which
# for a filter is a legitimate empty result, not an error.
rewrite_filtered() { # $1=file $2=what (for the log) ; remaining args = grep args
  local file="$1" what="$2"; shift 2
  local tmp="$file.rw.$$" grc
  grep "$@" "$file" > "$tmp" 2>/dev/null; grc=$?
  if [ "$grc" -gt 1 ]; then
    rm -f "$tmp"
    log "  WARNING: could not rewrite $what (grep exit $grc); leaving it unchanged"
    return 1
  fi
  if ! mv -f "$tmp" "$file" 2>/dev/null; then
    rm -f "$tmp"
    log "  WARNING: could not replace $what (mv failed); leaving it unchanged"
    return 1
  fi
  return 0
}

build_source_sidecar() {
  local sidecar="$FINDINGS_DIR/sessions-source.txt"
  local seen="$FINDINGS_DIR/.hash-to-path"
  local drop="$FINDINGS_DIR/.collided"
  # Fail closed on the bookkeeping files. If .hash-to-path cannot be written,
  # every path looks unseen and no collision is ever DETECTED; if .collided
  # cannot be appended, the drop set is short and the fatal dedup block below is
  # bypassed. Either way both sessions reach dispatch and overwrite the shared
  # artifact — the failure this whole function exists to prevent, arrived at by
  # a silently unwritable temp file.
  if ! { : > "$sidecar"; } 2>/dev/null || ! { : > "$seen"; } 2>/dev/null \
     || ! { : > "$drop"; } 2>/dev/null; then
    log_fatal "cannot write the provenance bookkeeping files in $FINDINGS_DIR; refusing to run collision detection blind"
    return 1
  fi
  DUPLICATE_PATHS=0; HASH_COLLISIONS=0; SESSIONS_BY_SOURCE=""
  local src sp h prev
  # source FIRST, so a path holding any remaining oddity is absorbed whole by the
  # last variable rather than truncated into it.
  while IFS=$'\t' read -r src sp; do
    [ -n "$sp" ] || continue
    # `|| continue` treated "legitimately absent" (exit 1, dropped at enumeration)
    # and "grep failed" (exit >1) as the same thing. On an I/O error that skips
    # the row silently, so a collision may never be DETECTED at all and the
    # unchanged worklist is dispatched with both paths on one artifact — failing
    # open on the way in to the check that fails closed on the way out.
    grep -qxF "$sp" "$SESSIONS_LIST.raw" 2>/dev/null; local prc=$?
    case "$prc" in
      0) : ;;                # present, carry on
      1) continue ;;         # dropped at enumeration, expected
      *) log_fatal "could not check the worklist for $sp (grep exit $prc); refusing to build provenance over an unreadable list"
         return 1 ;;
    esac
    if ! h=$(session_hash "$sp"); then
      log_fatal "could not derive an artifact hash for $sp; refusing to run collision detection on unusable keys"
      return 1
    fi
    # The stored path is everything after the 12-char hash and its tab, taken by
    # offset rather than by field split, so no delimiter inside the path matters.
    #
    # awk's status is checked: a read error returns empty, which is
    # indistinguishable from "hash unseen". A write-only .hash-to-path passes the
    # truncate and append guards and still cannot be read, so every path would
    # look new, .collided would stay empty, and both colliding sessions reach
    # dispatch.
    if ! prev=$(awk -v k="$h" 'substr($0,1,12)==k {print substr($0,14); exit}' "$seen" 2>/dev/null); then
      log_fatal "could not read the collision index; refusing to detect collisions blind"
      return 1
    fi
    if [ -n "$prev" ]; then
      if [ "$prev" = "$sp" ]; then
        DUPLICATE_PATHS=$((DUPLICATE_PATHS + 1))
        # NOT "claimed by more than one adapter". Only `claude` is ever enabled, and
        # sessions.txt.src is not deduplicated while .raw is sort -u'd, so every
        # duplicate today is one transcript reached through two entries of
        # SESSION_ROOTS — ordinary on a host where root-probe autodetects each
        # $HOME/.claude*/projects and one is a symlink of another. Naming adapters
        # sends the reader after a misconfiguration that does not exist.
        log "  duplicate: $sp was reached more than once (two session roots, or two adapters); keeping the first"
      else
        # Two DIFFERENT paths on one truncated hash. There is no sensible winner,
        # so BOTH are dropped from the worklist. An earlier version logged
        # "skipping both" while skipping neither: it removed the sidecar row and
        # left both paths in sessions.txt.raw, so two workers still raced for one
        # <hash>.json and silently overwrote each other. The log said one thing and
        # the code did another, which is worse than not checking at all.
        HASH_COLLISIONS=$((HASH_COLLISIONS + 1))
        log "  COLLISION: $h maps to two different sessions; dropping both: $prev / $sp"
        if ! printf '%s\n%s\n' "$prev" "$sp" >> "$drop" 2>/dev/null; then
          log_fatal "could not record a collided path for removal; refusing to dispatch two sessions onto one artifact"
          return 1
        fi
        # Rewrite unconditionally. `grep -v` exits 1 when it removes the only line,
        # so a guarded `&& mv` left the stale mapping behind in exactly the
        # single-entry case.
        # DELIBERATELY survivable. A stale provenance row overstates
        # sessions_by_source by one and the helper has already logged why; the
        # worklist, which is not survivable, is handled below.
        #
        # NOT counted here. Incrementing on a failed ATTEMPT is what kept this
        # counter attempt-based: a later rewrite may well remove the row, and a
        # single row may be attempted several times. The count is taken from the
        # final sidecar once, below.
        rewrite_filtered "$sidecar" "the source sidecar" -v "^$h	" || :
      fi
      continue
    fi
    if ! printf '%s\t%s\n' "$h" "$sp" >> "$seen" 2>/dev/null; then
      log_fatal "could not record $sp in the collision index; refusing to detect collisions blind"
      return 1
    fi
    # Fail closed, like every sibling write in this function. A silent `|| :` here
    # drops rows on a full disk, SESSIONS_BY_SOURCE is then computed from the short
    # sidecar below and reported as fact, with no counter and no line saying it is
    # short. This function's own header argues that a silently unwritable file is
    # how you arrive at the failure it exists to prevent.
    if ! printf '%s\t%s\n' "$h" "$src" >> "$sidecar" 2>/dev/null; then
      log_fatal "could not record provenance for $h in $sidecar"
      return 1
    fi
  done < "$SESSIONS_LIST.src" || {
    log_fatal "could not read the session source list; refusing to detect collisions over an unreadable input"
    return 1
  }
  rm -f "$seen"

  # Actually remove the colliding sessions from the worklist. Without this the
  # detection is decorative.
  if [ -s "$drop" ]; then
    # Deduplicate first. The earlier path is appended again for every later
    # collision on the same hash, so three paths sharing one hash produce
    # A,B,A,C — four lines describing three drops. Everything below counts and
    # filters from this file, so the duplicate propagated into the telemetry.
    # BOTH the worklist filter and the post-filter verification read this pattern
    # file, so a damaged one lets a collided path through while everything
    # downstream reports success.
    if ! sort_unique_inplace "$drop" "the collision drop set"; then
      rm -f "$drop"; return 1
    fi

    # The worklist is the one that must FAIL CLOSED. Leaving it unchanged means
    # both colliding paths are still in it, so two workers target one <hash>.json
    # and overwrite each other — exactly what this branch exists to prevent.
    if ! rewrite_filtered "$SESSIONS_LIST.raw" "the worklist" -vxF -f "$drop"; then
      log_fatal "refusing to dispatch two sessions onto one artifact"
      rm -f "$drop"; return 1
    fi
    # Verify the drop rather than trusting an exit code. grep -q returns 1 for
    # "not found", which is what we want, but anything ABOVE 1 is an I/O error
    # and would otherwise take the same success path — failing open on the one
    # check that exists to fail closed.
    grep -qxF -f "$drop" "$SESSIONS_LIST.raw" 2>/dev/null; local vrc=$?
    if [ "$vrc" -ne 1 ]; then
      log_fatal "could not confirm the collided paths are gone from the worklist (grep exit $vrc); refusing to dispatch two sessions onto one artifact"
      rm -f "$drop"; return 1
    fi
    # RAW is the ENUMERATED count and stays that way. Overwriting it with the
    # post-drop worklist size made a forced two-session collision report
    # sessions_found_raw: 0 and "0 session file(s) were enumerated" — telling the
    # reader nothing was there when two things were, and were dropped for cause.
    COLLIDED_DROPPED=$(( $(wc -l < "$drop" | tr -d ' ') ))
    # Their provenance rows go too. Note the narrower claim: this removes rows
    # for COLLISION drops only. build_source_sidecar runs before the self-prune
    # and the empty-session filter, so the sidecar still carries rows for worker
    # transcripts and 0-turn shells that are later excluded. Nothing consumes it
    # yet; the first consumer that joins it against <hash>.json must expect
    # hashes with no findings record.
    while IFS= read -r sp; do
      [ -n "$sp" ] || continue
      h=$(session_hash "$sp") || continue
      # Survivable: a stale row overstates sessions_by_source by one and the
      # helper has already said so. The worklist, which is not survivable, was
      # handled above.
      rewrite_filtered "$sidecar" "the provenance row for $h" -v "^$h	" || :
    done < "$drop"

    # Count stale rows from the FINAL sidecar, over UNIQUE hashes. Two things
    # made the earlier version wrong in both directions: it added a count when a
    # rewrite ATTEMPT failed, and it then iterated dropped PATHS. A two-path
    # collision with one persistent stale row reported 3 — one attempt plus the
    # same hash found twice — and a transient failure a later rewrite had already
    # repaired reported 1 when the honest answer was 0. What the reader needs is
    # how many rows are stale now, so that is what is measured.
    # Stage, THEN sort. `producer || exit 1 | sort -u` is masked: without
    # pipefail sort exits 0 on empty input, so a failing producer produced an
    # empty successful assignment and the metric read 0 — the exact false zero
    # this branch exists to avoid.
    local stale_hashes hstage ok_stage=1
    hstage="$FINDINGS_DIR/.stale-hashes.$$"
    : > "$hstage" 2>/dev/null || ok_stage=0
    if [ "$ok_stage" = "1" ]; then
      while IFS= read -r sp; do
        [ -n "$sp" ] || continue
        if ! session_hash "$sp" >> "$hstage" 2>/dev/null; then ok_stage=0; break; fi
        printf '\n' >> "$hstage" 2>/dev/null || { ok_stage=0; break; }
      done < "$drop"
    fi
    if [ "$ok_stage" = "1" ] && stale_hashes=$(sort -u "$hstage" 2>/dev/null); then
      rm -f "$hstage"
      SIDECAR_STALE_ROWS=0
      local sh grc2
      for sh in $stale_hashes; do
        grep -q "^$sh	" "$sidecar" 2>/dev/null; grc2=$?
        case "$grc2" in
          0) SIDECAR_STALE_ROWS=$((SIDECAR_STALE_ROWS + 1)) ;;
          1) : ;;                       # genuinely absent
          # An error is NOT "absent". Reporting 0 because the check itself broke
          # is the false-clean reading this repo already refuses elsewhere with
          # overlap_measured; say unknown instead.
          *) SIDECAR_STALE_ROWS=unknown; break ;;
        esac
      done
    else
      rm -f "$hstage"
      SIDECAR_STALE_ROWS=unknown
      log "  WARNING: could not compute the stale-row count; reporting it as unknown rather than zero"
    fi
  fi
  rm -f "$drop"

  # Counted from the FINAL sidecar rather than from the loop, because collision
  # resolution removes rows after the fact and a count taken during the walk
  # reported sessions that no longer exist in the worklist.
  SESSIONS_BY_SOURCE=$(awk -F'\t' 'NF>1 {print $2}' "$sidecar" 2>/dev/null | sort | uniq -c \
    | awk 'NF {printf "%s%s=%s", (NR>1?",":""), $2, $1}')
  [ -n "$SESSIONS_BY_SOURCE" ] || SESSIONS_BY_SOURCE="none"
}

# ---- Empty-session filter: drop 0-turn shells before fanout ----
# Most of a quiet night's corpus is auto-opened/aborted sessions that hold no user
# input (observed: ~150 of 163 files on 2026-05-30 were single-line `ai-title` shells).
# They cost an L1 worker each for zero signal. A session is SUBSTANTIVE iff it has at
# least one `user` turn that isn't `isMeta:true`; everything else is skippable. The
# predicate is deliberately conservative — any user turn keeps the session, and a jq
# parse failure keeps it too (bias to triage, never silently drop a real session).
# Reads a session-list file on stdin, prints the substantive subset.
# Disable with AUTODREAM_SKIP_EMPTY=0.
filter_empty_sessions() {
  while IFS= read -r sp; do
    [ -n "$sp" ] || continue
    if session_is_substantive "$sp"; then
      printf '%s\n' "$sp"
    fi
  done
}

# exit 0 = keep (substantive or unparseable), 1 = skip (provably a 0-turn shell).
session_is_substantive() {
  local sp="$1" verdict
  [ -r "$sp" ] || return 0
  verdict=$(jq -s 'if any(.[]; .type=="user" and (.isMeta != true)) then 1 else 0 end' "$sp" 2>/dev/null) || return 0
  [ "$verdict" = "0" ] && return 1
  return 0
}

# ---- Upstream changelog: detect Claude Code releases committed on the target day ----
# Clones (once) and pulls anthropics/claude-code into a persistent cache, then diffs
# CHANGELOG.md over [TARGET_DATE, NEXT_DATE) by real commit date and writes the inserted
# entries into the findings dir for Layer 2 to read. There is no remote `git blame`/`log`,
# so we keep a persistent local cache (not a tmpdir): nightly cost is one delta `git pull`.
# git is the only dependency. Any failure is recorded in the output file, never aborts the
# pipeline. Window matches the session scan exactly, so each release is reported once.
# Disable with AUTODREAM_CHANGELOG=0; point CHANGELOG_REMOTE at a local repo for offline tests.
changelog_window() {
  local out="$FINDINGS_DIR/changelog-window.md"
  [ "${AUTODREAM_CHANGELOG:-1}" != "0" ] || { log "changelog check disabled (AUTODREAM_CHANGELOG=0)"; return 0; }
  command -v git >/dev/null 2>&1 || { log "changelog: git not found; skipping"; return 0; }

  local remote="${CHANGELOG_REMOTE:-https://github.com/anthropics/claude-code.git}"
  local repo="${CLAUDE_CODE_REPO:-$AUTODREAM_DIR/cache/claude-code}"

  if [ -d "$repo/.git" ]; then
    log "changelog: updating cache ($repo)..."
    if ! ( cd "$repo" && git pull --ff-only --quiet ) 2>>"$RUN_LOG"; then
      log "changelog: pull failed"
      printf '# Claude Code changelog\n\nGit pull failed; upstream changes not checked this run.\n' > "$out"
      return 0
    fi
  else
    log "changelog: cloning $remote -> $repo..."
    rm -rf "$repo"
    if ! git clone --quiet "$remote" "$repo" 2>>"$RUN_LOG"; then
      log "changelog: clone failed"
      printf '# Claude Code changelog\n\nGit clone failed; upstream changes not checked this run.\n' > "$out"
      return 0
    fi
  fi

  local head_sha n added
  head_sha=$( cd "$repo" && git rev-parse --short HEAD 2>/dev/null ) || head_sha="?"
  n=$( cd "$repo" && git log --format=%H \
         --since="$TARGET_DATE 00:00:00" --until="$NEXT_DATE 00:00:00" \
         -- CHANGELOG.md 2>/dev/null | wc -l | tr -d ' ' )
  # Inserted changelog lines (new version headers + bullets), oldest-first; strip the
  # diff's leading '+' but drop the '+++ b/CHANGELOG.md' file header.
  added=$( cd "$repo" && git log -p --reverse \
             --since="$TARGET_DATE 00:00:00" --until="$NEXT_DATE 00:00:00" \
             -- CHANGELOG.md 2>/dev/null \
           | grep '^+' | grep -v '^+++' | sed 's/^+//' )

  if [ "${n:-0}" -gt 0 ] && [ -n "$added" ]; then
    {
      printf '# Claude Code changelog — commits in [%s, %s)\n' "$TARGET_DATE" "$NEXT_DATE"
      printf '# Source: %s @ %s\n' "$remote" "$head_sha"
      printf '# Commits touching CHANGELOG.md in window: %s\n\n' "$n"
      printf '%s\n' "$added"
    } > "$out"
    log "changelog: $n commit(s) in window -> $out"
  else
    printf '# Claude Code changelog — commits in [%s, %s)\n# Source: %s @ %s\n\nNo changelog commits in this window.\n' \
      "$TARGET_DATE" "$NEXT_DATE" "$remote" "$head_sha" > "$out"
    log "changelog: no commits in window"
  fi
}

# ---- Sleep/network resilience helpers ----
# A laptop that sleeps mid-run loses the network and whole batches of workers fail
# (this is the common overnight failure: started on a brief wake, slept through the
# run, ~half the workers errored, L2 produced no report). The L1 worker is already
# idempotent — a session with a findings JSON is skipped — so we can just re-dispatch
# the still-missing sessions across wake/sleep cycles until they all land, and retry
# L2 until a report exists. Tunable; network-wait/sleep are disabled in tests.

# A report is COMPLETE when it carries the end-of-document marker PROMPT.md mandates, not
# merely when its path is non-empty. `-s` cannot tell a finished report from one the
# aggregator was killed halfway through writing, and a truncated report satisfies `-s`
# exactly as well as a good one. That mattered three separate ways: the L2 retry loop
# would break after attempt 1 on a partial file, the superseded good copy would be
# deleted, and the consume gate would archive the user's notes and stamp bookmarks read
# against a half-written report. Mid-write death is precisely the sleep-kill scenario all
# of this exists for, so "non-empty" was never the right test. The marker is the last
# thing PROMPT.md emits, which is what makes its presence mean the write reached the end.
#
# Deliberately not `L2_RC -eq 0`: the CLI can exit non-zero after a perfectly good write.
report_complete() {
  [ -s "$REPORT_PATH" ] && grep -q 'autodream:open-questions=' "$REPORT_PATH" 2>/dev/null
}

# $1=adapter name $2=session path -> the project the session belongs to: the directory
# directly under whichever of the adapter's roots holds it. Claude nests transcripts at
# several depths under one bucket (<bucket>/<session>.jsonl, <bucket>/<session>/subagents/
# agent-*.jsonl, <bucket>/<session>/subagents/workflows/wf_*/agent-*.jsonl), and a bucket
# can itself be named "subagents", so no rule based on directory names finds the bucket at
# every depth. A session under none of the adapter's roots falls back to its parent dir.
session_project() {
  local r rest
  if [ -n "$1" ]; then
    while IFS= read -r r; do
      r=${r%/}
      [ -n "$r" ] || continue
      case $2 in
        "$r"/*/*) rest=${2#"$r"/}; printf '%s' "${rest%%/*}"; return 0 ;;
      esac
    done < <(adapter_roots "$1")
  fi
  basename "$(dirname "$2")"
}

# $1=findings dir -> one hash<TAB>project<TAB>cwd row per session in sessions.txt.
# Capture these before any model runs: findings must keep the project and cwd of the
# actual transcript, even if L1 invents a session_path or rewrites the worklist.
#
# A cwd is unusable, and recorded as "?", when the adapter cannot resolve it (usually a
# removed worktree), when it holds a tab or newline, or when its bucket is an encoded path
# (starts with "-") that the cwd does not encode to. Slug buckets from
# CLAUDE_CODE_PROJECT_DIR_NAME (owner-repo) skip that encoding check, because no cwd ever
# encodes to a slug. An adapter cwd is always absolute, so it can never be "?" itself.
session_rows() {
  local dir=$1 s hash src proj cwd
  # A missing worklist must not silently erase the provenance of every finding.
  [ -r "$dir/sessions.txt" ] || return 1
  while IFS= read -r s <&3; do
    [ -n "$s" ] || continue
    hash=$(session_hash "$s") || continue
    src=$(awk -F'\t' -v h="$hash" '$1 == h { print $2; exit }' "$dir/sessions-source.txt" 2>/dev/null)
    proj=$(session_project "$src" "$s")
    case $proj in ''|*$'\t'*|*$'\n'*) continue ;; esac
    cwd="?"
    if [ -n "$src" ]; then
      cwd=$(adapter_run "$src" project "$s" 2>/dev/null </dev/null) || cwd="?"
      [ -n "$cwd" ] || cwd="?"
    fi
    case $cwd in *$'\t'*|*$'\n'*) cwd="?" ;; esac
    case $proj in
      -*) if [ "$cwd" != "?" ] && [ "$(encode_project "$cwd")" != "$proj" ]; then cwd="?"; fi ;;
    esac
    printf '%s\t%s\t%s\n' "$hash" "$proj" "$cwd"
  done 3< "$dir/sessions.txt"
}

net_up() { # exit 0 if the API host is reachable (any HTTP code beats "000" = no route)
  local code
  code=$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' https://api.anthropic.com/ 2>/dev/null)
  [ -n "$code" ] && [ "$code" != "000" ]
}

wait_for_network() { # block until net_up (capped); no-op when AUTODREAM_NETCHECK=0
  [ "${AUTODREAM_NETCHECK:-1}" != "0" ] || return 0
  local waited=0 cap="${AUTODREAM_NETCHECK_CAP:-1800}"
  while ! net_up; do
    [ "$waited" -ge "$cap" ] && { log "network still down after ~${cap}s of checks; proceeding anyway"; return 0; }
    log "waiting for network to return... (${waited}s)"
    sleep 15; waited=$((waited + 15))
  done
}

l1_missing_count() { # count sessions in $SESSIONS_LIST that still have no findings JSON
  local m=0 s h
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    # An unvalidated hash here counts the session missing forever and the retry
    # loop re-dispatches it every round.
    h=$(session_hash "$s") || { m=$((m + 1)); continue; }
    jq -e .findings "$FINDINGS_DIR/$h.json" >/dev/null 2>&1 || m=$((m + 1))
  done < "$SESSIONS_LIST"
  printf '%s' "$m"
}

findings_json_count() {
  find "$FINDINGS_DIR" -type f -name '*.json' ! -name '*.stats.json' ! -name 'memory-candidates.json' 2>/dev/null \
    | wc -l | tr -d ' '
}

compute_session_stats() {
  local session hash stats
  while IFS= read -r session; do
    [ -n "$session" ] || continue
    # A hash failure means no sidecar is written for this session. It is NOT
    # counted here: stats_sidecars_unparseable is initialised to 0 in the
    # oversized-gate loop, which runs after this function, so an increment here
    # would be wiped — and referencing it before that assignment trips `set -u`
    # outright. That loop walks the same sessions.txt and counts this session
    # there, which is why the #27 fix reads the list rather than the sidecar
    # glob. Say it out loud here so the log names the session.
    hash=$(session_hash "$session") || {
      log "  WARNING: could not derive an artifact hash for $session; no stats sidecar will exist for it"
      continue
    }
    stats="$FINDINGS_DIR/$hash.stats.json"
    rm -f "$stats"
    if [ -x "$STATS" ] && "$STATS" "$session" "$stats" >/dev/null 2>&1 \
      && [ -s "$stats" ] && jq -e 'type == "object"' "$stats" >/dev/null 2>&1; then
      echo "stats: $session ($hash)" >&2
    else
      rm -f "$stats"
      echo "stats failed: $session ($hash); continuing without precomputed stats" >&2
    fi
  done < "$SESSIONS_LIST"
}

# ---- Model escalation: spend a stronger L1 model where friction was MEASURED ----
# Haiku missed a real permission-gate finding that Opus reported from the same input
# (one session, one run each; the repo L1 benchmark shows the same direction), and Opus
# costs about 15x as much per run, so it is not the default for every session. The
# decision uses the stats sidecar, which counts is_error tool_result blocks (never a
# grep of the transcript, which would count prose and the system prompt).
#
# The knobs are documented in the header of this file. score = error_result_count + 3 * permission_denial_count. The bar of 8 was calibrated on
# 16 real sessions: quiet ones scored 0-4, the session with the real permission finding
# scored 8, heavy-friction ones 22-71. The cost of an escalated session is per CHUNK, so a
# multi-chunk session costs several calls; the MAX cap counts sessions, not chunks.
# Written once, before any L1 call, so every retry round sends a session to the same model.
select_escalations() {
  . "$L1_INVOKE_LIB"    # l1_noise_gated lives with the other L1 helpers
  local mode="${AUTODREAM_L1_ESCALATE:-friction}" min="${AUTODREAM_L1_ESCALATE_MIN:-8}" max="${AUTODREAM_L1_ESCALATE_MAX:-6}"
  local session hash stats
  ESCALATED=0
  : > "$ESCALATE_LIST" 2>/dev/null || { log "WARNING: cannot write $ESCALATE_LIST; escalation is OFF this run"; return 0; }
  case "$mode" in
    off) return 0 ;;
    friction|all) ;;
    *) log "WARNING: AUTODREAM_L1_ESCALATE=$mode is not off, friction or all; escalation is OFF this run"; return 0 ;;
  esac
  case "$min" in ''|*[!0-9]*) log "WARNING: AUTODREAM_L1_ESCALATE_MIN=$min is not a number; using 8"; min=8 ;; esac
  case "$max" in ''|*[!0-9]*) log "WARNING: AUTODREAM_L1_ESCALATE_MAX=$max is not a number; using 6"; max=6 ;; esac
  while IFS= read -r session; do
    [ -n "$session" ] || continue
    hash=$(session_hash "$session") || continue
    stats="$FINDINGS_DIR/$hash.stats.json"
    # A session the noise gate will skip never reaches a model, so it must not take a slot
    # or be counted (the same predicate the worker uses).
    l1_noise_gated "$stats" && continue
    if [ "$mode" = all ]; then printf '999999\t%s\n' "$hash"; continue; fi
    [ -s "$stats" ] || continue
    jq -r --arg h "$hash" '"\(((.error_result_count // 0) + 3 * (.permission_denial_count // 0)))\t\($h)"' "$stats" 2>/dev/null
  done < "$SESSIONS_LIST" > "$ESCALATE_LIST.scores"
  if [ "$mode" = all ]; then
    cut -f2 "$ESCALATE_LIST.scores" > "$ESCALATE_LIST"
  else
    awk -F'\t' -v min="$min" '$1 + 0 >= min + 0' "$ESCALATE_LIST.scores" \
      | sort -t "$TAB" -k1,1nr -k2,2 | head -n "$max" | cut -f2 > "$ESCALATE_LIST"
  fi
  rm -f "$ESCALATE_LIST.scores"
  ESCALATED=$(wc -l < "$ESCALATE_LIST" | tr -d ' ')
  log "escalation ($mode): $ESCALATED session(s) go to ${AUTODREAM_L1_ESCALATE_MODEL:-claude-opus-5-5}"
}

# ---- Global overlap pass (#14): cross-session "multi-clauding" stat ----
# Runs once compute_session_stats has written every session's *.stats.json sidecar
# (each carries the mechanical user_turn_timestamps array). Overlap is a GLOBAL,
# cross-session computation — it can't be done per-session inside compute_session_stats
# or dispatch_l1's xargs subshells, which only ever see one session at a time. Sets
# OVERLAP_EVENTS / SESSIONS_WITH_OVERLAP (default "0"/"0" on any failure/absence so the
# run-stats.txt writer always has a value, never aborts the pipeline) AND OVERLAP_MEASURED,
# a tri-state marker (#26) so a genuine zero-overlap night can't be confused with a
# non-measurement:
#   1 = a real measurement happened (overlap-stats.sh ran and produced parseable output,
#       even if the answer is 0 pairs / 0 sessions — that is a legitimate result)
#   0 = no measurement happened: the script was missing/not executable, produced no
#       output, or produced output jq couldn't extract both fields from. Each of these
#       gets its own explicit "not measured" log line so a non-measurement is never
#       silently reported as the same "overlap: 0 pair(s)" line as a real zero.
compute_overlap_stats() {
  OVERLAP_EVENTS=0
  SESSIONS_WITH_OVERLAP=0
  OVERLAP_MEASURED=0
  if [ ! -x "$OVERLAP" ]; then
    log "overlap not measured: overlap-stats.sh not found/executable (counts left at 0/0)"
    return 0
  fi
  local json events involved
  json=$("$OVERLAP" "$FINDINGS_DIR" 2>>"$RUN_LOG")
  if [ -z "$json" ]; then
    log "overlap not measured: overlap-stats.sh produced no output (counts left at 0/0)"
    return 0
  fi
  events=$(printf '%s' "$json" | jq -r '.overlap_events // empty' 2>/dev/null)
  involved=$(printf '%s' "$json" | jq -r '.sessions_with_overlap // empty' 2>/dev/null)
  if [ -z "$events" ] || [ -z "$involved" ]; then
    log "overlap not measured: overlap-stats.sh output was unparseable (counts left at 0/0)"
    return 0
  fi
  OVERLAP_EVENTS="$events"
  SESSIONS_WITH_OVERLAP="$involved"
  OVERLAP_MEASURED=1
  log "overlap: $OVERLAP_EVENTS pair(s), $SESSIONS_WITH_OVERLAP session(s) involved"
}

dispatch_l1() { # one parallel pass; idempotent worker → only the still-missing sessions run
  < "$SESSIONS_LIST" xargs -P "$FANOUT" -I {} bash -c '
    session="$1"
    # Same contract as session_hash in the parent, inlined: this is a separate
    # bash -c and the function is not in scope. No apostrophes anywhere in this
    # body — one silently breaks the single-quoted block while bash -n still
    # passes. An empty hash would send every worker to the same artifact.
    hashout=$(printf "%s" "$session" | shasum -a 1 2>/dev/null) || exit 0
    hash=${hashout:0:12}
    case "$hash" in
      [0123456789abcdef][0123456789abcdef][0123456789abcdef][0123456789abcdef][0123456789abcdef][0123456789abcdef][0123456789abcdef][0123456789abcdef][0123456789abcdef][0123456789abcdef][0123456789abcdef][0123456789abcdef]) : ;;
      *) exit 0 ;;
    esac
    output="$FINDINGS_DIR/$hash.json"
    errlog="$output.err"
    . "$L1_INVOKE_LIB"

    # Idempotent, but validate: a non-empty file that is malformed or lacks a
    # top-level findings key is NOT a completed triage (a worker that emitted
    # garbage JSON). Treat it as missing so this pass re-dispatches it, rather
    # than letting it count as done and feed broken records to L2.
    jq -e .findings "$output" >/dev/null 2>&1 && exit 0

    # Validate the session is readable BEFORE spawning a worker. A path that find
    # enumerated but that is gone/unreadable by dispatch time otherwise sends the
    # worker into a cat/wc/Read retry loop. Emit a structured error record instead;
    # this is deterministic, so leaving it in $output (idempotent-skipped on re-run)
    # is correct — retrying would not help.
    if [ ! -r "$session" ]; then
      printf "{\"session_path\":\"%s\",\"error\":\"session file not readable at dispatch\",\"findings\":[]}\n" "$session" > "$output"
      rm -f "$errlog"
      echo "skip (unreadable): $session ($hash)" >&2
      exit 0
    fi

    # ---- Noise gate: skip the L1 model call for low-signal sessions ----
    # Uses the mechanical stats sidecar (session-stats.sh, computed once during
    # enumeration) so gating never needs a model call of its own. Subagent
    # transcripts (isSidechain) and high tool-count sessions are never gated;
    # they are legitimate work, just often short on user turns (see AGENTS.md).
    # An uncomputable duration (0, meaning zero or one timestamped line) never
    # gates on the duration rule alone; bias to triage when it cannot be
    # measured. A missing or unparseable stats sidecar also never gates; bias
    # to triage. Defaults: 2 user turns, 1 minute; either condition alone gates.
    statsfile="$FINDINGS_DIR/$hash.stats.json"
    if l1_noise_gated "$statsfile"; then
      printf "{\"session_path\":\"%s\",\"skipped\":\"below_noise_gate\",\"findings\":[]}\n" "$session" > "$output"
      rm -f "$errlog"
      echo "gated (below noise threshold): $session ($hash)" >&2
      exit 0
    fi

    # Oversized transcripts (multi-MB, base64 images, giant tool outputs) blow the
    # worker token budget so it errors out instead of triaging. Slim those first and
    # point the worker at the reduced copy; small sessions are read verbatim. The
    # findings session_path is rewritten back to the original after a successful run.
    readpath="$session"
    slimfile=""
    sz=$(wc -c < "$session" | tr -d " ")
    # Slim when the file is over the byte threshold, or when a report-day window is
    # set and the file spills outside the day. A small multi-day file would
    # otherwise be read whole and ignore the window.
    need_slim=0
    [ "${sz:-0}" -gt "${AUTODREAM_SLIM_BYTES:-262144}" ] && need_slim=1
    if [ "$need_slim" = 0 ] && [ -n "${AUTODREAM_WINDOW_START_EPOCH:-}" ] && [ -x "${SESSION_WINDOW:-}" ] \
       && "$SESSION_WINDOW" needs-slice "$session" "$AUTODREAM_WINDOW_START_EPOCH" "$AUTODREAM_WINDOW_END_EPOCH" </dev/null >/dev/null 2>&1; then
      need_slim=1
    fi
    # Chunking on (the default) means the slimmer keeps EVERY conversation line and the
    # chunker, not the slimmer, decides how to fit the worker. AUTODREAM_L1_CHUNK_BYTES=0
    # turns it off and restores the old head/tail elision.
    chunk_bytes="${AUTODREAM_L1_CHUNK_BYTES:-300000}"
    slim_full=0
    if [ "$chunk_bytes" -gt 0 ] 2>/dev/null && [ "${L1_COVERAGE:-0}" = 1 ]; then slim_full=1; fi
    if [ "$need_slim" = 1 ] && [ -x "$SLIM" ]; then
      slimfile="$FINDINGS_DIR/$hash.slim.jsonl"
      if AUTODREAM_SLIM_FULL="$slim_full" "$SLIM" "$session" "$slimfile" 2>/dev/null && [ -s "$slimfile" ]; then
        readpath="$slimfile"
        echo "slimmed: $session ($sz bytes) ($hash)" >&2
      else
        rm -f "$slimfile"; slimfile=""
      fi
    fi

    # Pass the paths as LITERAL data (not KEY=value) so the worker hands them
    # straight to the Read/Write tools and never tries to $-expand them in a shell
    # (there is no such env var, so it would expand to nothing and fail — exactly
    # the failure mode that broke earlier runs). Assemble via a brace group piped
    # straight to claude: a `prompt=$(...)` capture strips the trailing newlines,
    # which would glue the SESSION_TRIAGE.md body onto the end of the output-path
    # line and corrupt it. The printf keeps its blank-line separator this way.
    # Launch from the isolated worker cwd so any AI-title stub lands in $WORK_BUCKET,
    # not the real session bucket. All paths below are absolute, so cd is safe here.
    cd "$WORK_DIR" 2>/dev/null || true
    l1_model="${AUTODREAM_L1_MODEL:-claude-haiku-4-5}"
    l1_effort="${AUTODREAM_L1_EFFORT:-}"
    # A session picked by select_escalations gets the escalation model. The base effort
    # belongs to the base model (Haiku rejects --effort outright), so an escalated call
    # runs at the escalation model default effort.
    if [ -s "${ESCALATE_LIST:-/nonexistent}" ] && grep -qxF "$hash" "$ESCALATE_LIST"; then
      l1_model="${AUTODREAM_L1_ESCALATE_MODEL:-claude-opus-5-5}"
      l1_effort=""
      echo "escalated: $session ($hash) -> $l1_model" >&2
    fi
    # Split a slimmed transcript that is bigger than one worker can read. Chunk INPUTS
    # are rebuilt every dispatch (deterministic for an unchanged transcript). Chunk
    # OUTPUTS live under .chunks/ with a non-.json suffix, so nothing that globs the
    # findings directory can mistake one for a session, and are named by the sha1 of
    # their chunk, so a retry reuses an answer only for an identical chunk. Once the
    # chunker has produced chunks the session is chunked even if only ONE was kept (a
    # cap of 1), so the worker reads the retained chunk and never the whole slim file.
    chunked=0; nchunks=1; elided=0; chunkroot=""; l1_blocked=0
    if [ -n "$hash" ]; then chunkroot="$FINDINGS_DIR/.chunks/$hash"; fi
    if [ -n "$slimfile" ] && [ "$slim_full" = 1 ] && [ -n "$chunkroot" ]; then
      ssz=$(wc -c < "$slimfile" | tr -d " ")
      if [ "${ssz:-0}" -gt "$chunk_bytes" ]; then
        maxc="${AUTODREAM_L1_MAX_CHUNKS:-8}"
        case "$maxc" in ""|*[!0-9]*) maxc=0 ;; *) maxc=$((10#$maxc)) ;; esac
        [ "$maxc" -ge 1 ] || { echo "WARNING: AUTODREAM_L1_MAX_CHUNKS=${AUTODREAM_L1_MAX_CHUNKS:-} is not a positive number; using 8" >&2; maxc=8; }
        mkdir -p "$chunkroot/in" 2>/dev/null
        cinfo=$("$CHUNKER" "$slimfile" "$chunkroot/in" "$chunk_bytes" "$maxc" 2>/dev/null) || cinfo=""
        read -r nchunks elided <<< "$cinfo"
        case "$nchunks" in ""|*[!0-9]*) nchunks=0 ;; esac
        case "$elided" in ""|*[!0-9]*) elided=0 ;; esac
        if [ "$nchunks" -ge 1 ]; then
          chunked=1
          echo "chunked: $session ($hash) $nchunks chunks ($elided elided)" >&2
        else
          # The chunker could not run (full disk, unwritable scratch). Do NOT hand one
          # worker the whole uncapped slim, which the slimmer would otherwise have capped:
          # fall back to the old head/tail view, loudly.
          nchunks=1; elided=0
          echo "WARNING: chunker failed for $session ($hash); falling back to the capped head/tail slim" >&2
          if AUTODREAM_SLIM_FULL=0 "$SLIM" "$session" "$slimfile" 2>/dev/null && [ -s "$slimfile" ]; then
            readpath="$slimfile"
          else
            # The capped re-slim failed too: bound the full slim by hand rather than read it
            # uncapped, privately (a session-derived file) and with a numeric cap. If even that
            # fails there is no bounded input, so read nothing this round: the output stays
            # absent, the session is retried, and the final round writes the honest stub.
            cap="${AUTODREAM_SLIM_CAP:-262144}"
            case "$cap" in ""|*[!0-9]*) cap=262144 ;; esac
            if ( umask 077; head -c "$cap" "$slimfile" > "$slimfile.cap" ) 2>/dev/null && mv -f "$slimfile.cap" "$slimfile"; then
              :
            else
              rm -f "$slimfile.cap"; l1_blocked=1
            fi
          fi
        fi
      fi
    fi
    : > "$errlog"
    parts=(); chunk_fail=0; ci=1
    while [ "$ci" -le "$nchunks" ]; do
      if [ "$chunked" = 1 ]; then
        cin=$(printf "%s/in/chunk-%02d.jsonl" "$chunkroot" "$ci")
        csha=$(shasum -a 1 "$cin" | cut -c1-12)
        cout=$(printf "%s/%02d-%s.chunkout" "$chunkroot" "$ci" "$csha")
        cnote=$(l1_chunk_note "$ci" "$nchunks" "$elided")
      else
        cin="$readpath"; cout="$output"; cnote=""
      fi
      if [ "$l1_blocked" = 1 ]; then
        echo "WARNING: no bounded input for $session ($hash); skipping L1 this round" >&2
      elif [ "$chunked" = 1 ] && l1_chunk_ok "$cout"; then
        echo "reuse: chunk $ci/$nchunks of $session ($hash)" >&2
      else
        [ "$chunked" = 1 ] && rm -f "$cout"
        l1_build_prompt "$cin" "$cout" "$AUTODREAM_DIR/SESSION_TRIAGE.md" "$FINDINGS_DIR/$hash.stats.json" "$cnote" \
              | l1_invoke_claude "$l1_model" "$l1_effort" "" \
              > /dev/null 2>> "$errlog"
        # A chunk answer counts only if it is a findings object with no error. Anything
        # else (an error object, no findings, a wrong type) is discarded so the retry
        # round redoes THIS chunk, instead of being cached and merged around.
        if [ "$chunked" = 1 ] && ! l1_chunk_ok "$cout"; then rm -f "$cout"; chunk_fail=1; fi
      fi
      parts+=("$cout")
      ci=$((ci + 1))
    done
    # Merge only when EVERY chunk answered properly. A partial merge would publish a
    # session judged on some of its chunks as if it were all of them; instead $output
    # stays absent, the round retries, and the chunks that answered are reused. A merge
    # that fails anyway drops every cached answer so the next round cannot loop on them.
    if [ "$chunked" = 1 ] && [ "$chunk_fail" = 0 ]; then
      if "$MERGER" --session "$session" --elided "$elided" "${parts[@]}" > "$output.merge" 2>> "$errlog" && [ -s "$output.merge" ]; then
        mv -f "$output.merge" "$output"
      else
        rm -f "$output.merge" "${parts[@]}"
      fi
    fi
    
    if [ -s "$output" ]; then
      # Reported path should be the real session, not the temp slim copy. Then drop
      # the slim file (regenerable; keeps the findings dir clean).
      if [ -n "$slimfile" ]; then
        sed -i "" "s#$slimfile#$session#g" "$output" 2>/dev/null || true
        rm -f "$slimfile"
      fi
      rm -f "$errlog"
      echo "ok: $session ($hash)"
    else
      [ -n "$slimfile" ] && rm -f "$slimfile"
      # Worker exited without writing findings JSON. Record a diagnostic so the
      # failure is visible.
      printf "worker produced no findings JSON for %s (incomplete run: claude exited without writing output)\n" "$session" >> "$errlog"
      # On the FINAL retry round, fall back to a metadata-only findings stub so
      # the session is visible to L1_ERRORED and the L2 aggregator instead of
      # disappearing into a silent .err file (the old behavior, which the
      # 2026-06-11 self-audit flagged: 12 .err with l1_findings_with_error=0).
      # Earlier rounds leave $output absent so the next round can retry; only
      # the last round writes the stub. AUTODREAM_L1_ROUNDS comes through the
      # environment (exported below).
      if [ "${AUTODREAM_CURRENT_ROUND:-1}" -ge "${AUTODREAM_L1_ROUNDS:-5}" ]; then
        sz=$(wc -c < "$session" 2>/dev/null | tr -d " ")
        lines=$(wc -l < "$session" 2>/dev/null | tr -d " ")
        printf "{\"session_path\":\"%s\",\"error\":\"worker exited without findings JSON after %s rounds\",\"meta\":{\"bytes\":%s,\"lines\":%s,\"slimmed\":%s},\"findings\":[]}\n" \
          "$session" "${AUTODREAM_L1_ROUNDS:-5}" "${sz:-0}" "${lines:-0}" "$([ -n "$slimfile" ] && echo true || echo false)" > "$output"
        echo "FAIL (metadata stub written): $session ($hash) — see $errlog" >&2
      else
        echo "FAIL: $session ($hash) — see $errlog" >&2
      fi
    fi
    # Chunk scratch is only worth keeping while a retry is still pending.
    if [ -s "$output" ] && [ -n "$chunkroot" ]; then rm -rf "$chunkroot"; fi
  ' _ {}
}

# Dates in the trailing window whose findings were produced but never assembled into a
# complete report (#36). Echoes a comma-separated list, empty when there are none.
#
# The completeness test is the open-questions marker, not `-s`, for the same reason every
# other consumer uses it: a report killed mid-write is not a report. TARGET_DATE is skipped
# because this run is about to assemble it, and a stub findings dir left by an earlier
# attempt at the same date would otherwise report itself as a failure.
unassembled_dates() {
  local window="${AUTODREAM_UNASSEMBLED_WINDOW:-7}" root="$AUTODREAM_DIR/findings"
  local d date_label report found out=""
  [ -d "$root" ] || return 0
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    date_label=$(basename "$d")
    [ "$date_label" = "$TARGET_DATE" ] && continue
    # Findings JSONs, OR a run-stats.txt carrying `fatal:`. A dir holding nothing
    # but *.stats.json sidecars was never triaged, so it has nothing to assemble
    # and is not a failure — but a dir holding only a fatal marker is a night that
    # died before it could triage anything, which is the case with no other
    # surface at all: no report, no notification, and no findings to rebuild from.
    found=$(find "$d" -maxdepth 1 -type f -name '*.json' ! -name '*.stats.json' ! -name 'memory-candidates.json' 2>/dev/null | head -1)
    local why=""
    if [ -z "$found" ]; then
      # Commas out. PROMPT.md tells L2 to read this value as a comma-separated
      # date list, and the likeliest reason embeds one: the adapter-loader refusal
      # interpolates adapters_rejected, which is itself comma-separated, so
      # `rejected: claude,evil` turned one dead date into three list entries.
      why=$(sed -n 's/^fatal: //p' "$d/run-stats.txt" 2>/dev/null | head -1 | tr ',' ';')
      [ -n "$why" ] || continue
    fi
    report="$DREAMS_DIR/$date_label.md"
    if [ -s "$report" ] && grep -q 'autodream:open-questions=' "$report" 2>/dev/null; then
      continue
    fi
    # Carry the REASON, not just the label. fatal_exit writes it into that date's
    # run-stats.txt, and L2 only ever reads its OWN date's file — so without this
    # the marker was written and never read by anything, and PROMPT.md's "A night
    # that died" bullet was unreachable. The banner was the only working half.
    out="${out:+$out, }$date_label${why:+ (${why})}"
  done < <(find "$root" -maxdepth 1 -type d -name '2[0-9][0-9][0-9]-[0-1][0-9]-[0-3][0-9]' 2>/dev/null \
    | sort | tail -n "$window")
  printf '%s' "$out"
}

run() {
  log "===== autodream start: $(date) ====="
  log "runner: $RUNNER_COMMIT$([ "$RUNNER_DIRTY" = "yes" ] && echo " (dirty)")"
  log "target date: $TARGET_DATE"
  log "findings:    $FINDINGS_DIR"
  log "report:      $REPORT_PATH"
  log "fanout:      $FANOUT"
  log "claude:      $CLAUDE_BIN"

  # ---- Session roots (which $HOME/.claude*/projects dirs we scan) ----
  probe_roots

  # Flag found-but-not-indexed Claude folders for the report (never a prompt here).
  # Written before the idempotency guard on purpose: a catch-up trigger that no-ops for
  # today should still report folders that appeared since setup.
  write_unindexed_flag

  # ---- Dates that were triaged but never assembled (#36) ----
  # A run killed during L2 leaves a full findings dir and no report, and nothing notices:
  # notify.sh never runs, so there is not even a quiet banner. 2026-07-26 sat that way for
  # two days and was found during an unrelated investigation; 2026-08-01 did it again.
  # The catch-up triggers cannot cover it — launchd will not start a second instance of a
  # label that is already running, so a run slow enough to span its own catch-up window
  # turns those triggers into nothing at all.
  #
  # Recovery is cheap whenever the findings survive (`autodream-now.sh <date>` skips
  # straight to L2), so the gap was never the data. It was that nobody was told. This says
  # so in the log and in run-stats.txt, which puts it in the next morning's report.
  UNASSEMBLED=$(unassembled_dates)
  if [ -n "$UNASSEMBLED" ]; then
    log "WARNING: these dates have findings but no complete report: $UNASSEMBLED"
    log "         rebuild one cheaply with: $AUTODREAM_DIR/autodream-now.sh <date>"
  fi

  # ---- Idempotency guard: a finished report means we're done ----
  # A report is only written after a successful L2, so its presence means the date is
  # complete. This makes launchd catch-up/relaunch (the sleep-resilience strategy:
  # multiple wake-time triggers) cheap no-ops once the night succeeded. A run that
  # failed overnight left NO report, so it correctly proceeds and finishes the work.
  if [ -s "$REPORT_PATH" ] && [ "${AUTODREAM_FORCE:-0}" != "1" ]; then
    log "report already exists for $TARGET_DATE ($REPORT_PATH); nothing to do (AUTODREAM_FORCE=1 to rebuild)"
    return 0
  fi

  # The `claude` binary is checked by preflight below, NOT here. An earlier commit
  # moved a `[ -x "$CLAUDE_BIN" ]` test to this spot and its message claimed that
  # made preflight's --l2-bin branch reachable. It did not: this still ran first,
  # and for an absolute path — which CLAUDE_BIN defaults to — `command -v` cannot
  # fail once `[ -x ]` has passed, so the l2_engine branch stayed exercised only by
  # its own test suite. Two gates for one dependency with the second one dead.
  # Preflight owns it, so the check that reports the failure is the one that fires.

  # ---- Preflight: the shared dependencies this script already assumes ----
  # Before anything is ENUMERATED, because the dangerous one fails silently: with
  # shasum absent the artifact hash assignment yields an empty string and every
  # session in the night writes to the same findings filename. A run that got
  # that far would produce one record where it should have produced a hundred
  # and report success. Stopping here costs a night; continuing corrupts one.
  #
  # But BELOW the idempotency guard, which is not enumeration. Above it, a host
  # missing one dependency turned an already-complete date from a one-second
  # no-op into a failed run and an exit 1 on each of the four morning triggers.
  #
  # Gated on -r and invoked through bash, not gated on -x. install.sh's own
  # comment worries about a distribution path that loses the exec bit — a zip, a
  # restrictive umask — and an `[ -x ]` gate answers that by SKIPPING the check
  # silently, which lands you back in exactly the empty-hash corruption preflight
  # exists to stop. A present-but-unreadable preflight says so instead.
  if [ -r "$PREFLIGHT" ]; then
    # Pass the L2 engine. Without it L2_BIN was always empty, so preflight's
    # l2_engine check could only ever fire from its own test suite — a dependency
    # gate with a branch production never reached.
    if ! bash "$PREFLIGHT" --l2-bin "$CLAUDE_BIN" 2>>"$RUN_LOG"; then
      log_fatal "preflight failed; see the MISSING lines in this log. Nothing was enumerated."
      fatal_exit
      return 1
    fi
  else
    log "WARNING: preflight not readable at $PREFLIGHT; the shared-dependency check did NOT run"
  fi

  # ---- Enumerate sessions modified during the target day ----
  log "scanning for sessions modified between $TARGET_DATE and $NEXT_DATE..."
  # Adapter refusals belong with this run's artifacts, not written back into the
  # installed source tree where they persist across runs and vanish entirely on a
  # read-only install.
  export ADAPTERS_REJECT_LOG="$FINDINGS_DIR/.adapters-rejected"
  : > "$ADAPTERS_REJECT_LOG" 2>/dev/null || true
  scan_roots || { fatal_exit; return 1; }
  build_source_sidecar || { fatal_exit; return 1; }

  # Exclude autodream's OWN headless worker/aggregator transcripts. New runs leave none
  # (--no-session-persistence), but runs predating that fix littered ~/.claude/projects/
  # and those files must not be re-triaged. The prune helper owns the predicate; if it's
  # missing, fall back to the raw list rather than silently dropping real sessions.
  if [ -x "$PRUNE" ]; then
    "$PRUNE" --filter < "$SESSIONS_LIST.raw" > "$SESSIONS_LIST" 2>/dev/null || cp "$SESSIONS_LIST.raw" "$SESSIONS_LIST"
  else
    cp "$SESSIONS_LIST.raw" "$SESSIONS_LIST"
  fi
  COUNT_AFTER_PRUNE=$(wc -l < "$SESSIONS_LIST" | tr -d ' ')
  # Subtract the collision drops first. They left the worklist BEFORE the
  # self-prune ran, so charging them to EXCLUDED made a forced two-session
  # collision report self_sessions_excluded: 2 — the report calling files
  # "autodream-own" that were nothing of the kind.
  EXCLUDED=$(( RAW - COLLIDED_DROPPED - COUNT_AFTER_PRUNE ))
  [ "$EXCLUDED" -lt 0 ] && EXCLUDED=0

  # Drop 0-turn shells (auto-opened/aborted sessions with no user input) before fanout.
  # Independent of the self-prune above, so the two telemetry counts don't overlap.
  SKIPPED_EMPTY=0
  if [ "${AUTODREAM_SKIP_EMPTY:-1}" != "0" ]; then
    filter_empty_sessions < "$SESSIONS_LIST" > "$SESSIONS_LIST.nonempty" \
      && mv "$SESSIONS_LIST.nonempty" "$SESSIONS_LIST" \
      || rm -f "$SESSIONS_LIST.nonempty"
  fi
  COUNT=$(wc -l < "$SESSIONS_LIST" | tr -d ' ')
  SKIPPED_EMPTY=$(( COUNT_AFTER_PRUNE - COUNT ))
  log "found $RAW session files; excluded $EXCLUDED autodream-own, skipped $SKIPPED_EMPTY empty; $COUNT to triage; $OUT_OF_WINDOW out of window (modified later, nothing inside the day)"

  if [ "$COUNT" -eq 0 ]; then
    log "no sessions to triage; writing stub report and exiting"
    # A zero-session night is not always an empty night. Every session can be
    # rejected for an unrepresentable path or dropped by collision handling, and
    # this path used to return before run-stats.txt was written — so the report
    # said "no sessions were modified" while the counters that would have
    # contradicted it were never recorded anywhere. Say what was refused.
    # HASH_COLLISIONS counts collision EVENTS and each drops at least two paths,
    # so adding it to a path total understates the loss. Report the two
    # separately rather than inventing a combined figure that is wrong.
    local refused=$(( REJECTED_PATHS + HASH_COLLISIONS ))
    {
      printf '# Autodream run self-audit — %s\n' "$TARGET_DATE"
      printf 'runner_commit: %s\n' "$RUNNER_COMMIT"
      printf 'runner_dirty: %s\n' "$RUNNER_DIRTY"
      printf 'sessions_found_raw: %s\n' "$RAW"
      printf 'sessions_triaged: 0\n'
      # Already computed above and previously omitted here. Without them a night
      # where every session was a worker transcript or an empty shell looks
      # identical to a night with no files at all.
      printf 'self_sessions_excluded: %s\n' "$EXCLUDED"
      printf 'sessions_skipped_empty: %s\n' "$SKIPPED_EMPTY"
      printf 'sessions_out_of_window: %s\n' "$OUT_OF_WINDOW"
      printf 'sessions_rejected_path: %s\n' "$REJECTED_PATHS"
      printf 'sessions_duplicate_path: %s\n' "$DUPLICATE_PATHS"
      printf 'sessions_hash_collision: %s\n' "$HASH_COLLISIONS"
      printf 'sessions_dropped_to_collision: %s\n' "$COLLIDED_DROPPED"
      printf 'sidecar_stale_rows: %s\n' "$SIDECAR_STALE_ROWS"
      # The shortfall counters belong here most of all: this block exists so a
      # zero-triage night does not read as an empty one, and a partial walk or a
      # regression to single-root scanning is exactly what would explain it.
      printf 'roots_partially_enumerated: %s\n' "$PARTIAL_ROOTS"
      printf 'roots_unavailable: %s\n' "$ROOTS_UNAVAILABLE"
      printf 'roots_failed: %s\n' "$ROOTS_FAILED"
      printf 'session_roots: %s\n' "$(( $(printf '%s' "$SESSION_ROOTS" | tr -cd ':' | wc -c) + 1 ))"
      printf 'session_roots_list: %s\n' "$SESSION_ROOTS"
      printf 'adapters_rejected: %s\n' "$(adapters_rejected 2>/dev/null)"
      printf 'adapters_enabled: %s\n' "$(printf '%s' "$ENABLED_ADAPTERS" | tr ' ' ',' | sed 's/,$//')"
      printf 'sessions_by_source: %s\n' "${SESSIONS_BY_SOURCE:-none}"
      # The rest of the key set, emitted as real zeroes rather than omitted.
      # PROMPT.md tells L2 that keys missing from run-stats.txt mean the runner
      # predated the stat, so a zero-session night on CURRENT code produced a
      # morning report blaming a stale checkout for the gap. A night with nothing
      # to triage genuinely did zero L1 rounds and measured no overlap; saying so
      # is different from not saying it.
      # Key names copied from the full-run block below, not invented. The first
      # draft of this emitted l1_missing, oversized_slimmed, overlap_pairs and
      # elapsed — none of which that block writes — which would have left the real
      # keys still missing while adding four L2 has never seen.
      printf 'sessions_dropped_after_failures: 0\n'
      printf 'gated: 0\n'
      printf 'l1_rounds_max: %s\n' "${AUTODREAM_L1_ROUNDS:-5}"
      printf 'l1_escalated: 0\n'
      printf 'l1_escalate_mode: %s\n' "${AUTODREAM_L1_ESCALATE:-friction}"
      printf 'l1_chunks_elided: 0\n'
      printf 'l1_rounds_used: 0\n'
      printf 'l1_findings_written: 0\n'
      printf 'l1_missing_after_retries: 0\n'
      printf 'l1_err_files: 0\n'
      printf 'l1_findings_with_error: 0\n'
      printf 'l1_sessions_already_done_at_start: 0\n'
      printf 'l1_sessions_freshly_processed: 0\n'
      printf 'l1_elapsed_seconds: 0\n'
      printf 'oversized_total: 0\n'
      printf 'oversized_errored: 0\n'
      printf 'oversized_unmeasurable: %s\n' "${OVERSIZED_UNMEASURABLE:-0}"
      printf 'stats_sidecars_unparseable: 0\n'
      # A night with nothing to triage genuinely measured no overlap. That is not
      # the same as the overlap pass having failed, and the zero counts below are
      # the honest pair that goes with it.
      printf 'overlap_measured: no\n'
      printf 'overlap_events: 0\n'
      printf 'sessions_with_overlap: 0\n'
      # EMPTY, not `none`. PROMPT.md defines empty as "none" for this key and tells
      # L2 to name the dates for any non-empty value, so `none` was handed to it as
      # a date list to report.
      printf 'unassembled_dates: %s\n' "${UNASSEMBLED:-}"
    } > "$FINDINGS_DIR/run-stats.txt" 2>/dev/null || true
    cat > "$REPORT_PATH" <<EOF
# Autodream — $TARGET_DATE

No sessions were triaged on this date.

$( if [ "${ROOTS_FAILED:-0}" -gt 0 ] || [ "${ROOTS_UNAVAILABLE:-0}" -gt 0 ]; then
     # A failed root makes "no session files were modified" a claim this run
     # cannot support: it did not read one of the stores it was meant to. The
     # fatal for a single failed root was removed because on a single-root host
     # that shape is a quiet date plus a transient find error, and losing the
     # night is the wrong trade. That is only defensible while the stub refuses
     # to state an empty night as fact.
     # Both classes, and against ROOTS_CONFIGURED rather than ROOTS_SCANNED. A root
     # that was never a directory — a `:` inside a SESSION_ROOTS entry, or a store
     # that moved — was not read either, and it is missing from ROOTS_SCANNED
     # entirely, so measuring against that under-reported how many were configured.
     printf '%s of %s configured session root(s) were unreadable or failed to enumerate, so this run did not read the whole store. Nothing was triaged from what it did read. See roots_failed and roots_unavailable in run-stats.txt — whether this was an empty night is unknown.' \
       "$(( ROOTS_FAILED + ROOTS_UNAVAILABLE ))" "$ROOTS_CONFIGURED"
   elif [ "$RAW" -eq 0 ] && [ "$refused" -eq 0 ]; then
     printf 'No session files were modified.'
   else
     # Refused paths never reach sessions.txt.raw, so they are NOT part of RAW.
     # Folding them into "N session file(s) were modified" produced sentences
     # like "0 session file(s) were modified ... 3 with an unrepresentable path".
     # The two are counted separately because they are separate facts.
     printf 'Nothing was triaged. %s session file(s) were enumerated (%s autodream-own, %s with no substantive turns); a further %s path(s) were refused before enumeration, and %s hash-collision event(s) each dropped two or more paths. See run-stats.txt — this is not an empty night.' \
       "$RAW" "$EXCLUDED" "$SKIPPED_EMPTY" "$REJECTED_PATHS" "$HASH_COLLISIONS"
   fi )

(Generated $(date -u +%Y-%m-%dT%H:%M:%SZ))

<!-- autodream:open-questions=0 -->
EOF
    # A question-free report still counts as a report. Without this the streak
    # store would keep yesterday's questions alive across an empty night, and a
    # question that reappeared two reports later would be called consecutive when
    # it was not. The early return below is why this cannot live at the usual call
    # site next to notify.sh.
    if [ -x "$AUTODREAM_DIR/question-streaks.sh" ]; then
      env AUTODREAM_DIR="$AUTODREAM_DIR" "$AUTODREAM_DIR/question-streaks.sh" update "$REPORT_PATH" "$FINDINGS_DIR" \
        || log "question-streaks returned non-zero (continuing)"
    fi
    return 0
  fi

  # Compute once from the final enumeration. Retry rounds reuse these sidecars;
  # they are intentionally not regenerated during dispatch retries.
  compute_session_stats

  # Global pass: must run AFTER every session's sidecar exists (overlap is a
  # cross-session computation, not per-session). Deliberately BEFORE the noise gate
  # runs inside dispatch_l1 below — gated sessions' sidecars still exist and still
  # participate in overlap (see the comment in bin/overlap-stats.sh).
  compute_overlap_stats
  select_escalations

  # ---- Session provenance, fixed before any model runs ----
  SESSION_ROWS=""
  if ! SESSION_ROWS=$(session_rows "$FINDINGS_DIR"); then
    log "WARNING: could not resolve session provenance; findings cannot be normalized"
  fi

  # ---- Layer 1: triage, parallel, retried across sleep/network gaps ----
  # Lean-query env (claude-cells internal/claude/query.go pattern): keep subscription
  # OAuth auth but strip per-call bloat — no CLAUDE.md auto-load, no telemetry/error
  # reporting. Combined with the per-call flags (--no-session-persistence, --tools,
  # --disable-slash-commands, --strict-mcp-config, --settings disableAllHooks) this is
  # the token-minimal footprint WITHOUT --bare (which would disable OAuth/keychain auth
  # and require an API key). Exported once so both the L1 xargs subshells and the L2
  # call inherit it.
  export CLAUDE_CODE_DISABLE_CLAUDE_MDS=1 DISABLE_TELEMETRY=1 DISABLE_ERROR_REPORTING=1
  export CLAUDE_BIN AUTODREAM_DIR FINDINGS_DIR SLIM SESSION_WINDOW CHUNKER MERGER L1_COVERAGE ESCALATE_LIST WORK_DIR L1_INVOKE_LIB
  # AUTODREAM_L1_ROUNDS is referenced by the dispatcher subshell to decide
  # whether this is the last retry round (gates the metadata-stub fallback).
  export AUTODREAM_L1_ROUNDS

  clean_work_bucket  # start clean: drop any stub left by a prior run's workers

  # Pre-L1 cache snapshot: how many sessions in the worklist already have a valid
  # findings JSON before any worker runs. Without this, a re-run after a partial
  # crash shows an "impossible" l1_elapsed_seconds (e.g. 2s for 36 sessions)
  # because the dispatcher's idempotent skip exits every worker instantly. The
  # aggregator's self-audit needs this to disambiguate "fast run" from "broken
  # timer".
  L1_PRECACHED=$(l1_missing_count)
  L1_PRECACHED=$(( COUNT - L1_PRECACHED ))

  L1_START=$(date +%s)
  L1_ROUNDS="${AUTODREAM_L1_ROUNDS:-5}"
  MISSING=$COUNT
  for round in $(seq 1 "$L1_ROUNDS"); do
    log "L1 triage round $round/$L1_ROUNDS (fanout=$FANOUT)..."
    # The dispatcher's subshell reads this to decide whether the last-round
    # metadata-stub fallback should fire for sessions that produced no output.
    export AUTODREAM_CURRENT_ROUND="$round"
    dispatch_l1
    MISSING=$(l1_missing_count)
    L1_DONE=$(findings_json_count)
    log "L1 round $round: $L1_DONE done, $MISSING still missing"
    [ "$MISSING" -eq 0 ] && break
    if [ "$round" -lt "$L1_ROUNDS" ]; then
      log "L1 retrying $MISSING missing session(s) after a network/sleep check..."
      wait_for_network
      sleep "${AUTODREAM_RETRY_WAIT:-60}"
    fi
  done
  L1_ELAPSED=$(( $(date +%s) - L1_START ))
  L1_OK=$(findings_json_count)
  L1_FAIL=$(ls -1 "$FINDINGS_DIR"/*.json.err 2>/dev/null | wc -l | tr -d " ")
  # In-band failures: a worker that ran to completion but couldn't fit the transcript
  # writes a findings JSON carrying a top-level "error" key (empty findings). These are
  # NOT .json.err files, so l1_err_files=0 masked them — count them explicitly so the
  # self-audit can alarm on a high extraction-failure rate (slimming should drive →0).
  L1_ERRORED=$(find "$FINDINGS_DIR" -type f -name '*.json' ! -name '*.stats.json' ! -name 'memory-candidates.json' \
    -exec grep -l '"error":' {} + 2>/dev/null | wc -l | tr -d " ")
  # Noise-gated sessions: dispatch_l1 wrote a stub instead of calling the model
  # (see the "Noise gate" comment in dispatch_l1). Counted from the findings
  # dir rather than a shared counter, since each gate decision happens inside
  # an independent xargs subshell with no shared state to increment.
  GATED=$(find "$FINDINGS_DIR" -type f -name '*.json' ! -name '*.stats.json' ! -name 'memory-candidates.json' \
    -exec grep -l '"skipped": *"below_noise_gate"' {} + 2>/dev/null | wc -l | tr -d " ")
  # Sessions whose chunk cap dropped the middle: stated in the findings meta and counted
  # here, so a degraded read cannot pass as a complete one.
  L1_CHUNKS_ELIDED=$(find "$FINDINGS_DIR" -maxdepth 1 -type f -name '*.json' ! -name '*.stats.json' ! -name 'memory-candidates.json' \
    -exec jq -e '(.meta.chunks_elided // 0) > 0' {} \; 2>/dev/null | grep -c '^true$')
  log "L1 done in ${L1_ELAPSED}s: $L1_OK done ($L1_ERRORED with errors, $GATED gated), $MISSING missing (.err files: $L1_FAIL)"

  # ---- Oversized-transcript measurement gate (#12) ----
  # Issue #12 proposes chunk-summarizing oversized transcripts instead of slimming them;
  # that implementation is BLOCKED pending evidence it's actually needed. These two
  # counters are the measurement: how many triaged sessions exceeded AUTODREAM_SLIM_BYTES
  # (the same threshold dispatch_l1 checks before calling slim-transcript.sh), and of
  # those, how many still ended in an in-band failure (the same top-level "error" key
  # L1_ERRORED checks above) despite the existing fallback stack (slimming, chunked-Read
  # guidance, metadata-stub path). Gate: if oversized_errored/oversized_total sustains
  # >= 5% over a trailing week, that's the signal issue #12's gate has opened; below that
  # the fallback stack is doing its job. This script only records the counters — the L2
  # self-audit and the human do the trailing-week judgment.
  # Computed post-hoc from the *.stats.json sidecars' transcript_bytes field, same
  # post-hoc pattern as GATED/L1_ERRORED above: the per-worker sz variable at dispatch
  # time (line ~309) lives in an xargs subshell with no shared state to increment
  # directly, so this re-derives it from the sidecar written before dispatch instead.
  #
  # Iterate the SESSION LIST, not the *.stats.json glob (#27). A sidecar that was never
  # written — compute_session_stats deletes the file whenever session-stats.sh fails —
  # is absent from the glob entirely, so the session it belonged to used to drop out of
  # oversized_total without appearing anywhere. Walking the worklist means every triaged
  # session is accounted for exactly once, whatever state its sidecar is in, and stale
  # sidecars left by an earlier enumeration no longer sneak into the count.
  #
  # STATS_SIDECARS_UNPARSEABLE is the shared health signal for every sidecar consumer
  # (#27). One broken sidecar corrupts several counters at once — the noise gate reads
  # the same file inside dispatch_l1 — so the failures are counted once here rather than
  # each stat carrying its own measured/not-measured flag. A sidecar counts as
  # unparseable when it is missing, empty, not valid JSON, or carries no numeric
  # transcript_bytes. The noise gate's own read is deliberately left alone: it already
  # biases to triage on an unreadable sidecar (worst case, a wasted model call), and the
  # only thing missing there was the signal, which this counter now supplies.
  OVERSIZED_TOTAL=0
  OVERSIZED_ERRORED=0
  STATS_SIDECARS_UNPARSEABLE=0
  OVERSIZED_UNMEASURABLE=0
  while IFS= read -r session; do
    [ -n "$session" ] || continue
    # Same reasoning as compute_session_stats above: no hash means no sidecar to
    # UNMEASURABLE: excluded from both counters, exactly as oversized-gate.sh:105
    # does for the same case. An earlier version of this counted it in
    # oversized_total but never in oversized_errored, and its comment claimed that
    # dropping the session biased the #12 gate closed. The reasoning was inverted.
    # The gate is oversized_errored / oversized_total, so padding the DENOMINATOR
    # with sessions whose size was never read pushes the share DOWN and holds the
    # gate closed; dropping one raises it. That version also made the runner and
    # oversized-gate.sh disagree about the same findings dir — run.sh reporting
    # `12 / 0` and GATE CLOSED where the gate tool reported 0 oversized and 12
    # unmeasurable.
    #
    # Nor is it a sidecar parse failure: a session with no derivable key has no
    # sidecar to parse. Conflating the two hid a keying failure inside a counter
    # about file contents, so it gets its own.
    hash=$(session_hash "$session") || {
      OVERSIZED_UNMEASURABLE=$((OVERSIZED_UNMEASURABLE + 1))
      log "  WARNING: could not derive an artifact hash for $session; excluded from the oversized gate as unmeasurable"
      continue
    }
    statsfile="$FINDINGS_DIR/$hash.stats.json"
    sz=""
    [ -s "$statsfile" ] && sz=$(jq -r '.transcript_bytes | numbers | floor' "$statsfile" 2>/dev/null)
    case "$sz" in ''|*[!0-9]*) sz="" ;; esac
    if [ -z "$sz" ]; then
      STATS_SIDECARS_UNPARSEABLE=$((STATS_SIDECARS_UNPARSEABLE + 1))
      # Measure the transcript directly rather than letting the session fall out of the
      # count. transcript_bytes is only ever `wc -c` of this same file (session-stats.sh),
      # and dispatch_l1 sizes it exactly this way before slimming, so this is the same
      # quantity from its original source — not an estimate. A clamped 0 here would bias
      # the #12 gate toward staying closed, which is the whole point of the issue.
      sz=$(wc -c < "$session" 2>/dev/null | tr -d ' ')
      case "$sz" in ''|*[!0-9]*) sz=0 ;; esac
    fi
    if [ "$sz" -gt "${AUTODREAM_SLIM_BYTES:-262144}" ]; then
      OVERSIZED_TOTAL=$((OVERSIZED_TOTAL + 1))
      findingsfile="$FINDINGS_DIR/$hash.json"
      if [ -f "$findingsfile" ] && grep -q '"error":' "$findingsfile" 2>/dev/null; then
        OVERSIZED_ERRORED=$((OVERSIZED_ERRORED + 1))
      fi
    fi
  done < "$SESSIONS_LIST"
  log "oversized: $OVERSIZED_TOTAL session(s) over ${AUTODREAM_SLIM_BYTES:-262144} bytes ($OVERSIZED_ERRORED errored)"
  if [ "$STATS_SIDECARS_UNPARSEABLE" -gt 0 ]; then
    log "stats sidecars unparseable: $STATS_SIDECARS_UNPARSEABLE of $COUNT (sizes fell back to a live read; gated/oversized counts are degraded)"
  fi

  # ---- Normalize the project field deterministically from the session path ----
  # SESSION_TRIAGE.md asks the L1 worker to emit "project" by hand, and the worker does it
  # nondeterministically: one run surfaced the SAME -Users-sean dir as "-Users-sean",
  # "Users-sean" (dash stripped), and even the bare session UUID (filename, not dir).
  # That splinters L2's per-project grouping. The project is the bucket the runner already
  # computed for each session in SESSION_ROWS (see session_rows), before L1 ran. Each findings
  # file is looked up by its own name, the session hash, never by the session_path the model
  # wrote, and its project field is overwritten. Deterministic, idempotent on re-runs.
  if command -v python3 >/dev/null 2>&1; then
    SESSION_ROWS="$SESSION_ROWS" python3 - "$FINDINGS_DIR" <<'PY'
import glob, json, os, sys
findings_dir = sys.argv[1]
projects = {}
for row in os.environ.get("SESSION_ROWS", "").splitlines():
    parts = row.split("\t")
    if len(parts) >= 2 and parts[1]:
        projects[parts[0]] = (parts[1], parts[2] if len(parts) >= 3 and parts[2] != "?" else None)
fixed = 0
for path in glob.glob(os.path.join(findings_dir, "*.json")):
    provenance = projects.get(os.path.basename(path)[:-len(".json")])
    if not provenance:
        continue
    proj, cwd = provenance
    try:
        with open(path) as f:
            data = json.load(f)
    except (ValueError, OSError):
        continue  # malformed JSON: leave for the triage-failures report section
    changed = False
    # Skill calls are mechanical facts from the full transcript, not L1 guesses.
    # Apply on cached findings too so a report rebuild repairs old extraction.
    try:
        with open(path[:-5] + ".stats.json") as f:
            skills = json.load(f).get("skills_invoked")
        if isinstance(skills, list) and all(isinstance(s, str) for s in skills):
            if data.get("skills_invoked") != skills:
                data["skills_invoked"] = skills
                changed = True
    except (ValueError, OSError, AttributeError):
        pass  # Missing/legacy sidecars must not erase previously extracted skills.
    if data.get("cwd") != cwd:
        data["cwd"] = cwd
        changed = True
    if data.get("project") != proj:
        data["project"] = proj
        changed = True
    if changed:
        tmp = path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(data, f)
        os.replace(tmp, path)
        fixed += 1
print(fixed)
PY
    log "normalized project and invoked skills from deterministic evidence"
  else
    log "python3 not found; skipping project-field normalization (L2 grouping may show dupes)"
  fi

  # ---- Self-audit stats: runtime telemetry only the runner can see ----
  # The aggregator can't observe its own machinery — which sessions were autodream's
  # own (already excluded), how many workers failed, how many retry rounds it took.
  # Surface it so PROMPT.md's "Autodream self-audit" section can flag regressions
  # (e.g. the self-pollution exclusion count climbing again) and propose source fixes.
  # Sessions enumerated by find but unaccounted for at run end — not pruned as
  # self/empty, not in findings. This is the gap the 2026-06-11 self-audit
  # caught: 12 .err files existed but stats showed l1_missing_after_retries=0
  # because both denominators counted from the POST-prune sessions.txt. By
  # computing against RAW and subtracting the legitimate prunes, any session
  # lost to a filter mis-classification or silent worker death surfaces here.
  # Bounded at 0 in case of a counting bug in the prunes.
  # Collision drops are deliberate, not failures, and have their own key.
  DROPPED_AFTER_FAILURES=$(( RAW - COLLIDED_DROPPED - L1_OK - EXCLUDED - SKIPPED_EMPTY ))
  [ "$DROPPED_AFTER_FAILURES" -lt 0 ] && DROPPED_AFTER_FAILURES=0
  L1_FRESHLY_PROCESSED=$(( L1_OK - L1_PRECACHED ))
  [ "$L1_FRESHLY_PROCESSED" -lt 0 ] && L1_FRESHLY_PROCESSED=0
  # How many directories we scanned for sessions (colon-count + 1). Kept as its own
  # stat so a regression to single-root scanning is visible from the artifact.
  SESSION_ROOT_COUNT=$(( $(printf '%s' "$SESSION_ROOTS" | tr -cd ':' | wc -c) + 1 ))
  {
    printf '# Autodream run self-audit — %s\n' "$TARGET_DATE"
    # Which code produced this file (#29). install.sh symlinks ~/.claude/autodream/*.sh
    # straight at the repo working tree, so the nightly executes whatever is checked out
    # at 03:15 — a tree sitting behind origin runs old code even though the fix is merged.
    # That has now cost real data twice: the 2026-07-24 overlap-stats.sh dangle, and a
    # tree stuck on a local commit from 2026-07-20 to 2026-07-24 that wrote four nights
    # of run-stats.txt with no oversized_*/gated/overlap_* keys at all. Absent keys are a
    # terrible signal — they read as "this stat did not apply" rather than "this runner
    # predates the stat", and telling those apart took a reflog dig both times. Stamping
    # the commit makes the runner's age legible from the artifact itself.
    printf 'runner_commit: %s\n' "$RUNNER_COMMIT"
    printf 'runner_dirty: %s\n' "$RUNNER_DIRTY"
    printf 'session_roots: %s\n' "$SESSION_ROOT_COUNT"
    printf 'session_roots_list: %s\n' "$SESSION_ROOTS"
    printf 'sessions_found_raw: %s\n' "$RAW"
    # Paths dropped at enumeration because a line-based sessions.txt cannot hold
    # them. Recorded rather than left implicit: a nonzero value here means a real
    # transcript exists that no report will ever mention, which is exactly the
    # kind of silent shortfall this file exists to make visible.
    printf 'sessions_rejected_path: %s\n' "$REJECTED_PATHS"
    # Roots whose enumerator errored yet still returned paths. Nonzero means this
    # night's corpus may be short by an unknown amount — not a failure, but not a
    # clean read either, and the aggregator should not treat the totals as complete.
    printf 'roots_partially_enumerated: %s\n' "$PARTIAL_ROOTS"
    printf 'roots_unavailable: %s\n' "$ROOTS_UNAVAILABLE"
    printf 'roots_failed: %s\n' "$ROOTS_FAILED"
    # Which harnesses produced this night's corpus. A source that drops to zero
    # on a day the user worked in it is the signal that its ingest broke, and
    # that is invisible without a per-source count.
    printf 'adapters_enabled: %s\n' "$(printf '%s' "$ENABLED_ADAPTERS" | tr ' ' ',' | sed 's/,$//')"
    # Refusals that still left claude accepted are otherwise completely silent —
    # a third-party adapter failing containment, a mismatched manifest name, a
    # lost exec bit. Same silent-shortfall class as overlap_measured and
    # stats_sidecars_unparseable: the value is that a zero here means something.
    printf 'adapters_rejected: %s\n' "$(adapters_rejected 2>/dev/null)"
    printf 'sessions_by_source: %s\n' "$SESSIONS_BY_SOURCE"
    printf 'sessions_duplicate_path: %s\n' "$DUPLICATE_PATHS"
    printf 'sessions_hash_collision: %s\n' "$HASH_COLLISIONS"
    printf 'self_sessions_excluded: %s\n' "$EXCLUDED"
    printf 'sessions_skipped_empty: %s\n' "$SKIPPED_EMPTY"
    printf 'sessions_out_of_window: %s\n' "$OUT_OF_WINDOW"
    printf 'sessions_triaged: %s\n' "$COUNT"
    # Sessions within sessions_triaged that were skipped before any model call
    # (noise gate). Structurally cannot appear in l1_findings_with_error since
    # they never reached a model; the self-audit denominator for the
    # extraction-failure rate must subtract this out.
    printf 'gated: %s\n' "$GATED"
    # vs.-raw denominator: a session lost to ANY path (prune mis-classification,
    # silent worker death, slim leftovers) shows up here. Always >= 0; if
    # nonzero, the aggregator should investigate even when l1_missing=0.
    printf 'sessions_dropped_to_collision: %s\n' "$COLLIDED_DROPPED"
    printf 'sidecar_stale_rows: %s\n' "$SIDECAR_STALE_ROWS"
    printf 'sessions_dropped_after_failures: %s\n' "$DROPPED_AFTER_FAILURES"
    printf 'l1_rounds_used: %s\n' "$round"
    printf 'l1_rounds_max: %s\n' "$L1_ROUNDS"
    printf 'l1_escalated: %s\n' "$ESCALATED"
    printf 'l1_escalate_mode: %s\n' "${AUTODREAM_L1_ESCALATE:-friction}"
    printf 'l1_chunks_elided: %s\n' "$L1_CHUNKS_ELIDED"
    printf 'l1_findings_written: %s\n' "$L1_OK"
    printf 'l1_findings_with_error: %s\n' "$L1_ERRORED"
    # Oversized-transcript measurement gate (#12) — see the computation above L1_ERRORED
    # for the gate meaning (M/N >= 5% over a trailing week opens issue #12).
    printf 'oversized_total: %s\n' "$OVERSIZED_TOTAL"
    printf 'oversized_errored: %s\n' "$OVERSIZED_ERRORED"
    printf 'oversized_unmeasurable: %s\n' "${OVERSIZED_UNMEASURABLE:-0}"
    # Sidecar health (#27): how many of sessions_triaged had a stats sidecar that was
    # missing, empty, or carried no numeric transcript_bytes. Every consumer of the
    # sidecars degrades when this is non-zero — `gated` under-counts (an unreadable
    # sidecar never gates, by design) and the oversized sizes came from a live read
    # rather than the sidecar — so it caveats those two keys rather than duplicating
    # a flag onto each of them.
    printf 'stats_sidecars_unparseable: %s\n' "$STATS_SIDECARS_UNPARSEABLE"
    printf 'l1_missing_after_retries: %s\n' "$MISSING"
    printf 'l1_err_files: %s\n' "$L1_FAIL"
    # Cached vs. fresh: lets the aggregator distinguish a sub-second "elapsed"
    # caused by everything already being done from a broken timer.
    printf 'l1_sessions_already_done_at_start: %s\n' "$L1_PRECACHED"
    printf 'l1_sessions_freshly_processed: %s\n' "$L1_FRESHLY_PROCESSED"
    printf 'l1_elapsed_seconds: %s\n' "$L1_ELAPSED"
    # Global cross-session overlap stat (#14) — see compute_overlap_stats above.
    # overlap_measured (#26) disambiguates a genuine zero-overlap night from the
    # script not running/producing usable output; the two count keys are always
    # emitted (0 when unmeasured) so existing consumers never hit a missing key.
    printf 'overlap_measured: %s\n' "$([ "$OVERLAP_MEASURED" = "1" ] && echo yes || echo no)"
    printf 'overlap_events: %s\n' "$OVERLAP_EVENTS"
    printf 'sessions_with_overlap: %s\n' "$SESSIONS_WITH_OVERLAP"
    # Other dates that were triaged and never assembled (#36). Empty means none in the
    # window, which is the reading that matters — this is the key that gets a killed run
    # noticed the next morning instead of during an unrelated investigation two days on.
    printf 'unassembled_dates: %s\n' "${UNASSEMBLED:-}"
  } > "$FINDINGS_DIR/run-stats.txt"

  # ---- Upstream changelog window (writes changelog-window.md for L2 to read) ----
  changelog_window

  # ---- Operator notes (writes operator-notes.md for L2 to read) ----
  # Merges every capture surface — the terminal-written notes.md and the vault inbox —
  # into one file so PROMPT.md reads a single path. Adding a surface is a change to
  # vault-notes.sh, never to the prompt. Best-effort: a broken vault must not cost the
  # report, so failure here logs and continues.
  if [ -x "$VAULT_NOTES" ]; then
    "$VAULT_NOTES" collect "$FINDINGS_DIR" || log "operator-note collection failed (continuing)"
  else
    log "vault-notes.sh not found at $VAULT_NOTES; skipping operator-note collection"
  fi

  # ---- X bookmarks (writes x-bookmarks.md for L2 to read) ----
  # Unread bookmarks become idea fuel: L2 cross-references what the user saved against
  # what they actually worked on. The script always exits 0 and always writes the file,
  # including a "not configured" stub, so this seam has exactly one shape for L2.
  if [ -x "$XBOOKMARKS" ]; then
    "$XBOOKMARKS" collect "$FINDINGS_DIR" || log "x-bookmark collection failed (continuing)"
  else
    log "x-bookmarks.sh not found at $XBOOKMARKS; skipping bookmark collection"
  fi

  # ---- Was the queryId scraping walk actually exercised tonight? (#38) ----
  # The walk against X's JS bundle is the one part of the fetcher with no test, and the
  # part most likely to break, since it turns on X's bundle layout rather than on anything
  # here. A cached id produces a working fetch without proving the walk still works, so
  # `cache` and `fresh` have to be told apart or a walk that stopped working stays hidden
  # until the cache expires. Appended rather than written above because the collector that
  # knows the answer runs after run-stats.txt is closed; the key is always emitted so a
  # consumer never has to handle it being absent.
  XQID_SOURCE=not_attempted
  if [ -s "$FINDINGS_DIR/x-bookmarks-queryid.txt" ]; then
    XQID_SOURCE=$(tr -d '[:space:]' < "$FINDINGS_DIR/x-bookmarks-queryid.txt")
    [ -n "$XQID_SOURCE" ] || XQID_SOURCE=not_attempted
  fi
  printf 'x_queryid_source: %s\n' "$XQID_SOURCE" >> "$FINDINGS_DIR/run-stats.txt"

  # ---- Layer 2: opus aggregate, retried until a report lands ----
  # The aggregator call can also die to a mid-run sleep (this is what left exit 1 +
  # "no report" overnight). Retry until $REPORT_PATH is non-empty, waiting for the
  # network between attempts. Idempotent: a re-run overwrites the report harmlessly.
  # Keep the approved effective default; the expired Fable date cutoff is gone.
  # AUTODREAM_L2_MODEL still wins, including an exported override over the config.
  # Record the requested model, not a claim about the CLI's actual selection:
  # an unrecognized model name can silently fall back inside the CLI.
  L2_MODEL="${AUTODREAM_L2_MODEL:-claude-opus-5-5}"
  log "L2 model: $L2_MODEL"
  printf 'l2_model: %s\n' "$L2_MODEL" >> "$FINDINGS_DIR/run-stats.txt"

  # ---- Move a stale report aside before attempting L2 ----
  # The only way to reach this line with $REPORT_PATH already non-empty is
  # AUTODREAM_FORCE=1 (the idempotency guard above returns early otherwise): a previous
  # run of this same TARGET_DATE left a report on disk and we're rebuilding. Nothing
  # below distinguishes "this run wrote it" from "it was already there" — the retry
  # loop's `[ -s "$REPORT_PATH" ] && break` and the consume gate further down both just
  # stat the path. Left in place, an old report satisfies BOTH: the retry loop stops
  # after attempt 1 even though this run's L2 never wrote anything, and the consume
  # gate then archives the vault note / marks bookmarks read as if something had
  # actually read them. That's the exact overnight failure mode this script is built
  # around (Mac sleeps mid-run, every L2 attempt fails) turning into silent,
  # unrecoverable data loss for the user's notes and bookmarks. Move the old file aside
  # first so `-s "$REPORT_PATH"` again means "this run produced it" for both checks.
  # Moved aside, not deleted: if every L2 attempt below still fails, the user's last
  # good report for this date must stay recoverable, not vanish.
  # CONSUME_SAFE is the whole point of this block, not a side effect of it. If the move
  # fails we are back in precisely the state the move exists to prevent: an old report
  # sitting at $REPORT_PATH that a failed L2 will let the retry loop and the consume gate
  # both mistake for this run's output. Continuing anyway would archive unread notes and
  # stamp bookmarks read against a report nothing produced — the silent, unrecoverable
  # loss this is all guarding. So a failed move disarms consuming for the run rather than
  # logging a warning and carrying on.
  CONSUME_SAFE=1
  if [ -s "$REPORT_PATH" ]; then
    STALE_REPORT="$REPORT_PATH.stale-$(date +%s)"
    if mv "$REPORT_PATH" "$STALE_REPORT"; then
      log "existing report for $TARGET_DATE moved aside to $STALE_REPORT before rebuilding (AUTODREAM_FORCE=1)"
    else
      log "WARNING: could not move the existing report aside; this run will NOT archive notes or mark bookmarks read, because a stale report can no longer be told apart from a fresh one"
      STALE_REPORT=""
      CONSUME_SAFE=0
    fi
  fi

  L2_ATTEMPTS="${AUTODREAM_L2_ATTEMPTS:-3}"
  L2_START=$(date +%s)
  L2_RC=1
  for attempt in $(seq 1 "$L2_ATTEMPTS"); do
    log "L2 aggregation attempt $attempt/$L2_ATTEMPTS..."
    # Preserve proposals from an earlier run/attempt, but never pair them with a
    # new report. A complete report must describe only its own candidate sidecar.
    if [ -e "$FINDINGS_DIR/memory-candidates.json" ]; then
      if STALE_CANDIDATES=$(mktemp "$FINDINGS_DIR/memory-candidates.json.stale-XXXXXX") \
         && mv -f "$FINDINGS_DIR/memory-candidates.json" "$STALE_CANDIDATES"; then
        log "moved earlier memory candidates aside before this attempt"
      else
        log "WARNING: could not move earlier memory candidates aside; stopping L2 rather than presenting stale proposals"
        if [ -n "${STALE_CANDIDATES:-}" ] && [ -f "$STALE_CANDIDATES" ] && [ ! -s "$STALE_CANDIDATES" ]; then
          rm -f "$STALE_CANDIDATES"
        fi
        L2_RC=1
        break
      fi
    fi
    # Same literal-path framing and brace-group assembly as L1 (see the L1 worker
    # comment): keep the paths as literal data the aggregator hands to Glob/Read/Write,
    # and preserve the blank-line separator before PROMPT.md instead of letting a
    # `prompt=$(...)` capture strip it and glue the doc onto the report-path line.
    # Subshell so the cwd change (isolating the AI-title stub into $WORK_BUCKET, same
    # as L1) is scoped to this call and doesn't leak into the notification steps below.
    # $? after the subshell is the pipeline's exit (claude's), exactly as before.
    (
      cd "$WORK_DIR" 2>/dev/null || true
      {
        printf "Findings directory to aggregate (literal absolute path): %s\n" "$FINDINGS_DIR"
        printf "Write the report to this literal absolute path: %s\n\n" "$REPORT_PATH"
        cat "$AUTODREAM_DIR/PROMPT.md"
      } | "$CLAUDE_BIN" \
        --print \
        --permission-mode bypassPermissions \
        --model "$L2_MODEL" \
        --no-session-persistence \
        --tools Glob Read Write Edit \
        --disable-slash-commands \
        --strict-mcp-config \
        --settings '{"disableAllHooks":true}' \
        --append-system-prompt "Headless aggregator. Read the per-session findings JSONs from the findings directory given on line 1 of the prompt, then write the report, via the Write tool, to the literal report path given on line 2. Those paths are literal strings, not shell variables — never \$-expand them. The only files you write are the report and memory-candidates.json in the findings directory; never read or edit MEMORY.md or write any project file. Print report path and 3-line summary, then exit."
    )

    L2_RC=$?
    report_complete && break
    if [ -s "$REPORT_PATH" ]; then
      log "L2 attempt $attempt left a report with no open-questions marker — treating it as truncated and retrying (exit $L2_RC)"
    else
      log "L2 attempt $attempt wrote no report (exit $L2_RC)"
    fi
    if [ "$attempt" -lt "$L2_ATTEMPTS" ]; then
      wait_for_network
      sleep "${AUTODREAM_RETRY_WAIT:-60}"
    fi
  done
  clean_work_bucket  # all workers have exited; remove their AI-title stubs

  L2_ELAPSED=$(( $(date +%s) - L2_START ))
  log "L2 done in ${L2_ELAPSED}s (exit $L2_RC, $attempt attempt(s))"

  # ---- A truncated report must not become the permanent one ----
  # Every attempt can leave a marker-less file behind (killed mid-write, each time), and
  # nothing below removes it. The idempotency guard at the top of run() tests `-s` alone,
  # so the very next launchd catch-up trigger would see a non-empty report, log "nothing
  # to do", and return — the multi-trigger retry design silently disarmed by the file it
  # exists to replace, with a half-written report standing as the day's output forever.
  # That is the same "non-empty is not complete" error as the other three consumers, at a
  # fourth site, and it is the one that makes the mistake permanent rather than one-night.
  #
  # Move it aside rather than delete it: it may hold most of a report, and a partial
  # report is worth reading even though it must not block a retry. The stub written when
  # COUNT=0 returns long before this line, so it is never affected.
  if [ -f "$REPORT_PATH" ] && ! report_complete; then
    PARTIAL_REPORT="$REPORT_PATH.partial-$(date +%s)"
    if mv "$REPORT_PATH" "$PARTIAL_REPORT"; then
      log "WARNING: every L2 attempt left an incomplete report; moved it to $PARTIAL_REPORT so a later trigger retries this date"
    else
      log "WARNING: an incomplete report is at $REPORT_PATH and could not be moved aside; later triggers will treat this date as done"
    fi
  fi

  # ---- Retire the copies this date no longer needs, and name the ones it keeps ----
  # This has to sit outside the `-f "$REPORT_PATH"` test below. A successful partial move
  # leaves that path gone, so the stale copy went unmentioned in the one outcome where the
  # user most needs to be told where their last good report went.
  #
  # The moved-aside copy was insurance against this rebuild producing nothing. A complete
  # report means the insurance has expired, and dropping it is what stops every --force
  # rebuild from leaving another .stale-<epoch> file in the dreams dir forever. Only a
  # COMPLETE report supersedes the old one; a truncated file is not a rebuild.
  if [ -n "${STALE_REPORT:-}" ] && [ -s "$STALE_REPORT" ]; then
    if report_complete; then
      rm -f "$STALE_REPORT" && log "rebuild succeeded; discarded the superseded report copy"
    else
      log "this run produced no complete report; the previous one for $TARGET_DATE is still at $STALE_REPORT"
    fi
  fi

  # Partials are prefixes of a report that now exists in full, so a complete report
  # supersedes every one of them for this date — including partials from earlier nights,
  # which is the case the .stale-* rule above can never reach because it only knows about
  # the copy this run made. Without this they pile up in the dreams dir with nothing to
  # ever remove them.
  if report_complete; then
    for partial in "$REPORT_PATH".partial-*; do
      [ -e "$partial" ] || continue
      if rm -f "$partial"; then log "discarded superseded partial report $partial"; fi
    done
  elif [ -n "${PARTIAL_REPORT:-}" ] && [ -s "$PARTIAL_REPORT" ]; then
    log "the incomplete report for $TARGET_DATE is readable at $PARTIAL_REPORT"
  fi

  if [ -f "$REPORT_PATH" ]; then
    log "report bytes: $(wc -c < "$REPORT_PATH" | tr -d ' ')"

    # ---- Drop open-questions file into Sublime (no-op if zero questions) ----
    if [ -x "$AUTODREAM_DIR/notify.sh" ]; then
      log "writing open-questions inbox file..."
      "$AUTODREAM_DIR/notify.sh" "$REPORT_PATH" || log "notify step returned non-zero (continuing)"
    fi

    # ---- Escalate questions this report has now asked N nights running ----
    # After notify.sh, deliberately: the nightly banner goes out either way, and this adds
    # a second, differently-worded one only when a question has gone stale. The failure it
    # answers is not a missing signal but an unchanging one — the X bookmarks question was
    # asked six times across ten failing nights, each night's banner identical to the last,
    # and nothing moved until the user noticed by accident. Never fatal; it is bookkeeping.
    if [ -x "$AUTODREAM_DIR/question-streaks.sh" ]; then
      env AUTODREAM_DIR="$AUTODREAM_DIR" "$AUTODREAM_DIR/question-streaks.sh" update "$REPORT_PATH" "$FINDINGS_DIR" \
        || log "question-streaks returned non-zero (continuing)"
    fi

    # ---- Consume what L2 just read ----
    # Deliberately gated on a NON-EMPTY report, not merely an existing one. Archiving a
    # note or stamping a bookmark read after a run that produced nothing would throw away
    # the only copy of input the user cared about — the failure mode is silent and
    # unrecoverable, so the guard is stricter than the enclosing -f check.
    #
    # Also gated on TARGET_DATE being the date a normal nightly run would process
    # (yesterday, right now — same computation the default at the top of this script
    # uses). collect() above is date-agnostic: it reads whatever is CURRENTLY in the
    # vault inbox and CURRENTLY unread, regardless of which date's findings dir it's
    # writing into. That's exactly right when TARGET_DATE is tonight's date — but
    # AGENTS.md documents reprocessing an old one (AUTODREAM_FORCE=1 run.sh
    # 2026-05-29), and archive/mark-read have no idea the date is old: a successful
    # rebuild of 2026-05-29 would archive a note the user wrote THIS morning into
    # processed/2026-05-29/ and stamp today's unread bookmarks read, and tonight's real
    # run would then find an empty inbox and nothing unread — the note never reaches
    # any report. Collection still runs unconditionally above, so L2 still SEES
    # today's notes/bookmarks as context; only the consuming side is skipped for an
    # old-date reprocess.
    # AUTODREAM_CONSUME_DATE overrides which date counts as "the normal nightly one",
    # authoritatively and with no fallback, for the same reason AUTODREAM_STATS_BIN and
    # AUTODREAM_OVERLAP_BIN do: the suite pins a fixed historical TARGET_DATE, so without
    # an override every consume path would take the skip branch and the tests that cover
    # archiving would pass while asserting nothing.
    NORMAL_TARGET_DATE="${AUTODREAM_CONSUME_DATE:-$(date -v-1d +%Y-%m-%d)}"
    if ! report_complete; then
      log "report is present but carries no open-questions marker; skipping vault-notes archive and x-bookmark mark-read rather than consuming input against a truncated report"
    else
      # Publishing is NOT a consuming step — it copies the report into the vault so it
      # can be read on a phone, and a reprocessed date is exactly as worth reading as a
      # fresh one. It stays outside the date gate; only archive and mark-read, which
      # destroy the user's only copy of their input, are gated.
      if [ -x "$VAULT_NOTES" ]; then
        "$VAULT_NOTES" publish "$REPORT_PATH" || log "vault report publish failed (continuing)"
      fi
      if [ "${CONSUME_SAFE:-1}" != "1" ]; then
        log "skipping vault-notes archive and x-bookmark mark-read: a stale report could not be moved aside, so this report cannot be attributed to this run"
      elif [ "$TARGET_DATE" = "$NORMAL_TARGET_DATE" ]; then
        if [ -x "$VAULT_NOTES" ]; then
          "$VAULT_NOTES" archive "$FINDINGS_DIR" || log "vault note archive failed (notes stay in the inbox)"
        fi
        if [ -x "$XBOOKMARKS" ]; then
          "$XBOOKMARKS" mark-read "$FINDINGS_DIR" || log "x-bookmark mark-read failed (they stay unread)"
        fi
      else
        log "target date $TARGET_DATE is not $NORMAL_TARGET_DATE (today's normal nightly date); skipping vault-notes archive and x-bookmark mark-read so today's inbox/unread bookmarks aren't consumed by this reprocess (still collected as L2 context)"
      fi
    fi

    # ---- Memory candidates: L2 proposes, the human promotes. Nothing is
    #      written to any memory store here; bin/promote.sh <date> reads the
    #      sidecar after triage and writes accepted entries to Mnemopi.
    CANDIDATES="$FINDINGS_DIR/memory-candidates.json"
    if [ -s "$CANDIDATES" ]; then
      if n=$(jq -e 'if type=="array" then length else empty end' "$CANDIDATES" 2>/dev/null); then
        log "$n memory candidate(s) proposed; promote with: bin/promote.sh $TARGET_DATE"
      else
        log "WARNING: $CANDIDATES is not a JSON array; promote.sh will refuse it"
      fi
    fi
  else
    # Where the recoverable copies are was already logged above, in the one block that
    # runs whether or not this path still holds a file.
    log "WARNING: no report at $REPORT_PATH"
  fi

  log "===== autodream end: $(date) ====="
  return $L2_RC
}

# ---- The logger must not be able to take the run down with it ----
# `run 2>&1 | tee -a "$RUN_LOG"` turns every log line into a write to a pipe, so whatever
# kills tee kills the run on its very next log call — by SIGPIPE, with no error line,
# before the L2 retry loop, the move-aside blocks, or the consume gate are ever reached.
# Three runs on 2026-08-02 died exactly there and left 2026-08-01 with no report at all:
# `Terminated: 15` on tee, `Broken pipe: 13` on run, and a log ending mid-sentence at
# "L2 aggregation attempt 1/3...". Every recovery path in this script assumes it gets to
# run, and a logger that can revoke that assumption defeats all of them at once.
#
# A file has no reader to lose, so that is where an unattended run writes. Ignoring
# SIGPIPE covers the interactive path too, where tee is still worth having and a closed
# terminal should cost the run its output rather than its life.
trap '' PIPE
if [ -t 1 ]; then
  run 2>&1 | tee -a "$RUN_LOG"
  exit "${PIPESTATUS[0]}"
fi
echo "autodream: logging to $RUN_LOG"
run >> "$RUN_LOG" 2>&1
exit $?
