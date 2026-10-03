#!/bin/bash
# Merge the per-chunk L1 answers for ONE session into the one findings JSON that L2
# and every other consumer already reads. Contract: tests/merge-chunks.sh.
#
#   merge-chunks.sh --session PATH [--elided N] CHUNK.json [CHUNK.json ...]   > merged.json
#     exit 0 ok, 2 usage, nonzero (jq) on an unparseable chunk file; stdout stays empty then
#
# No model call: the merge is mechanical, so it has to say what each field means when
# the answers disagree.
#   session_path     the ORIGINAL transcript, never a chunk file
#   underlying_goal  the first non-null one: the session says what it wants where it begins
#   outcome          the last answering chunk: the end state is where the outcome is judged
#   stats fields     taken once from the first answering chunk. Every worker copies the
#                    same precomputed sidecar verbatim, so summing them would be nonsense.
#   findings         union, each tagged with its chunk, exact duplicates on
#                    (category, what) dropped, most severe first, capped at 10
#   other lists      order-preserving union, instructions_given capped at 3 (schema cap)
# A chunk that returned an error object is excluded, not merged as data. When EVERY
# chunk errored the result is an error object with an empty findings list, which is the
# L1 error contract.
set -u

usage() { echo "usage: $0 --session PATH [--elided N] CHUNK.json ..." >&2; exit 2; }

session=""; elided=0; files=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --session) [ "$#" -ge 2 ] || usage; session="$2"; shift 2 ;;
    --elided)  [ "$#" -ge 2 ] || usage; elided="$2"; shift 2 ;;
    --) shift; break ;;
    -*) usage ;;
    *) files+=("$1"); shift ;;
  esac
done
while [ "$#" -gt 0 ]; do files+=("$1"); shift; done
[ -n "$session" ] && [ "${#files[@]}" -gt 0 ] || usage
case "$elided" in ''|*[!0-9]*) usage ;; esac

jq -s --arg session "$session" --argjson elided "$elided" '
  def sev: if . == "high" then 0 elif . == "medium" then 1 elif . == "low" then 2 else 3 end;
  # A worker answer is untrusted shape: a model emits wrong types unprompted and a
  # transcript can nudge it to. Every read below goes through these so a bad field is
  # ignored rather than aborting the merge (and with it the findings of every other chunk).
  def arr: if type == "array" then . else [] end;
  def objs: arr | map(select(type == "object"));
  def num: if type == "number" then . else 0 end;
  def sig($ok; $k): [$ok[].c.satisfaction_signals | (if type == "object" then .[$k] else null end) | num] | add;
  def uniq_ordered: reduce .[] as $x ([]; if any(.[]; . == $x) then . else . + [$x] end);
  def dedupe: reduce .[] as $f ({seen: {}, out: []};
      ((($f.category // "") | tostring) + "|" + (($f.what // "") | tostring)) as $k
      | if .seen[$k] then . else (.seen[$k] = true | .out += [$f]) end) | .out;
  . as $all
  | [ $all | to_entries[]
      | select((.value | type) == "object" and (.value.error == null))
      | {i: (.key + 1), c: .value} ] as $ok
  | {chunks: ($all | length), chunks_ok: ($ok | length), chunks_elided: $elided} as $meta
  | if ($ok | length) == 0 then
      {session_path: $session,
       error: ("no chunk of " + ($all | length | tostring) + " produced a findings object"),
       findings: [], meta: $meta}
    else
      ($ok[0].c + {
        session_path: $session,
        underlying_goal: ([$ok[].c.underlying_goal | select(. != null)] | .[0]),
        outcome: $ok[-1].c.outcome,
        notable_initiatives: ([$ok[].c.notable_initiatives | arr | .[]] | uniq_ordered),
        instructions_given: ([$ok[].c.instructions_given | arr | .[]] | uniq_ordered | .[0:3]),
        satisfaction_signals: {
          happy: sig($ok; "happy"),
          satisfied: sig($ok; "satisfied"),
          dissatisfied: sig($ok; "dissatisfied"),
          frustrated: sig($ok; "frustrated")
        },
        findings: ([$ok[] | .i as $i | (.c.findings | objs)[] | . + {chunk: $i}]
                   | dedupe | sort_by(.severity | sev) | .[0:10]),
        meta: $meta
      })
    end' "${files[@]}"
