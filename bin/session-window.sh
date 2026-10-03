#!/bin/bash
# Local-day window over a Claude Code transcript. Contract: tests/session-window.sh.
#
#   session-window.sh bounds DATE NEXT_DATE        prints "START_EPOCH END_EPOCH"
#   session-window.sh in-window FILE START END     exit 0 yes, 1 no, 2 error
#   session-window.sh needs-slice FILE START END   exit 0 yes, 1 no, 2 error
#   session-window.sh slice FILE START END         in-window lines on stdout, unmodified
#
# Why. Enumeration selected a session by file mtime inside the report day, so a
# multi-day orchestrator, still being written, was never selected. Without that upper
# bound the in-transcript timestamp is the only thing that says which day a record
# belongs to. The window is [START, END): local midnight to the next local midnight,
# computed with BSD date so a 23h or 25h DST day comes out right.
#
# in-window answers YES when it cannot tell (no parseable timestamp anywhere, or an
# empty file) so a transcript without a clock is triaged exactly as before. An
# unreadable file is an ERROR (2), never a no: the caller keeps the session on an
# error, so a broken helper costs extra work and never reads as a quiet night.
#
# Timestamps are compared as epoch seconds, not as strings: "00.5Z" sorts before
# "00Z" lexicographically, which would misplace the boundary second.
set -u

# Shared by every jq program below. No apostrophes anywhere in these programs: they
# sit inside single-quoted shell strings, and one stray quote ends the string.
TS_DEF='def ts: (try .timestamp catch null)
  | select(type == "string")
  | try (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) catch empty;'

usage() {
  echo "usage: $0 bounds DATE NEXT_DATE | in-window|needs-slice|slice FILE START END" >&2
  exit 2
}

is_int() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

cmd="${1:-}"
case "$cmd" in
  bounds)
    [ "$#" -eq 3 ] || usage
    a=$(date -j -f '%Y-%m-%d %H:%M:%S' "$2 00:00:00" +%s 2>/dev/null) || exit 1
    b=$(date -j -f '%Y-%m-%d %H:%M:%S' "$3 00:00:00" +%s 2>/dev/null) || exit 1
    is_int "$a" && is_int "$b" && [ "$b" -gt "$a" ] || exit 1
    printf '%s %s\n' "$a" "$b"
    ;;
  in-window|needs-slice|slice)
    [ "$#" -eq 4 ] || usage
    f="$2"; s="$3"; e="$4"
    is_int "$s" && is_int "$e" || usage
    [ -r "$f" ] || exit 2
    case "$cmd" in
      in-window)
        # Phase 1 stops at the first in-window record, so a large file that is in
        # window costs one short read. Phase 2 only runs for a file with nothing in
        # window, and stops at the first timestamp it sees.
        hit=$(jq -R -n --argjson s "$s" --argjson e "$e" "$TS_DEF"'
          first(inputs | fromjson? | select(type == "object") | ts | select(. >= $s and . < $e))' "$f" 2>/dev/null) || exit 2
        [ -n "$hit" ] && exit 0
        any=$(jq -R -n "$TS_DEF"'
          first(inputs | fromjson? | select(type == "object") | ts)' "$f" 2>/dev/null) || exit 2
        [ -n "$any" ] && exit 1
        # No parseable timestamp anywhere, so the records cannot place this file in a day
        # and its mtime decides, exactly as the bounded find used to: modified by the end
        # of the day -> yes (bias to triage), modified after it -> no. Without this, the
        # find that no longer has an upper bound would enumerate a no-clock file on every
        # later date as well and triage it twice, filed under the wrong day.
        mt=$(stat -f %m "$f" 2>/dev/null) || exit 0
        case "$mt" in ''|*[!0-9]*) exit 0 ;; esac
        [ "$mt" -lt "$e" ] && exit 0
        exit 1
        ;;
      needs-slice)
        # Cheap by design. The first timestamp is found with an early exit over the whole
        # file (a leading run of clockless lines no longer hides it), and the last from the
        # final 2000 lines. A transcript is chronological, so a file that starts inside the
        # day and ends inside the day is wholly inside it. No timestamp at all means
        # nothing to slice by.
        first_ts=$(jq -R -n "$TS_DEF"'
          first(inputs | fromjson? | select(type == "object") | ts)' "$f" 2>/dev/null) || exit 2
        last_ts=$(tail -n 2000 "$f" | jq -R -n "$TS_DEF"'
          [inputs | fromjson? | select(type == "object") | ts] | last // empty' 2>/dev/null) || exit 2
        if [ -n "$first_ts" ] && [ "${first_ts%.*}" -lt "$s" ]; then exit 0; fi
        if [ -n "$last_ts" ] && [ "${last_ts%.*}" -ge "$e" ]; then exit 0; fi
        exit 1
        ;;
      slice)
        # Raw lines out, not re-serialised, so the slimmer and the stats see exactly
        # the bytes that were written. A torn line or a record with no clock is
        # dropped: when a window is set, a record that cannot be placed in it is not
        # evidence for this day.
        jq -R -r --argjson s "$s" --argjson e "$e" "$TS_DEF"'
          . as $l | ($l | fromjson? | select(type == "object") | ts | select(. >= $s and . < $e)) | $l' "$f" 2>/dev/null || exit 2
        ;;
    esac
    ;;
  *) usage ;;
esac
