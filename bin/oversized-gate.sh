#!/bin/bash
# Issue #12 measurement gate: what share of oversized transcripts still failed to triage?
#
# The gate is a trailing-window judgment ("sustained oversized_errored/oversized_total
# >= 5% over a week opens #12"), but run.sh only ever records one night at a time, and a
# run whose runner predated the counters (#29) records nothing at all. This recomputes
# the window from the *.stats.json sidecars and findings JSONs still on disk, so a date
# whose run-stats.txt is missing the keys is recoverable rather than lost.
#
# It reads only artifacts. No model calls, no network, safe to re-run.
#
# Usage:
#   oversized-gate.sh                       # trailing 7 dated dirs under the findings root
#   oversized-gate.sh --days 14             # trailing 14
#   oversized-gate.sh <findings-dir>...     # exactly these dirs
#
# Environment:
#   AUTODREAM_DIR         default: $HOME/.claude/autodream
#   AUTODREAM_SLIM_BYTES  oversized threshold, matches run.sh   default: 262144

set -u

HERE=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# The install dir is not the only place to look, for the same reason run.sh has a
# fallback: install.sh symlinks each script into ~/.claude/autodream individually,
# so merging a branch swaps the script those links point at instantly while a NEW
# library link does not exist until install.sh is re-run. `cd -P` resolves a
# symlinked DIRECTORY but not a symlinked FILE, so $HERE is the install dir every
# time and this script stopped working entirely during that window — on the one
# tool whose whole purpose is recomputing the #12 gate from artifacts after a
# runner problem. Walk this script's own symlink chain to find the repo's bin/.
_og_src="${BASH_SOURCE[0]}"; _og_hops=0
while [ -L "$_og_src" ] && [ "$_og_hops" -lt 8 ]; do
  _og_dir=$(cd "$(dirname "$_og_src")" && pwd) || break
  _og_src=$(readlink "$_og_src") || break
  case $_og_src in /*) ;; *) _og_src="$_og_dir/$_og_src" ;; esac
  _og_hops=$((_og_hops + 1))
done
_og_real=""
[ -L "$_og_src" ] || _og_real=$(cd "$(dirname "$_og_src")" 2>/dev/null && pwd) || _og_real=""
# shellcheck source=/dev/null
if [ -r "$HERE/lib-project.sh" ]; then . "$HERE/lib-project.sh"
elif [ -n "$_og_real" ] && [ -r "$_og_real/lib-project.sh" ]; then . "$_og_real/lib-project.sh"
else
  echo "oversized-gate: lib-project.sh not found beside this script or its real location" >&2; exit 2
fi

AUTODREAM_DIR="${AUTODREAM_DIR:-$HOME/.claude/autodream}"
THRESHOLD="${AUTODREAM_SLIM_BYTES:-262144}"
DAYS=7
DIRS=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    # Validate rather than defaulting a missing value: `--days` with nothing after it
    # used to leave $# at 1 while `shift 2` silently refused to shift, spinning forever.
    --days)
      [ "$#" -ge 2 ] || { echo "--days needs a value" >&2; exit 2; }
      case "$2" in ''|*[!0-9]*) echo "--days needs a positive integer, got: $2" >&2; exit 2 ;; esac
      [ "$2" -gt 0 ] || { echo "--days needs a positive integer, got: $2" >&2; exit 2; }
      DAYS="$2"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) DIRS+=("$1"); shift ;;
  esac
done

if [ "${#DIRS[@]}" -eq 0 ]; then
  root="$AUTODREAM_DIR/findings"
  [ -d "$root" ] || { echo "no findings root at $root" >&2; exit 1; }
  while IFS= read -r d; do
    [ -n "$d" ] && DIRS+=("$d")
  done < <(find "$root" -maxdepth 1 -type d -name '2[0-9][0-9][0-9]-[0-1][0-9]-[0-3][0-9]' \
    | sort | tail -n "$DAYS")
fi

[ "${#DIRS[@]}" -gt 0 ] || { echo "no dated findings dirs found" >&2; exit 1; }

# A session's size comes from its sidecar's transcript_bytes; when that is missing or
# unusable, fall back to measuring the transcript directly. transcript_bytes is only ever
# `wc -c` of that same file, so the fallback is the same quantity from its original
# source (#27). Sessions whose transcript is also gone are counted as unmeasurable and
# excluded from the ratio rather than silently sized at 0.
total_oversized=0
total_errored=0
total_unmeasurable=0

printf '%-12s %7s %10s %9s %8s  %s\n' DATE SESSIONS OVERSIZED ERRORED SHARE SOURCE
for d in "${DIRS[@]}"; do
  date_label=$(basename "$d")
  list="$d/sessions.txt"
  [ -r "$list" ] || { printf '%-12s %7s %10s %9s %8s  %s\n' "$date_label" - - - - "no sessions.txt"; continue; }

  sessions=0; oversized=0; errored=0; from_sidecar=0; unmeasurable=0
  while IFS= read -r session; do
    [ -n "$session" ] || continue
    sessions=$((sessions + 1))
    # Same validated contract as the runner. Deriving a hash here with
    # `shasum | cut` meant a runtime-failing shasum yielded an empty key, so the
    # gate consulted ".stats.json" and ".json" for every session and could
    # undercount errored oversized sessions — reporting GATE CLOSED off a
    # measurement that never happened. That is precisely the false-clean reading
    # this script was written to refuse.
    hash=$(session_hash "$session") || { unmeasurable=$((unmeasurable + 1)); continue; }
    sidecar="$d/$hash.stats.json"
    size=""
    [ -s "$sidecar" ] && size=$(jq -r '.transcript_bytes | numbers | floor' "$sidecar" 2>/dev/null)
    case "$size" in ''|*[!0-9]*) size="" ;; esac
    if [ -n "$size" ]; then
      from_sidecar=$((from_sidecar + 1))
    else
      size=$(wc -c < "$session" 2>/dev/null | tr -d ' ')
      case "$size" in ''|*[!0-9]*) size="" ;; esac
      if [ -z "$size" ]; then
        unmeasurable=$((unmeasurable + 1))
        continue
      fi
    fi
    if [ "$size" -gt "$THRESHOLD" ]; then
      oversized=$((oversized + 1))
      findings="$d/$hash.json"
      if [ -f "$findings" ] && grep -q '"error":' "$findings" 2>/dev/null; then
        errored=$((errored + 1))
      fi
    fi
  done < "$list"

  total_oversized=$((total_oversized + oversized))
  total_errored=$((total_errored + errored))
  total_unmeasurable=$((total_unmeasurable + unmeasurable))

  if [ "$oversized" -gt 0 ]; then
    share=$(awk -v e="$errored" -v o="$oversized" 'BEGIN{printf "%.1f%%", 100*e/o}')
  else
    share="n/a"
  fi
  source_note="$from_sidecar/$sessions from sidecars"
  [ "$unmeasurable" -gt 0 ] && source_note="$source_note, $unmeasurable unmeasurable"
  printf '%-12s %7s %10s %9s %8s  %s\n' "$date_label" "$sessions" "$oversized" "$errored" "$share" "$source_note"
done

echo
if [ "$total_oversized" -eq 0 ]; then
  echo "No oversized transcripts in this window. The gate has nothing to measure;"
  echo "that is not the same as a measured 0% and should not close #12 on its own."
  exit 0
fi

share=$(awk -v e="$total_errored" -v o="$total_oversized" 'BEGIN{printf "%.2f", 100*e/o}')
# Rule of three: with 0 failures in n trials the 95% upper bound is about 3/n. Quoting it
# keeps a clean run from being read as stronger evidence than the sample size supports.
printf 'Window: %s oversized, %s errored, %s%%' "$total_oversized" "$total_errored" "$share"
[ "$total_unmeasurable" -gt 0 ] && printf ' (%s session(s) unmeasurable, excluded)' "$total_unmeasurable"
printf '\n'
if [ "$total_errored" -eq 0 ]; then
  bound=$(awk -v n="$total_oversized" 'BEGIN{printf "%.1f", 100*3/n}')
  echo "Zero failures in $total_oversized samples; 95% upper bound about $bound% (rule of three)."
fi
if awk -v s="$share" 'BEGIN{exit !(s + 0 >= 5)}'; then
  echo "GATE OPEN: at or above the 5% threshold. Issue #12 (chunk-summarize) is unblocked."
else
  echo "GATE CLOSED: below the 5% threshold. The existing fallback stack is coping."
fi
