#!/bin/bash
# Claude Code harness adapter.
#
# Every subcommand delegates to the script that already implements this
# behavior. Nothing is invented here. The point of this file is that run.sh
# stops knowing which harness it is talking to — not that anything about
# Claude ingest changes.
set -u

# cd -P, not plain cd. Logical resolution would succeed against a
# coincidental $TARGET/bin in the installed layout and silently land in the
# wrong directory; -P follows the adapters symlink physically first, so this
# resolves to the real bin/ regardless of what else exists alongside.
BIN=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../../bin" && pwd)

cmd="${1:-}"
[ "$#" -gt 0 ] && shift

case "$cmd" in

  enumerate) # $1=root $2=target-date $3=next-date -> NUL-delimited session paths
    # stderr is NOT discarded. find exits 1 for any unreadable directory in the
    # walk, and the runner has to decide between a partial corpus and a failed
    # root on that status alone. Swallowing the reason left it reporting bare
    # `(exit 1)` with nothing to act on. Only stdout is the contract.
    find "$1" -type f -name '*.jsonl' \
         -newermt "$2 00:00:00" \
         ! -newermt "$3 00:00:00" \
         -print0
    ;;

  normalize) # $1=in $2=out
    [ "$#" -ge 2 ] || exit 2   # see the note on stats|slim below
    # A Claude transcript is a flat list of turns, so normalisation is a copy.
    # It still writes through a .tmp and renames: the contract says a failed
    # subcommand leaves NO output, and a half-written file that a later step
    # reads as a whole session is worse than no session at all.
    [ -r "$1" ] || exit 1
    # A unique temp in the DESTINATION directory. A fixed "$2.tmp" is a shared
    # name: two invocations writing the same output would clobber or remove each
    # other's temp file and leave the result from the wrong one, or none.
    # A directory at the destination is refused. `mv -f "$t" "$2"` would move
    # the temp INSIDE it and return success, so the adapter would report a write
    # it never performed and leave a randomly-named file in the caller's
    # directory. The delegates used to reject this themselves, because a `>`
    # redirection to a directory fails; wrapping them removed that.
    [ ! -d "$2" ] || exit 1
    t=$(mktemp "$2.tmp.XXXXXX" 2>/dev/null) || exit 1
    cp "$1" "$t" 2>/dev/null || { rm -f "$t"; exit 1; }
    mv -f "$t" "$2" 2>/dev/null || { rm -f "$t"; exit 1; }
    # Post-condition, because the guard above is a check-then-act. Something can
    # create a directory at $2 between the two, and `mv` then moves the temp
    # INSIDE it and returns 0 — success reported with no output written, which
    # is the exact failure the guard exists to stop. macOS has no `mv -T`, so
    # the destination is verified to be a regular file afterwards and the stray
    # removed. Verified by deleting the guard above: this alone still satisfies
    # the directory-destination contract test, so it is a real backstop and not
    # decoration. The guard stays anyway — it fails before any work, and it is
    # what stops a file appearing inside the caller's directory even briefly.
    #
    # This NARROWS the race rather than closing it. A sequence that creates a
    # directory at $2 after the guard, lets mv move the temp inside it, then
    # replaces $2 with a regular file before this check, still reports success
    # with the output somewhere else. Closing that needs an atomic
    # rename-if-not-a-directory, which is renameat2 on Linux and does not exist
    # on macOS, where this runs. Winning any of these needs write access to the
    # findings dir, at which point the dir is already the attacker's; these
    # checks exist because silent wrong success is the failure this repo keeps
    # getting caught by, not because there is a threat model. Named here rather
    # than papered over with a fourth layer that would not close it either.
    [ -f "$2" ] || { rm -f "$2/$(basename "$t")" 2>/dev/null; exit 1; }
    ;;

  project) # $1=session -> the session's real working directory
    [ -r "$1" ] || exit 1
    # jq, not grep: a cwd containing a quote or a backslash is JSON-escaped, and
    # a regex over the raw line either truncates at the escaped quote or hands
    # realpath a doubled backslash.
    cwd=$(jq -re 'select(.cwd != null) | .cwd' "$1" 2>/dev/null | head -1)
    [ -n "$cwd" ] || exit 1
    realpath "$cwd" 2>/dev/null || exit 1
    ;;

  memory-root) # $1=session -> the Claude config dir that owns it
    # Two shapes exist and both are legitimate sessions to triage:
    #   <root>/projects/<bucket>/<file>.jsonl
    #   <root>/projects/<bucket>/<session>/subagents/agent-*.jsonl
    # so a fixed number of `..` hops is wrong. Walk up to the `projects`
    # directory instead; its parent is the config root. Failing here is
    # correct rather than defensive — an unresolvable memory root must not
    # reach the findings record, because it would later authorise a write
    # against an empty target.
    d=$(cd "$(dirname "$1")" 2>/dev/null && pwd -P) || exit 1
    while [ "$d" != "/" ]; do
      if [ "$(basename "$d")" = "projects" ]; then
        dirname "$d"
        exit 0
      fi
      d=$(dirname "$d")
    done
    exit 1
    ;;

  # stats and slim delegate like everything else, but they cannot `exec`. Both
  # delegated scripts write the destination directly — slim-transcript.sh in two
  # steps, a `>` for the body and a `>>` for the footer — so an interruption
  # leaves a non-empty file with no footer, and the caller's `-s` check accepts
  # it and sends a truncated session to L1 as if it were whole.
  #
  # The atomicity belongs here rather than in those scripts: the contract is the
  # adapter's (docs/design/unify-harness-adapters-2026-08-23.md:131 requires it
  # of every subcommand that writes a file), and both scripts have callers
  # outside this seam. Same shape as normalize above — a unique temp in the
  # DESTINATION directory, renamed on success, removed on failure.
  #
  # DELIBERATELY NO SIGNAL TRAP, and this was measured rather than assumed. A
  # killed run leaves the temp behind, which is real but cosmetic: nothing reads
  # `*.tmp.*` — the findings glob is `*.json` and slim output is read by exact
  # path. Adding `trap 'rm -f "$t"' ... TERM` costs far more than it saves,
  # because bash defers a TRAPPED signal until the foreground child returns. The
  # delegate is that child, so the trap converts a prompt death into an adapter
  # that ignores SIGTERM for as long as the delegate runs — verified here: the
  # test below hung for 120s and left orphaned slim-transcript.sh processes
  # holding their input open. Being killed mid-flight is this pipeline's normal
  # failure, so trading a stale temp for a hung process is the wrong direction.
  # Backgrounding the delegate and killing it from the trap would work and is
  # five lines of signal plumbing in a file whose whole claim is that nothing is
  # invented here. Tracked instead.
  stats|slim)
    # Arity BEFORE dereferencing $2. Under `set -u` a one-arg call died with
    # "$2: unbound variable" and status 1 — indistinguishable from a legitimate
    # skip-this-session failure, when the caller actually made a usage error.
    [ "$#" -ge 2 ] || exit 2
    case "$cmd" in
      stats) delegate="$BIN/session-stats.sh" ;;
      slim)  delegate="$BIN/slim-transcript.sh" ;;
    esac
    [ ! -d "$2" ] || exit 1   # see the note on the first use above
    t=$(mktemp "$2.tmp.XXXXXX" 2>/dev/null) || exit 1
    "$delegate" "$1" "$t" || { rm -f "$t"; exit 1; }
    mv -f "$t" "$2" 2>/dev/null || { rm -f "$t"; exit 1; }
    [ -f "$2" ] || { rm -f "$2/$(basename "$t")" 2>/dev/null; exit 1; }   # see the note above
    ;;

  is-self) # $1=session -> exit 0 if this is one of autodream's own transcripts
    # The readability guard every sibling subcommand has. Without it a vanished
    # or unreadable transcript answers "not one of ours" — prune-self-sessions.sh
    # greps with 2>/dev/null and returns 1 either way — which is indistinguishable
    # from a real user session, and the contract has no channel to say "I could
    # not read it". Exit 2 is the unknown-subcommand code and would be wrong here;
    # this is a readable-input failure, so the caller sees a nonzero that is not 1.
    [ -r "$1" ] || exit 3
    # Delegated, never reimplemented: prune-self-sessions.sh is the single
    # source of truth for this predicate, and a marker added there must not
    # have to be remembered here too.
    exec "$BIN/prune-self-sessions.sh" --is-self "$1"
    ;;

  skills-inventory)
    for d in "$HOME"/.claude/skills/*/ "$HOME"/.claude/plugins/*/skills/*/; do
      [ -f "$d/SKILL.md" ] || continue
      printf '%s\n' "$(basename "$d")"
    done
    ;;

  *)
    printf 'claude adapter: unknown subcommand: %s\n' "$cmd" >&2
    exit 2
    ;;
esac
