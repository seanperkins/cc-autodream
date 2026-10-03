#!/bin/bash
# Mock `claude` binary for cc-autodream integration tests.
#
# run.sh invokes the real claude CLI for both layers. Here we stand in for it:
# read the prompt on stdin, find the two literal-path lines run.sh inlined, and
# write (or deliberately don't write) the expected output file — no model, no
# network. Which layer we are is decided by line 1 of the prompt.
#
# Env knobs (all optional):
#   MOCK_MODE=good           write findings (L1) / report (L2). [default]
#   MOCK_MODE=l1_incomplete  L1 writes nothing (simulates a worker that exits
#                            without producing JSON); L2 still writes its report.
#   MOCK_MODE=l2_fail        L2 writes no report and exits 1 (simulates the
#                            aggregator dying to a mid-run sleep). L1 is unaffected.
#                            Pair with AUTODREAM_L2_ATTEMPTS=1 so the test doesn't
#                            sit through the retry loop.
#   MOCK_MODE=candidates     L2 writes a memory-candidates.json sidecar plus the report.
#   MOCK_MODE=candidates_partial  as candidates, but the report is truncated.
#   MOCK_MODE=l1_forged      L1 writes another session's path and cwd.
#   MOCK_MODE=l1_tamper      L1 also rewrites the session worklist.
#   MOCK_CANDIDATE_CWD       cwd proposed by the candidate mock.
#   MOCK_CAPTURE_DIR=<dir>   dump each layer's stdin + argv to <dir>/l{1,2}-*.txt
#                            so tests can assert on the exact prompt framing.
#   MOCK_MODE=chunked        L1 answers as one chunk of a longer session (goal-N, outcome
#                            fully_achieved only on the last chunk). MOCK_FAIL_CHUNK=N
#                            makes chunk N produce nothing on its first attempt.
#   MOCK_MODEL_LOG=<file>    append "<output path><TAB><model>" for every L1 call.
#   MOCK_BAD_CHUNK=N         chunked mode: chunk N answers with the wrong thing once.
#   MOCK_BAD_KIND=error|nofindings|typed   what that wrong answer is (default error).
#   MOCK_TRANSCRIPT_LOG=<file>  append "<transcript path><TAB><its bytes>" per L1 call.
#   MOCK_CALL_LOG=<file>     append the L1 output path for every invocation of
#                            this mock, one per line — lets a test prove the
#                            model was (or was not) invoked for a given session
#                            (e.g. a noise-gated session should never appear).

input=$(cat)
mode="${MOCK_MODE:-good}"

line1=$(printf '%s\n' "$input" | sed -n '1p')
line2=$(printf '%s\n' "$input" | sed -n '2p')

if printf '%s' "$line1" | grep -q '^Session transcript'; then
  # ---- Layer 1: triage worker ----
  if [ -n "${MOCK_CAPTURE_DIR:-}" ]; then
    printf '%s' "$input" > "$MOCK_CAPTURE_DIR/l1-stdin.txt"
    printf '%s\n' "$@" > "$MOCK_CAPTURE_DIR/l1-args.txt"
  fi
  out=$(printf '%s' "$line2" | sed 's/^Write your findings JSON to this literal absolute path: //')
  sess=$(printf '%s' "$line1" | sed 's/^Session transcript to analyze (literal absolute path): //')
  [ -n "${MOCK_CALL_LOG:-}" ] && printf '%s\n' "$out" >> "$MOCK_CALL_LOG"
  # How big a transcript the worker was actually handed (a slim file that exists only
  # for the duration of the call), so a test can prove what the worker was given.
  [ -n "${MOCK_TRANSCRIPT_LOG:-}" ] && printf '%s\t%s\n' "$sess" "$(wc -c < "$sess" 2>/dev/null | tr -d ' ')" >> "$MOCK_TRANSCRIPT_LOG"
  # The model this call asked for, so a test can prove WHICH model a session got.
  if [ -n "${MOCK_MODEL_LOG:-}" ]; then
    _m=""; _prev=""
    for _a in "$@"; do [ "$_prev" = "--model" ] && _m="$_a"; _prev="$_a"; done
    printf '%s\t%s\n' "$out" "$_m" >> "$MOCK_MODEL_LOG"
  fi
  # chunked mode: answer as one chunk of a longer session, so the merge has something
  # to disagree about. Chunk i of n comes from the chunk note in the prompt.
  write_chunked() { # $1=i $2=n
    local oc=partially_achieved; [ "$1" = "$2" ] && oc=fully_achieved
    jq -cn --arg sess "$sess" --arg i "$1" --arg oc "$oc" \
      '{session_path:$sess, project:"proj-a", turn_count:30, tool_call_count:0, tools_used:[], skills_invoked:[],
        models_used:[], notable_initiatives:[("init-"+$i)], underlying_goal:("goal-"+$i), outcome:$oc,
        satisfaction_signals:{happy:0,satisfied:0,dissatisfied:0,frustrated:0}, instructions_given:[],
        findings:[{category:"permission_prompt",severity:"low",what:("finding-from-chunk-"+$i),evidence_excerpt:"x",proposed_rule:"y"},
                  {category:"other",severity:"low",what:"shared across chunks",evidence_excerpt:"x",proposed_rule:"y"}]}' > "$out"
  }
  write_findings() { printf '{"session_path":"x","project":"proj-a","turn_count":2,"tool_call_count":0,"tools_used":[],"skills_invoked":[],"models_used":[],"notable_initiatives":[],"underlying_goal":null,"outcome":"fully_achieved","satisfaction_signals":{"happy":0,"satisfied":1,"dissatisfied":0,"frustrated":0},"instructions_given":["always run tests after edits"],"findings":[]}' > "$out"; }
  # Emit a real session_path but a deliberately WRONG project (what nondeterministic
  # haiku does), so run.sh's path-based normalization pass has something to correct.
  write_badproject() { printf '{"session_path":"%s","project":"WRONG-PROJECT","turn_count":2,"tool_call_count":0,"tools_used":[],"skills_invoked":[],"models_used":[],"notable_initiatives":[],"findings":[]}' "$sess" > "$out"; }
  case "$mode" in
    l1_incomplete) : ;;                 # never write — simulates a worker that exits empty
    l1_badproject|candidates|candidates_partial) write_badproject ;;
    l1_forged|l1_tamper)
      printf '{"session_path":"%s","cwd":"/forged/cwd","project":"WRONG-PROJECT","findings":[]}' "$MOCK_FORGED_SESSION" > "$out"
      if [ "$mode" = "l1_tamper" ]; then
        printf '%s\n' "$MOCK_FORGED_SESSION" > "$(dirname "$out")/sessions.txt"
      fi ;;
    l1_flaky)                           # fail the first dispatch per session, succeed on retry
      if [ -f "$out.attempt" ]; then write_findings; else : > "$out.attempt"; fi ;;
    chunked)                            # answer per chunk; MOCK_FAIL_CHUNK=N fails chunk N once
      ci=""; cn=""
      read -r ci cn <<< "$(printf '%s' "$input" | sed -n 's/.*chunk \([0-9][0-9]*\) of \([0-9][0-9]*\) of ONE session.*/\1 \2/p' | head -1)"
      [ -n "$ci" ] || { ci=1; cn=1; }
      if [ "$ci" = "${MOCK_FAIL_CHUNK:-0}" ] && [ ! -f "$out.attempt" ]; then
        : > "$out.attempt"
      elif [ "$ci" = "${MOCK_BAD_CHUNK:-0}" ] && [ ! -f "$out.bad" ]; then
        # a worker that answers, but with the wrong thing, once; the retry answers properly
        : > "$out.bad"
        case "${MOCK_BAD_KIND:-error}" in
          error)      printf '{"session_path":"%s","error":"unreadable","findings":[]}' "$sess" > "$out" ;;
          nofindings) printf '{"foo":1}' > "$out" ;;
          typed)      printf '{"session_path":"%s","findings":"oops"}' "$sess" > "$out" ;;
        esac
      else
        write_chunked "$ci" "$cn"
      fi ;;
    *) write_findings ;;
  esac
  echo done
else
  # ---- Layer 2: aggregator ----
  if [ -n "${MOCK_CAPTURE_DIR:-}" ]; then
    printf '%s' "$input" > "$MOCK_CAPTURE_DIR/l2-stdin.txt"
    printf '%s\n' "$@" > "$MOCK_CAPTURE_DIR/l2-args.txt"
  fi
  rep=$(printf '%s' "$line2" | sed 's/^Write the report to this literal absolute path: //')
  if [ "$mode" = "l2_fail" ]; then
    echo "mock: aggregator failed" >&2
    exit 1
  fi
  fdir=$(printf '%s' "$line1" | sed 's/^Findings directory to aggregate (literal absolute path): //')
  case "$mode" in
    candidates|candidates_partial)
      jq -cn --arg cwd "$MOCK_CANDIDATE_CWD" \
        '[{cwd:$cwd,content:"Mock lesson",kind:"correction",evidence:["fixture-session"]}]' \
        > "$fdir/memory-candidates.json" ;;
    *) printf '[]\n' > "$fdir/memory-candidates.json" ;;
  esac
  # l2_partial: a NON-EMPTY report with no open-questions marker — what a mid-write kill
  # leaves behind. `-s` cannot tell this from a good report, which is why run.sh checks
  # for the marker instead.
  if [ "$mode" = "l2_partial" ] || [ "$mode" = "candidates_partial" ]; then
    printf '# Autodream — mock\n\n## Top patterns\n\n1. truncated mid-w' > "$rep"
    echo "mock: partial write"
    exit 0
  fi
  # The open-questions marker is part of the real contract (PROMPT.md mandates it) and
  # run.sh now treats its absence as a truncated write, so the mock must emit it too.
  printf '# Autodream — mock\n\nmock aggregate report\n\n<!-- autodream:open-questions=0 -->\n' > "$rep"
  echo "report: $rep"
  echo "mock: 1 session reviewed, 0 findings, 0 edits"
fi
