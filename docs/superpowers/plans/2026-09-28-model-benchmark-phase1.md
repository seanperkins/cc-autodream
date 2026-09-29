# Autodream Model Benchmark, Phase 1 (L1 objective benchmark): Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `bench/`, a repeatable benchmark that runs a candidate model and effort level in the autodream **L1** (per-session triage) role and reports validity, authoritative-field fidelity, evidence grounding, and depth, plus latency, tokens, and API-equivalent cost, in separate columns with an eligibility gate.

**Architecture:** The L1 prompt assembly and `claude` command move out of `bin/run.sh` into `bin/l1-invoke.sh`, which both production and the benchmark use. `bench/` holds stdlib-only Python modules (sampler, runner, grader, report, historical importer) and one bash driver that calls the shared invocation. Runs go through the `claude` CLI on the user's subscription, resume per (case, rep), and write results in a per-candidate run directory.

**Tech Stack:** Python 3 stdlib only (`unittest`, `argparse`, `difflib`, `subprocess`, `concurrent.futures`), bash 3.2-compatible shell (macOS), the `claude` CLI, `jq`.

**Spec:** `docs/superpowers/specs/2026-09-28-model-benchmark-design.md` (reviewed, commit `7d10895`). This plan is **Phase 1 of 4**. Phases 2 (reference and judge), 3 (L2 fixtures and end-to-end smoke check) and 4 (codex adapter) get separate plans once Phase 1 is proven.

Work in the existing checkout, `/Users/sean/sites/cc-autodream`, on `main`. All commands run from that directory.

## How this plan was validated

Every code block below was written and run before it went into this document, not drafted from memory:

- The 86 benchmark unit tests pass (`python3 -m unittest discover -s bench/tests`).
- Task 1's patch was applied to a scratch copy of the repo and run against the real suite: **RED** (tests only) gave `passed: 684 failed: 3`, then **GREEN** (tests plus code) gave `passed: 687 failed: 0`.
- The sampler and grader were run against the real corpus: 406 eligible sessions, 60 frozen (57 slimmed), and the historical Haiku output graded as the calibration baseline (numbers in Task 6).

## Decisions to confirm before executing

1. **L1 production default.** `bin/run.sh` currently has an uncommitted experiment (`claude-sonnet-5-5`, `--effort medium`), and committed `59f2eb8` has `--effort low`. Both returned `unclear_from_transcript` for 18 of 20 sessions on 2026-09-28. Task 1 makes the L1 model and effort overridable (`AUTODREAM_L1_MODEL`, `AUTODREAM_L1_EFFORT`) and sets the default back to **`claude-haiku-4-5`**, and reverts the doc wording that the experiment changed. If you want a different default, change it in Task 1's patch (`claude-haiku-4-5` appears in one place in the code patch and one in the test patch).
2. **Gate thresholds differ from the spec.** The spec's starting values (authoritative 100%, hallucination 2%) fail the incumbent Haiku on its own historical output (authoritative 58/60 = 96.7%, hallucinated evidence 1/20 = 5%). `bench/config.json` uses `authoritative_min` 0.95 and `hallucination_max` 0.10. The spec says the thresholds are starting values adjustable after the first run; this calibration is that first run. `validity_min` (0.98) and `abstain_excess_max` (0.10) are unchanged.

## Deviations from the spec

1. **Python modules, not `.sh` entry points.** `sample_cases.py`, `runner.py`, `grade_l1.py`, `report.py` (plus the bash driver `run-one-l1.sh`). The spec's file names were illustrative; stdlib Python is testable.
2. **`bin/l1-invoke.sh`, not `bench/lib/l1-invoke.sh`.** Production sources it, so it sits beside `bin/lib-project.sh`, is found through `find_lib`, and is linked by `install.sh`.
3. **Gated sessions are excluded from the case set.** Production never sends them to an L1 model, so they would measure nothing.
4. **Markdown report, not the skill's lite HTML.** That builder only reads `baseline` and `v<N>` variant directories, which does not fit a model-by-effort matrix. Revisit in Phase 2.
5. **Evidence grounding is tiered:** verbatim, then anchored (quoted commands and identifiers appear in the transcript), then unverifiable, then ungrounded. On the 20 real historical findings, 0 were verbatim quotes: production L1 paraphrases with line references, so a verbatim-only check would fail the incumbent every time. Only `ungrounded` counts as hallucinated.
6. **New `bench/import_historical.py`.** Grades the outputs production already produced for the frozen cases, for free, to calibrate the grader before spending subscription usage.
7. **Resume key** is (case, rep) inside a run directory named `model@effort`; the spec's (case, model, effort, rep) is equivalent.

## Global Constraints

- Calls go through the `claude` CLI on the user's subscription; no API keys, no direct API calls.
- `bench/data/` holds frozen session content: gitignored, never committed, never sent anywhere except to the models being benchmarked.
- Runner concurrency defaults to 2 and backs off with jitter on rate-limit or usage-cap errors, recording the retry count.
- Every case has a hard per-case wall-clock ceiling; a timeout is recorded as a timeout, not a zero.
- Every failed attempt gets a failure class (refusal, harness/serving error, timeout, or genuine failure) and goes to `errors.jsonl`, never into `results.jsonl`.
- A served model that differs from the requested one fails the attempt; if the CLI exposes no served-model field, rows are marked `served_model: unverified` and the report says so.
- `--dry-run` prints models x cases x reps and makes zero calls; a real run requires `--confirm`.
- Report quality, latency, tokens, and cost as separate columns. No blended score.
- `bin/run.sh` behavior stays unchanged apart from the L1 model and effort overrides: the existing 679 checks stay green.
- The benchmark varies model, effort, and harness only; the production L1 prompt is held fixed.
- Gate: validity at least 98%, authoritative fields at least 95% of valid rows (spec: 100%, see Decisions), hallucinated evidence at most 10% of findings (spec: 2%), `abstain_excess` at most 10%.
- Python 3 standard library only. Shell code must run on macOS bash 3.2.

## Review Focus

Failure modes the spec implies that a person using this will hit; each has a test in the owning task.

1. **The CLI returns no `modelUsage`** (older CLI, or a candidate that omits it): the run must succeed with `served_verified: null`, not crash and not be rejected. Task 5, `test_missing_model_usage_is_recorded_as_unverified`.
2. **A crash leaves a truncated last line in `results.jsonl`:** resume must ignore it, and the next append must not be glued onto it. Task 2 (`test_append_after_truncated_line_does_not_glue`), Task 5 (`test_resume_tolerates_a_truncated_last_line`).
3. **A session whose historical outcome is missing or `unclear_from_transcript`:** excluded from the `abstain_excess` denominator; a zero denominator gives `None` and the gate reports it as unmeasured, never a crash and never a silent pass. Task 4, `test_abstaining_where_reference_did_not_decide_is_not_penalised`.
4. **Real L1 evidence is a paraphrase with line references, JSON keys, spacing and punctuation differences:** it must still be recognized as grounded when its quoted commands and identifiers are in the transcript, and fabricated evidence must still be caught. Task 4, `GroundingTiers`.
5. **A hung CLI whose child processes outlive the parent:** the whole process group is killed at the timeout, and the run continues. Task 5, `test_timeout_kills_the_whole_process_group`.
6. **The same session triaged on several dates** (reruns): the sampler keeps the latest findings only. Task 3, `test_latest_findings_file_wins_for_a_session`.

## File Structure

```
bin/l1-invoke.sh                     NEW  l1_build_prompt, l1_invoke_claude, L1_APPEND_SYSTEM_PROMPT (sourced)
bin/run.sh                           MOD  sources it via find_lib; AUTODREAM_L1_MODEL / AUTODREAM_L1_EFFORT
install.sh                           MOD  link the new script
tests/run-all.sh                     MOD  argv/prompt parity tests; runs the bench unit tests
bench/common.py                      NEW  paths, jsonl helpers, session_hash, Wilson interval, config loader
bench/config.json                    NEW  gate thresholds, run defaults, candidate matrix
bench/sample_cases.py                NEW  stratified sampler + freezer
bench/grade_l1.py                    NEW  the four objective checks, aggregation, gate, perf summary
bench/run-one-l1.sh                  NEW  bash driver: one L1 call through bin/l1-invoke.sh
bench/runner.py                      NEW  candidate runner (resume, timeout, backoff, served-model check)
bench/import_historical.py           NEW  grade existing production outputs, no model calls
bench/report.py                      NEW  markdown comparison table
bench/README.md                      NEW
bench/tests/                         NEW  test_common, test_sample_cases, test_grade_l1, test_runner,
                                          test_report, test_pipeline, fake_claude.sh
.gitignore                           MOD  bench/data/, __pycache__/
README.md, AGENTS.md, CHANGELOG.md, codemaps/architecture.md, prompts/PROMPT.md   MOD (wording)
```

Modules import each other as `from common import ...`; test files put `bench/` on `sys.path` themselves. Run tests from the repo root with `python3 -m unittest discover -s bench/tests`.

---

### Task 1: Shared L1 invocation

**Files:**
- Create: `bin/l1-invoke.sh`
- Modify: `bin/run.sh`, `install.sh`, `tests/run-all.sh`, `README.md`, `AGENTS.md`, `codemaps/architecture.md`, `prompts/PROMPT.md`, `CHANGELOG.md`
- Scratch (gitignored): `.tmp/task1_patch.py`

**Interfaces:**
- Produces (shell functions, sourced from `bin/l1-invoke.sh`):
  - `l1_build_prompt TRANSCRIPT OUTPUT TRIAGE_MD [STATS_JSON]` writes the L1 prompt to stdout; the stats block is appended only when `STATS_JSON` is a non-empty file.
  - `l1_invoke_claude MODEL EFFORT OUTPUT_FORMAT` reads the prompt on stdin and runs `"$CLAUDE_BIN"`; `EFFORT` and `OUTPUT_FORMAT` are omitted from the argv when empty.
  - `L1_APPEND_SYSTEM_PROMPT` (variable).
- Produces (`bin/run.sh`): env overrides `AUTODREAM_L1_MODEL` (default `claude-haiku-4-5`) and `AUTODREAM_L1_EFFORT` (default none); exported `L1_INVOKE_LIB` (path of the sourced file).
- Consumes: nothing from earlier tasks.

- [ ] **Step 1: Baseline**

```bash
git status --short
bash tests/run-all.sh 2>&1 | tail -3
```

Expected: `git status` shows only ` M bin/run.sh` (the uncommitted L1 experiment, which this task supersedes); the suite ends with `passed: 679   failed: 0`.

- [ ] **Step 2: Add the failing tests**

Create `.tmp/task1_patch.py` with this content, then run it in `tests` mode:

````python
"""Task 1 patch for cc-autodream: route the L1 worker through bin/l1-invoke.sh.
Run from the repo root:  python3 task1_patch.py tests   (then)   python3 task1_patch.py code
Every replacement asserts its anchor matches exactly once, so re-running fails loudly."""
import sys
from pathlib import Path

NEW_TESTS = r'''
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
'''


def edit(path, pairs):
    p = Path(path)
    t = p.read_text()
    for old, new in pairs:
        assert t.count(old) == 1, (path, t.count(old), old[:70])
        t = t.replace(old, new)
    p.write_text(t)


def patch_tests():
    edit("tests/run-all.sh", [
        ('echo "# L2: claude-opus-5-5 is the effective default; L1 is claude-sonnet-5-5"',
         'echo "# L2: claude-opus-5-5 is the effective default; L1 is claude-haiku-4-5"'),
        ("'^claude-sonnet-5-5$' \"L1 requests Sonnet 5.5\"", "'^claude-haiku-4-5$' \"L1 requests Haiku 4.5\""),
        ('\ntest_l2_model_pin_is_honoured\n', '\ntest_l2_model_pin_is_honoured\n' + NEW_TESTS),
    ])
    print("task 1 tests added")


def patch_code():
    # --- bin/run.sh -------------------------------------------------------------------
    t = Path("bin/run.sh").read_text()
    start = t.index('    {\n      printf "Session transcript to analyze')
    end_marker = '      > /dev/null 2> "$errlog"\n'
    end = t.index(end_marker, start) + len(end_marker)
    t = t[:start] + '''    l1_build_prompt "$readpath" "$output" "$AUTODREAM_DIR/SESSION_TRIAGE.md" "$FINDINGS_DIR/$hash.stats.json" \\
          | l1_invoke_claude "${AUTODREAM_L1_MODEL:-claude-haiku-4-5}" "${AUTODREAM_L1_EFFORT:-}" "" \\
          > /dev/null 2> "$errlog"
    ''' + t[end:]
    Path("bin/run.sh").write_text(t)
    edit("bin/run.sh", [
        ('PREFLIGHT=$(find_lib preflight.sh) || PREFLIGHT="$SCRIPT_DIR/preflight.sh"\n',
         'PREFLIGHT=$(find_lib preflight.sh) || PREFLIGHT="$SCRIPT_DIR/preflight.sh"\n'
         '# Shared L1 invocation (prompt assembly + the claude command). Also sourced by the model\n'
         '# benchmark in bench/, so the benchmark measures this exact call. Every L1 worker needs it.\n'
         'L1_INVOKE_LIB=$(find_lib l1-invoke.sh) || {\n'
         '  echo "fatal: l1-invoke.sh not found in $SCRIPT_DIR or the repo bin/ (re-run install.sh)" >&2\n'
         '  exit 70\n'
         '}\n'),
        ('export CLAUDE_BIN AUTODREAM_DIR FINDINGS_DIR SLIM WORK_DIR\n',
         'export CLAUDE_BIN AUTODREAM_DIR FINDINGS_DIR SLIM WORK_DIR L1_INVOKE_LIB\n'),
        ('    output="$FINDINGS_DIR/$hash.json"\n    errlog="$output.err"\n',
         '    output="$FINDINGS_DIR/$hash.json"\n    errlog="$output.err"\n    . "$L1_INVOKE_LIB"\n'),
        ("spawn a parallel `claude --model claude-sonnet-5-5`",
         "spawn a parallel `claude` (AUTODREAM_L1_MODEL, default claude-haiku-4-5)"),
        ("# ---- Layer 1: sonnet triage,", "# ---- Layer 1: triage,"),
    ])

    # --- install.sh: link the new sibling like every other bin/ script --------------------
    edit("install.sh", [(
        'link "$REPO_DIR/bin/root-probe.sh"           "$TARGET/root-probe.sh"\n',
        'link "$REPO_DIR/bin/root-probe.sh"           "$TARGET/root-probe.sh"\n'
        'link "$REPO_DIR/bin/l1-invoke.sh"            "$TARGET/l1-invoke.sh"\n')])

    # --- docs: put back the wording the Sonnet experiment changed ---------------------------
    edit("README.md", [("a per-session pass (`claude-sonnet-5-5`, low effort)", "a cheap per-session pass (`claude-haiku-4-5`)")])
    edit("AGENTS.md", [("SESSION_TRIAGE.md`, `claude-sonnet-5-5` at low effort, fanned", "SESSION_TRIAGE.md`, `claude-haiku-4-5`, fanned")])
    edit("codemaps/architecture.md", [("(claude-sonnet-5-5, low effort, lean flags)", "(claude-haiku-4-5, lean flags)")])
    edit("prompts/PROMPT.md", [("Layer 1 (Sonnet 5.5, fanned", "Layer 1 (haiku, fanned")])
    edit("CHANGELOG.md", [(
        "- **L1 is now `claude-sonnet-5-5` at `--effort low`** (was `claude-haiku-4-5`): about 2x per token ($2/$10 vs $1/$5) for a 1M context window and stronger judgment on compliance and missed-skill findings. Low effort keeps thinking-token cost down.\n",
        "- **L1 stays `claude-haiku-4-5`; L1 model and effort are now overridable** with `AUTODREAM_L1_MODEL` and `AUTODREAM_L1_EFFORT` (L2 already had `AUTODREAM_L2_MODEL`). Sonnet 5.5 at `--effort low` and `medium` returned `unclear_from_transcript` for 18 of 20 sessions on 2026-09-28. The L1 prompt assembly and `claude` command moved to `bin/l1-invoke.sh`, shared with the model benchmark in `bench/`.\n")])
    print("task 1 code and docs patched")

mode = sys.argv[1] if len(sys.argv) > 1 else ""
if mode == "tests":
    patch_tests()
elif mode == "code":
    patch_code()
else:
    sys.exit("usage: task1_patch.py tests|code")
````

```bash
mkdir -p .tmp
python3 .tmp/task1_patch.py tests
bash -n tests/run-all.sh && echo syntax-ok
```

Expected: `task 1 tests added`, then `syntax-ok`.

- [ ] **Step 3: Run the tests to verify they fail**

```bash
bash tests/run-all.sh 2>&1 | grep -E "FAIL|passed:"
```

Expected: exactly three failures and `passed: 684   failed: 3`:
`L1 requests Haiku 4.5`, `L1 argv is exactly the production command (no --effort by default)`, and `model then effort, in that order`.

- [ ] **Step 4: Create `bin/l1-invoke.sh`**

````bash
#!/bin/bash
# Shared L1 (per-session triage) invocation. Sourced by bin/run.sh and by the model
# benchmark (bench/run-one-l1.sh) so the benchmark measures the production call and
# the two cannot drift. Claude-harness only: other harnesses get their own adapters.
#
# No apostrophes in L1_APPEND_SYSTEM_PROMPT or in any function body a caller embeds
# inside a single-quoted `bash -c '...'` block.

L1_APPEND_SYSTEM_PROMPT='Headless triage worker. Read the session transcript and write exactly one findings JSON object, via the Write tool, to the literal output path given on line 2 of the prompt. Those paths are literal strings, not shell variables — never $-expand them. Print only the literal word done and exit.'

# l1_build_prompt TRANSCRIPT OUTPUT TRIAGE_MD [STATS_JSON] -> the L1 prompt on stdout.
# The paths are passed as LITERAL data so the worker hands them straight to Read/Write
# and never tries to $-expand them (see the 2026 worker-path failures).
l1_build_prompt() {
  printf 'Session transcript to analyze (literal absolute path): %s\n' "$1"
  printf 'Write your findings JSON to this literal absolute path: %s\n\n' "$2"
  cat "$3"
  if [ -n "${4:-}" ] && [ -s "$4" ]; then
    printf '\n## Precomputed session stats (authoritative — copy these into your output)\n\n```json\n'
    cat "$4"
    printf '\n```\n'
  fi
}

# l1_invoke_claude MODEL EFFORT OUTPUT_FORMAT  (prompt on stdin; needs $CLAUDE_BIN)
# EFFORT and OUTPUT_FORMAT are omitted from the argv when empty.
l1_invoke_claude() {
  local model="$1" effort="${2:-}" fmt="${3:-}"
  local -a args=(--print --permission-mode bypassPermissions --model "$model")
  [ -n "$effort" ] && args+=(--effort "$effort")
  [ -n "$fmt" ] && args+=(--output-format "$fmt")
  args+=(--no-session-persistence --tools Read Write --disable-slash-commands
         --strict-mcp-config --settings '{"disableAllHooks":true}'
         --append-system-prompt "$L1_APPEND_SYSTEM_PROMPT")
  "$CLAUDE_BIN" "${args[@]}"
}
````

```bash
chmod +x bin/l1-invoke.sh
bash -n bin/l1-invoke.sh && echo syntax-ok
```

- [ ] **Step 5: Apply the code patch**

```bash
python3 .tmp/task1_patch.py code
bash -n bin/run.sh && bash -n install.sh && echo syntax-ok
```

Expected: `task 1 code and docs patched`, then `syntax-ok`. The script asserts each anchor matches exactly once, so it fails loudly if `run.sh` has drifted.

- [ ] **Step 6: Run the suite to verify it passes**

```bash
bash tests/run-all.sh 2>&1 | tail -3
```

Expected: `passed: 687   failed: 0`.

- [ ] **Step 7: Check the diff**

```bash
git diff --stat
grep -n -- "--effort" bin/run.sh
```

Expected: `AGENTS.md`, `CHANGELOG.md`, `README.md`, `bin/run.sh`, `codemaps/architecture.md`, `install.sh`, `prompts/PROMPT.md`, `tests/run-all.sh` changed, plus the new untracked `bin/l1-invoke.sh`. `grep` prints nothing: the `--effort` flag now lives in `bin/l1-invoke.sh`. Optional: run `bash install.sh` to add the symlink under `~/.claude/autodream`; `run.sh` finds the file through the repo's `bin/` either way.

- [ ] **Step 8: Commit**

```bash
git add bin/l1-invoke.sh bin/run.sh install.sh tests/run-all.sh README.md AGENTS.md CHANGELOG.md codemaps/architecture.md prompts/PROMPT.md
git commit -m "refactor: share the L1 invocation via bin/l1-invoke.sh; add L1 model/effort overrides"
```

---

### Task 2: Benchmark scaffolding and shared helpers

**Files:**
- Create: `bench/common.py`, `bench/config.json`, `bench/tests/test_common.py`
- Modify: `.gitignore`

**Interfaces:**
- Produces (`bench/common.py`): `BENCH_DIR`, `REPO`, `DATA_DIR` (`Path`s); `session_hash(session_path) -> str` (12 hex, same as `run.sh`); `read_jsonl(path)` (generator of dict rows, skipping blank and invalid lines); `append_jsonl(path, row)` (fsyncs, starts a new line after a truncated one); `wilson(k, n) -> (lo, hi)` (`(None, None)` when `n == 0`, bounds clamped to 0..1); `rate(k, n) -> {"k","n","rate","ci"}`; `load_config(path=None) -> dict`.
- Produces (`bench/config.json`): `gate` thresholds, `grounding.min_ratio`, `run` defaults, `candidates` list.

- [ ] **Step 1: Write the failing test**

Create `bench/tests/test_common.py`:

````python
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import common  # noqa: E402


class SessionHash(unittest.TestCase):
    def test_matches_run_sh_derivation(self):
        path = "/Users/x/.claude/projects/-p/abc.jsonl"
        expect = subprocess.run(
            ["bash", "-c", 'printf "%s" "$1" | shasum -a 1 | cut -c1-12', "_", path],
            capture_output=True, text=True, check=True).stdout.strip()
        self.assertEqual(common.session_hash(path), expect)


class Jsonl(unittest.TestCase):
    def test_skips_garbage_and_missing_file(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "r.jsonl"
            self.assertEqual(list(common.read_jsonl(p)), [])
            p.write_text('{"a":1}\n\nnot json\n[1,2]\n{"b":2}\n{"c":')
            self.assertEqual(list(common.read_jsonl(p)), [{"a": 1}, {"b": 2}])

    def test_append_after_truncated_line_does_not_glue(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "r.jsonl"
            p.write_text('{"a":1}\n{"trunc":')
            common.append_jsonl(p, {"b": 2})
            self.assertEqual(list(common.read_jsonl(p)), [{"a": 1}, {"b": 2}])

    def test_append_creates_parent_dirs(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "x" / "y" / "r.jsonl"
            common.append_jsonl(p, {"ok": True})
            self.assertEqual(json.loads(p.read_text()), {"ok": True})


class Wilson(unittest.TestCase):
    def test_empty_is_none(self):
        self.assertEqual(common.wilson(0, 0), (None, None))
        self.assertIsNone(common.rate(0, 0)["rate"])

    def test_half(self):
        lo, hi = common.wilson(50, 100)
        self.assertAlmostEqual(lo, 0.404, places=2)
        self.assertAlmostEqual(hi, 0.596, places=2)

    def test_zero_successes_lower_bound_is_zero(self):
        lo, hi = common.wilson(0, 10)
        self.assertAlmostEqual(lo, 0.0, places=6)
        self.assertGreater(hi, 0.2)


if __name__ == "__main__":
    unittest.main()
````

- [ ] **Step 2: Run it to verify it fails**

```bash
python3 -m unittest discover -s bench/tests -p "test_common.py" 2>&1 | tail -4
```

Expected: `ModuleNotFoundError: No module named 'common'`.

- [ ] **Step 3: Write the implementation**

Create `bench/common.py`:

````python
"""Shared helpers for the autodream model benchmark. Stdlib only."""
import hashlib
import json
import math
import os
from pathlib import Path

BENCH_DIR = Path(__file__).resolve().parent
REPO = BENCH_DIR.parent
DATA_DIR = BENCH_DIR / "data"


def session_hash(session_path):
    """The 12-hex id run.sh derives for a session: first 12 chars of sha1(path)."""
    return hashlib.sha1(session_path.encode()).hexdigest()[:12]


def read_jsonl(path):
    """Yield dict rows from a JSONL file. Skips blank lines and any line that is not
    valid JSON (a crash can leave a truncated last line)."""
    p = Path(path)
    if not p.exists():
        return
    with p.open(encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(row, dict):
                yield row


def append_jsonl(path, row):
    """Append one row. If the file ends in a partial line (crash mid-write), start on a
    fresh line so the new row is not glued onto the garbage."""
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    prefix = ""
    if p.exists() and p.stat().st_size:
        with p.open("rb") as f:
            f.seek(-1, os.SEEK_END)
            if f.read(1) != b"\n":
                prefix = "\n"
    with p.open("a", encoding="utf-8") as f:
        f.write(prefix + json.dumps(row, ensure_ascii=False) + "\n")
        f.flush()
        os.fsync(f.fileno())


def wilson(successes, n, z=1.96):
    """Wilson score interval as (lo, hi); (None, None) when n == 0."""
    if n == 0:
        return (None, None)
    p = successes / n
    d = 1 + z * z / n
    c = p + z * z / (2 * n)
    m = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n))
    return (max(0.0, (c - m) / d), min(1.0, (c + m) / d))


def rate(k, n):
    """{'k','n','rate','ci'} with a Wilson interval; rate/ci are None when n == 0."""
    lo, hi = wilson(k, n)
    return {"k": k, "n": n, "rate": (k / n) if n else None, "ci": [lo, hi]}


def load_config(path=None):
    p = Path(path) if path else BENCH_DIR / "config.json"
    return json.loads(p.read_text(encoding="utf-8"))
````

Create `bench/config.json`:

````json
{
  "gate": {
    "validity_min": 0.98,
    "authoritative_min": 0.95,
    "hallucination_max": 0.1,
    "abstain_excess_max": 0.1
  },
  "grounding": {
    "min_ratio": 0.85
  },
  "run": {
    "concurrency": 2,
    "timeout_s": 900,
    "max_attempts": 3,
    "backoff_base_s": 30
  },
  "candidates": [
    {
      "model": "claude-haiku-4-5",
      "effort": ""
    },
    {
      "model": "claude-sonnet-5-5",
      "effort": "low"
    },
    {
      "model": "claude-sonnet-5-5",
      "effort": "medium"
    },
    {
      "model": "claude-sonnet-5-5",
      "effort": "high"
    },
    {
      "model": "claude-opus-5-5",
      "effort": "medium"
    },
    {
      "model": "claude-fable-5-1",
      "effort": "high"
    }
  ]
}
````

- [ ] **Step 4: Run the test to verify it passes**

```bash
python3 -m unittest discover -s bench/tests -p "test_common.py" 2>&1 | tail -4
```

Expected: `Ran 7 tests`, `OK`.

- [ ] **Step 5: Keep session content out of git**

Append to `.gitignore`:

```
# Model benchmark: frozen session transcripts and run output. Session content, never committed.
bench/data/
__pycache__/
```

```bash
mkdir -p bench/data && touch bench/data/probe.jsonl
git check-ignore -v bench/data/probe.jsonl
rm bench/data/probe.jsonl
git status --short
```

Expected: `check-ignore` prints the `.gitignore` line for `bench/data/`; `git status` does not list `bench/data`.

- [ ] **Step 6: Commit**

```bash
git add .gitignore bench/common.py bench/config.json bench/tests/test_common.py
git commit -m "feat(bench): shared helpers and config for the model benchmark"
```

---

### Task 3: Case sampler

**Files:**
- Create: `bench/sample_cases.py`, `bench/tests/test_sample_cases.py`

**Interfaces:**
- Consumes (Task 2): `session_hash`, `read_jsonl`, `DATA_DIR`, `REPO`.
- Produces (`bench/sample_cases.py`): `size_bucket(nbytes) -> str`; `iter_findings(root)`; `build_records(root) -> list[dict]`; `select(records, n, seed) -> list[dict]`; `freeze(chosen, out_dir, slim_script, slim_bytes=262144) -> list[dict]` which writes `out_dir/cases.jsonl` and `out_dir/inputs/`; `main(argv) -> int`.
- Produces (`cases.jsonl` row): `case_id`, `session_path`, `transcript` and `stats` (paths relative to the data dir), `project`, `size_bytes`, `slimmed`, `stratum`, `hist` (`outcome`, `underlying_goal`, `findings`), `findings_src`.

- [ ] **Step 1: Write the failing test**

Create `bench/tests/test_sample_cases.py`:

````python
import json
import stat
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import sample_cases as sc  # noqa: E402


def make_tree(root, sessions_dir):
    """findings/<date>/<hash>.json (+ .stats.json) for a mix of eligible/ineligible sessions."""
    def add(date, name, size, findings_obj, stats=True, transcript=True):
        sp = sessions_dir / f"{name}.jsonl"
        if transcript:
            sp.write_text("x" * size)
        obj = dict(findings_obj, session_path=str(sp))
        h = sc.session_hash(str(sp))
        d = root / date
        d.mkdir(parents=True, exist_ok=True)
        (d / f"{h}.json").write_text(json.dumps(obj))
        if stats:
            (d / f"{h}.stats.json").write_text(json.dumps({"turn_count": 3}))
        return str(sp)
    ok = {"project": "-p-a", "outcome": "fully_achieved", "findings": []}
    add("2026-09-01", "a", 100, ok)
    add("2026-09-02", "b", 100, dict(ok, project="-p-b", outcome="not_achieved", findings=[{"category": "tool_loop"}]))
    add("2026-09-02", "c", 300_000, dict(ok, project="-p-a"))
    add("2026-09-02", "err", 100, {"project": "-p-a", "error": "boom", "findings": []})
    add("2026-09-02", "gated", 100, {"project": "-p-a", "skipped": "below_noise_gate", "findings": []})
    add("2026-09-02", "nostats", 100, ok, stats=False)
    add("2026-09-02", "notranscript", 100, ok, transcript=False)
    # same session triaged on two dates: the later date must win
    sp = add("2026-09-01", "dup", 100, dict(ok, outcome="not_achieved"))
    add("2026-09-03", "dup", 100, dict(ok, outcome="fully_achieved"))
    return sp


class Sampling(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name) / "findings"
        self.sess = Path(self.tmp.name) / "sessions"
        self.sess.mkdir()
        self.dup = make_tree(self.root, self.sess)

    def tearDown(self):
        self.tmp.cleanup()

    def test_only_real_triages_with_transcript_and_stats(self):
        recs = sc.build_records(self.root)
        names = sorted(Path(r["session_path"]).stem for r in recs)
        self.assertEqual(names, ["a", "b", "c", "dup"])

    def test_latest_findings_file_wins_for_a_session(self):
        recs = {Path(r["session_path"]).stem: r for r in sc.build_records(self.root)}
        self.assertEqual(recs["dup"]["hist"]["outcome"], "fully_achieved")
        self.assertEqual(recs["dup"]["date"], "2026-09-03")

    def test_size_buckets(self):
        self.assertEqual(sc.size_bucket(10), "lt64k")
        self.assertEqual(sc.size_bucket(100_000), "lt256k")
        self.assertEqual(sc.size_bucket(500_000), "lt1m")
        self.assertEqual(sc.size_bucket(5_000_000), "ge1m")

    def test_select_is_deterministic_and_bounded(self):
        recs = sc.build_records(self.root)
        a = [r["case_id"] for r in sc.select(recs, 3, seed=1)]
        b = [r["case_id"] for r in sc.select(recs, 3, seed=1)]
        self.assertEqual(a, b)
        self.assertEqual(len(a), 3)
        self.assertEqual(len(sc.select(recs, 99, seed=1)), len(recs))

    def test_select_spreads_across_strata(self):
        recs = sc.build_records(self.root)
        chosen = sc.select(recs, 3, seed=5)
        self.assertEqual(len({r["stratum"] for r in chosen}), 3)

    def test_freeze_copies_small_and_slims_large(self):
        slim = Path(self.tmp.name) / "slim.sh"
        slim.write_text('#!/bin/bash\nprintf SLIMMED > "$2"\n')
        slim.chmod(slim.stat().st_mode | stat.S_IEXEC)
        recs = sc.build_records(self.root)
        out = Path(self.tmp.name) / "data"
        rows = {Path(r["session_path"]).stem: r
                for r in sc.freeze(recs, out, slim, slim_bytes=200_000)}
        self.assertFalse(rows["a"]["slimmed"])
        self.assertTrue(rows["c"]["slimmed"])
        self.assertEqual((out / rows["c"]["transcript"]).read_text(), "SLIMMED")
        self.assertEqual(len((out / rows["a"]["transcript"]).read_text()), 100)
        self.assertEqual(json.loads((out / rows["a"]["stats"]).read_text()), {"turn_count": 3})
        self.assertTrue(Path(rows["a"]["findings_src"]).is_file())
        written = [json.loads(l) for l in (out / "cases.jsonl").read_text().splitlines()]
        self.assertEqual(len(written), 4)

    def test_freeze_falls_back_to_original_when_slim_fails(self):
        slim = Path(self.tmp.name) / "slim.sh"
        slim.write_text("#!/bin/bash\nexit 1\n")
        slim.chmod(slim.stat().st_mode | stat.S_IEXEC)
        recs = [r for r in sc.build_records(self.root) if Path(r["session_path"]).stem == "c"]
        rows = sc.freeze(recs, Path(self.tmp.name) / "data", slim, slim_bytes=200_000)
        self.assertFalse(rows[0]["slimmed"])
        self.assertEqual(rows[0]["size_bytes"], 300_000)


if __name__ == "__main__":
    unittest.main()
````

- [ ] **Step 2: Run it to verify it fails**

```bash
python3 -m unittest discover -s bench/tests -p "test_sample_cases.py" 2>&1 | tail -4
```

Expected: `ModuleNotFoundError: No module named 'sample_cases'`.

- [ ] **Step 3: Write the implementation**

Create `bench/sample_cases.py`:

````python
"""Pick and freeze the L1 benchmark case set. Stdlib only.

Scans historical L1 findings, keeps sessions whose transcript still exists, picks a
stratified sample, and freezes the exact bytes each candidate will read (slimmed the
way production slims them) plus the stats sidecar, into bench/data/. Frozen inputs
hold session content: bench/data/ is gitignored and never committed.

Gated sessions (below the noise gate) and error stubs are excluded: production never
sends them to an L1 model, so they measure nothing.

Usage: python3 bench/sample_cases.py [--n 60] [--seed 7] [--findings-root DIR] [--out DIR]
"""
import argparse
import json
import random
import shutil
import subprocess
import sys
from pathlib import Path

from common import DATA_DIR, REPO, read_jsonl, session_hash  # noqa: F401

SKIP_NAMES = ("memory-candidates.json",)
DEFAULT_ROOT = Path.home() / ".claude" / "autodream" / "findings"
SLIM_BYTES = 262144  # AUTODREAM_SLIM_BYTES default in bin/run.sh


def size_bucket(nbytes):
    if nbytes < 64 * 1024:
        return "lt64k"
    if nbytes < 256 * 1024:
        return "lt256k"
    if nbytes < 1024 * 1024:
        return "lt1m"
    return "ge1m"


def iter_findings(root):
    """Yield (date, findings_path, obj) for every per-session findings JSON under root."""
    for day in sorted(Path(root).glob("20*")):
        if not day.is_dir():
            continue
        for f in sorted(day.glob("*.json")):
            if f.name.endswith(".stats.json") or f.name in SKIP_NAMES or f.name.startswith("skill-backfill"):
                continue
            try:
                obj = json.loads(f.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError):
                continue
            if isinstance(obj, dict):
                yield day.name, f, obj


def build_records(root):
    """One record per session (latest findings file wins). Eligible only when the file is
    a real triage (no error/skipped), the transcript exists, and the stats sidecar exists."""
    latest = {}
    for date, f, obj in iter_findings(root):
        sp = obj.get("session_path")
        if not isinstance(sp, str) or "error" in obj or "skipped" in obj:
            continue
        stats = f.with_name(f.stem + ".stats.json")
        if not Path(sp).is_file() or not stats.is_file():
            continue
        prev = latest.get(sp)
        if prev is not None and prev["date"] > date:
            continue
        outcome = obj.get("outcome")
        findings = obj.get("findings") if isinstance(obj.get("findings"), list) else []
        size = Path(sp).stat().st_size
        project = obj.get("project") or "unknown"
        latest[sp] = {
            "case_id": session_hash(sp),
            "date": date,
            "session_path": sp,
            "stats_src": str(stats),
            "findings_src": str(f),
            "project": project,
            "size_bytes": size,
            "stratum": "|".join([project, size_bucket(size), str(outcome), "F" if findings else "-"]),
            "hist": {"outcome": outcome, "underlying_goal": obj.get("underlying_goal"),
                     "findings": findings},
        }
    return list(latest.values())


def select(records, n, seed):
    """Round-robin over strata (deterministic for a seed) until n sessions are chosen."""
    rng = random.Random(seed)
    strata = {}
    for r in sorted(records, key=lambda r: r["case_id"]):
        strata.setdefault(r["stratum"], []).append(r)
    for rows in strata.values():
        rng.shuffle(rows)
    keys = sorted(strata)
    chosen = []
    while len(chosen) < n and any(strata[k] for k in keys):
        for k in keys:
            if strata[k] and len(chosen) < n:
                chosen.append(strata[k].pop())
    return chosen


def freeze(chosen, out_dir, slim_script, slim_bytes=SLIM_BYTES):
    """Copy (or slim) each transcript and copy its stats sidecar into out_dir/inputs/.
    Writes out_dir/cases.jsonl and returns the rows."""
    out_dir = Path(out_dir)
    inputs = out_dir / "inputs"
    inputs.mkdir(parents=True, exist_ok=True)
    rows = []
    for r in chosen:
        cid = r["case_id"]
        dst = inputs / f"{cid}.jsonl"
        slimmed = False
        if r["size_bytes"] > slim_bytes and Path(slim_script).is_file():
            cp = subprocess.run([str(slim_script), r["session_path"], str(dst)],
                                capture_output=True)
            slimmed = cp.returncode == 0 and dst.is_file() and dst.stat().st_size > 0
        if not slimmed:  # production reads the original when slimming fails
            shutil.copyfile(r["session_path"], dst)
        shutil.copyfile(r["stats_src"], inputs / f"{cid}.stats.json")
        rows.append({
            "case_id": cid, "session_path": r["session_path"],
            "transcript": f"inputs/{cid}.jsonl", "stats": f"inputs/{cid}.stats.json",
            "project": r["project"], "size_bytes": r["size_bytes"], "slimmed": slimmed,
            "stratum": r["stratum"], "hist": r["hist"], "findings_src": r["findings_src"],
        })
    with (out_dir / "cases.jsonl").open("w", encoding="utf-8") as f:
        for row in rows:
            f.write(json.dumps(row, ensure_ascii=False) + "\n")
    return rows


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--n", type=int, default=60)
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--findings-root", default=str(DEFAULT_ROOT))
    ap.add_argument("--out", default=str(DATA_DIR))
    ap.add_argument("--slim-script", default=str(REPO / "bin" / "slim-transcript.sh"))
    a = ap.parse_args(argv)
    records = build_records(a.findings_root)
    if not records:
        print(f"no eligible sessions under {a.findings_root}", file=sys.stderr)
        return 2
    chosen = select(records, a.n, a.seed)
    rows = freeze(chosen, a.out, a.slim_script)
    print(f"{len(records)} eligible sessions; froze {len(rows)} into {a.out}/cases.jsonl "
          f"({sum(1 for r in rows if r['slimmed'])} slimmed)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
````

- [ ] **Step 4: Run the test to verify it passes**

```bash
python3 -m unittest discover -s bench/tests -p "test_sample_cases.py" 2>&1 | tail -4
```

Expected: `Ran 7 tests`, `OK`.

- [ ] **Step 5: Smoke-test on the real corpus (read-only, scratch output)**

```bash
python3 bench/sample_cases.py --n 5 --out .tmp/bench-smoke
head -c 400 .tmp/bench-smoke/cases.jsonl; echo
rm -rf .tmp/bench-smoke
```

Expected: a line like `NNN eligible sessions; froze 5 into .tmp/bench-smoke/cases.jsonl (N slimmed)` (about 400 eligible sessions), then the start of a JSON row with `case_id`, `session_path`, `transcript`. The scratch copies hold session content, so they are removed straight away.

- [ ] **Step 6: Commit**

```bash
git add bench/sample_cases.py bench/tests/test_sample_cases.py
git commit -m "feat(bench): stratified L1 case sampler with frozen inputs"
```

---

### Task 4: Grader

**Files:**
- Create: `bench/grade_l1.py`, `bench/tests/test_grade_l1.py`

**Interfaces:**
- Consumes (Task 2): `load_config`, `rate`, `read_jsonl`, `DATA_DIR`.
- Produces (`bench/grade_l1.py`): `check_validity(obj) -> list[str]`; `check_authoritative(obj, stats) -> list[str]`; `transcript_text(path) -> str`; `is_grounded`, `anchors`, `ground_finding(excerpt, haystack, min_ratio, hay_compact) -> "verbatim"|"anchored"|"unverifiable"|"ungrounded"`; `depth_flags(obj, hist_outcome) -> dict`; `grade_row(row, case, obj, stats, haystack, cfg) -> dict`; `evaluate_gate(metrics, cfg) -> {"pass","failed"}`; `aggregate(graded, cfg) -> dict`; `perf_summary(rows, errors) -> dict`; `grade_run(run_dir, cases_path, cfg) -> summary`, which writes `graded.jsonl` and `summary.json` into the run directory.
- A run's `results.jsonl` row (written by Task 5) has: `case_id`, `rep`, `status` (`ok`, `no_output`, `invalid_json`), `findings_path` (relative to the run dir), `usage`, `api_cost_usd`, `latency_s`, `served_verified`.

- [ ] **Step 1: Write the failing test**

Create `bench/tests/test_grade_l1.py`:

````python
import copy
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import grade_l1 as g  # noqa: E402
from common import load_config  # noqa: E402

CFG = load_config()
# Pin the gate logic to fixed thresholds so tuning bench/config.json never breaks these tests.
CFG["gate"] = {"validity_min": 0.98, "authoritative_min": 1.0,
               "hallucination_max": 0.02, "abstain_excess_max": 0.10}
STATS = {"turn_count": 5, "tool_call_count": 2, "tools_used": ["Bash", "Read"],
         "skills_invoked": [], "models_used": ["claude-opus-5-5"],
         "compliance_markers": {"RETRY-BUDGET": 0, "FETCH-PIVOT": 0, "DELEGATED": 0, "DIRECT-OK": 0}}
GOOD = {
    "session_path": "/s/x.jsonl", "project": "-p", "started_at": "2026-09-27",
    "turn_count": 5, "tool_call_count": 2, "tools_used": ["Read", "Bash"],
    "skills_invoked": [], "models_used": ["claude-opus-5-5"],
    "notable_initiatives": ["Fix the flaky deploy"],
    "compliance_markers": dict(STATS["compliance_markers"]),
    "underlying_goal": "ship the deploy", "outcome": "fully_achieved",
    "satisfaction_signals": {"happy": 0, "satisfied": 0, "dissatisfied": 0, "frustrated": 0},
    "instructions_given": ["always run tests"],
    "findings": [{"category": "tool_loop", "severity": "low", "what": "retried curl",
                  "evidence_excerpt": "curl -s http://localhost:8080/health returned 503",
                  "proposed_rule": "stop after 2 retries"}],
}
HAY = g.normalize("The assistant ran curl -s http://localhost:8080/health returned 503 again and again. "
                  '{"is_error": true}')
FABRICATED = "ran `rm -rf /srv/prod_data` and then executed deploy_everything.sh on the box"


def variant(**kw):
    o = copy.deepcopy(GOOD)
    o.update(kw)
    return o


class Validity(unittest.TestCase):
    def test_good_is_valid(self):
        self.assertEqual(g.check_validity(GOOD), [])

    def test_null_outputs_are_invalid(self):
        for bad in (None, [], "done", {}, {"error": "x", "findings": []}):
            self.assertTrue(g.check_validity(bad), bad)

    def test_specific_violations(self):
        self.assertTrue(g.check_validity(variant(outcome="great")))
        self.assertTrue(g.check_validity(variant(findings="none")))
        self.assertTrue(g.check_validity(variant(instructions_given=["a", "b", "c", "d"])))
        self.assertTrue(g.check_validity(variant(satisfaction_signals={"happy": 1})))
        self.assertTrue(g.check_validity(variant(findings=[dict(GOOD["findings"][0], category="assumption_unsurfaced")])))
        self.assertTrue(g.check_validity(variant(findings=[dict(GOOD["findings"][0], severity="urgent")])))
        self.assertTrue(g.check_validity(variant(findings=[GOOD["findings"][0]] * 11)))

    def test_empty_findings_is_valid(self):
        self.assertEqual(g.check_validity(variant(findings=[])), [])


class Authoritative(unittest.TestCase):
    def test_list_order_is_ignored(self):
        self.assertEqual(g.check_authoritative(GOOD, STATS), [])

    def test_mismatches_are_named(self):
        bad = variant(turn_count=6, tools_used=["Bash"])
        self.assertEqual(sorted(g.check_authoritative(bad, STATS)), ["tools_used", "turn_count"])

    def test_keys_absent_from_stats_are_skipped(self):
        self.assertEqual(g.check_authoritative(GOOD, {"turn_count": 5}), [])


class Grounding(unittest.TestCase):
    def test_exact_and_whitespace_insensitive(self):
        self.assertTrue(g.is_grounded("curl -s   http://localhost:8080/health\nreturned 503", HAY))

    def test_fuzzy_survives_small_edits(self):
        self.assertTrue(g.is_grounded("curl -s http://localhost:8080/health returned 5O3", HAY))

    def test_fabricated_is_not_grounded(self):
        self.assertFalse(g.is_grounded("the user said this deploy will definitely never work", HAY))

    def test_empty_and_tiny_are_not_grounded(self):
        self.assertFalse(g.is_grounded("", HAY))
        self.assertFalse(g.is_grounded("zzqx", HAY))

    def test_transcript_text_flattens_json_strings(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "t.jsonl"
            p.write_text(json.dumps({"message": {"content": [{"text": 'said "hello"\nworld'}]}}) + "\nplain line\n")
            text = g.transcript_text(p)
            self.assertIn('said "hello" world', text)
            self.assertIn("plain line", text)


class GroundingTiers(unittest.TestCase):
    """Production L1 often paraphrases with line references instead of quoting verbatim."""

    def tier(self, excerpt):
        return g.ground_finding(excerpt, HAY)

    def test_verbatim(self):
        self.assertEqual(self.tier("curl -s http://localhost:8080/health returned 503"), "verbatim")

    def test_paraphrase_with_a_real_quoted_command_is_anchored(self):
        self.assertEqual(self.tier("Line 12: agent ran `curl -s http://localhost:8080/health` repeatedly, no pivot"), "anchored")

    def test_matching_ignores_spacing_and_punctuation(self):
        self.assertEqual(self.tier("Lines 84/88/93 returned is_error:true results with no pivot strategy"), "anchored")

    def test_contractions_are_not_quotes_but_wrapped_spans_are(self):
        self.assertEqual(g.anchors("it doesn't work and they can't tell what's wrong"), [])
        self.assertEqual(g.anchors("it said 'sandbox blocks writes to the sibling repo' twice"),
                         ["sandbox blocks writes to the sibling repo"])

    def test_line_references_and_bare_words_are_not_anchors(self):
        self.assertEqual(g.anchors("Lines 84/88/93 and 121/125, the marker. was missing"), [])

    def test_paraphrase_with_nothing_checkable_is_unverifiable_not_hallucinated(self):
        self.assertEqual(self.tier("the agent kept retrying the same thing without changing approach"), "unverifiable")

    def test_checkable_fragments_that_are_absent_are_ungrounded(self):
        self.assertEqual(self.tier(FABRICATED), "ungrounded")

    def test_half_of_the_anchors_present_is_enough(self):
        self.assertEqual(self.tier("ran `curl -s http://localhost:8080/health` then `rm -rf /srv/prod_data`"), "anchored")

    def test_anchors_are_deduplicated_and_lowercased(self):
        a = g.anchors("ran `Deploy_Prod.sh` then deploy_prod.sh again")
        self.assertEqual(len(a), 1)

    def test_transcript_text_includes_keys_and_scalars(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "t.jsonl"
            p.write_text(json.dumps({"is_error": True, "n": 3}) + "\n")
            text = g.transcript_text(p)
            self.assertIn("is_error", text)
            self.assertIn("true", text)


class Depth(unittest.TestCase):
    def test_flags(self):
        d = g.depth_flags(variant(outcome="unclear_from_transcript"), "fully_achieved")
        self.assertEqual(d, {"decided_ref": True, "abstained": True, "header_only": False})

    def test_no_historical_outcome_is_not_decided(self):
        self.assertFalse(g.depth_flags(GOOD, None)["decided_ref"])
        self.assertFalse(g.depth_flags(GOOD, "unclear_from_transcript")["decided_ref"])

    def test_header_only_phrases(self):
        for phrase in ("Long session (only session header read; transcript body not reviewed)",
                       "content not reviewed in detail", "only the opening hook lines were read, header"):
            self.assertTrue(g.depth_flags(variant(notable_initiatives=[phrase]), "fully_achieved")["header_only"], phrase)
        self.assertFalse(g.depth_flags(GOOD, "fully_achieved")["header_only"])


def grade(obj, hist="fully_achieved", status="ok"):
    row = {"case_id": "c1", "rep": 0, "status": status}
    return g.grade_row(row, {"hist": {"outcome": hist}}, obj, STATS, HAY, CFG)


class Rows(unittest.TestCase):
    def test_good_row(self):
        r = grade(GOOD)
        self.assertTrue(r["valid"] and r["authoritative_ok"])
        self.assertEqual((r["findings_n"], r["ungrounded_n"]), (1, 0))

    def test_hallucinated_evidence_is_counted(self):
        bad = variant(findings=[dict(GOOD["findings"][0], evidence_excerpt=FABRICATED)])
        r = grade(bad)
        self.assertEqual(r["ungrounded_n"], 1)
        self.assertEqual(r["grounding"]["ungrounded"], 1)

    def test_findings_copied_from_another_session_fail_grounding(self):
        other = g.normalize("A different session entirely: the user asked about pasta recipes.")
        row = {"case_id": "c1", "rep": 0, "status": "ok"}
        r = g.grade_row(row, {"hist": {"outcome": "fully_achieved"}}, GOOD, STATS, other, CFG)
        self.assertEqual(r["grounding"]["ungrounded"], 1)

    def test_failed_statuses_are_invalid(self):
        for status in ("no_output", "invalid_json"):
            r = grade(None, status=status)
            self.assertFalse(r["valid"])
            self.assertEqual(r["problems"], [status])

    def test_invalid_object_skips_downstream_checks(self):
        r = grade(variant(outcome="great"))
        self.assertFalse(r["valid"])
        self.assertIsNone(r["depth"])


class Gate(unittest.TestCase):
    def rows(self, n_ok, n_abstain, hist="fully_achieved"):
        out = [grade(GOOD, hist) for _ in range(n_ok)]
        out += [grade(variant(outcome="unclear_from_transcript"), hist) for _ in range(n_abstain)]
        return out

    def test_oracle_passes(self):
        m = g.aggregate(self.rows(20, 0), CFG)
        self.assertTrue(m["gate"]["pass"], m["gate"])

    def test_null_fails(self):
        m = g.aggregate([grade(None, status="no_output") for _ in range(20)], CFG)
        self.assertFalse(m["gate"]["pass"])
        self.assertIn("validity", m["gate"]["failed"])

    def test_the_2026_09_28_sonnet_failure_is_caught(self):
        # 18 of 20 sessions came back unclear_from_transcript
        m = g.aggregate(self.rows(2, 18), CFG)
        self.assertAlmostEqual(m["abstain_excess"]["rate"], 0.9)
        self.assertEqual(m["gate"]["failed"], ["abstain_excess"])

    def test_abstaining_where_reference_did_not_decide_is_not_penalised(self):
        m = g.aggregate(self.rows(0, 20, hist=None), CFG)
        self.assertIsNone(m["abstain_excess"]["rate"])
        self.assertIn("abstain_excess_unmeasured", m["gate"]["failed"])

    def test_authoritative_must_be_exact(self):
        rows = self.rows(19, 0) + [grade(variant(turn_count=99))]
        m = g.aggregate(rows, CFG)
        self.assertIn("authoritative", m["gate"]["failed"])

    def test_hallucination_ceiling(self):
        bad = variant(findings=[dict(GOOD["findings"][0], evidence_excerpt=FABRICATED)])
        m = g.aggregate([grade(bad)] + self.rows(10, 0), CFG)
        self.assertIn("hallucination", m["gate"]["failed"])

    def test_zero_findings_everywhere_does_not_divide_by_zero(self):
        rows = [grade(variant(findings=[])) for _ in range(20)]
        m = g.aggregate(rows, CFG)
        self.assertIsNone(m["hallucination"]["rate"])
        self.assertTrue(m["gate"]["pass"])


class Perf(unittest.TestCase):
    def test_summary(self):
        rows = [{"latency_s": s, "usage": {"input_tokens": 10, "output_tokens": 5}, "api_cost_usd": 0.1,
                 "served_verified": True} for s in (1, 2, 3, 4)]
        rows[0]["served_verified"] = None
        p = g.perf_summary(rows, [{"failure_class": "timeout"}, {"failure_class": "timeout"}])
        self.assertEqual(p["latency_p50_s"], 3)
        self.assertEqual(p["errors"], {"timeout": 2})
        self.assertEqual(p["unverified_served_model"], 1)
        self.assertAlmostEqual(p["api_cost_usd_total"], 0.4)

    def test_empty(self):
        p = g.perf_summary([], [])
        self.assertIsNone(p["latency_p50_s"])
        self.assertIsNone(p["api_cost_usd_per_case"])


if __name__ == "__main__":
    unittest.main()
````

- [ ] **Step 2: Run it to verify it fails**

```bash
python3 -m unittest discover -s bench/tests -p "test_grade_l1.py" 2>&1 | tail -4
```

Expected: `ModuleNotFoundError: No module named 'grade_l1'`.

- [ ] **Step 3: Write the implementation**

Create `bench/grade_l1.py`:

````python
"""Objective grading of L1 triage output (Phase 1). Stdlib only.

Four reference-free checks per output, then rates per candidate and an eligibility gate:
  1. validity           schema, enums, caps, retired category, zeroed satisfaction_signals
  2. authoritative      fields the prompt says to copy must equal the stats sidecar
  3. grounding          every finding's evidence must be checkable in the frozen transcript:
                        verbatim match, else its quoted/identifier fragments (Haiku paraphrases)
  4. depth              abstain_excess: says unclear_from_transcript where the historical
                        stand-in (Haiku, Phase 1) decided an outcome; header-only phrases

Usage: python3 bench/grade_l1.py --run bench/data/runs/<label> [--cases PATH] [--config PATH]
"""
import argparse
import difflib
import json
import re
import statistics
import sys
from pathlib import Path

from common import DATA_DIR, load_config, rate, read_jsonl

CATEGORIES = {
    "missed_skill", "wrong_skill", "sandbox_friction", "memory_miss", "tool_loop",
    "permission_prompt", "fabricated_id", "stop_projection", "drift_after_compaction",
    "buggy_code_shipped",
}
SEVERITIES = {"high", "medium", "low"}
OUTCOMES = ("fully_achieved", "mostly_achieved", "partially_achieved", "not_achieved",
            "unclear_from_transcript")
DECIDED = set(OUTCOMES[:4])
AUTHORITATIVE = ("turn_count", "tool_call_count", "tools_used", "skills_invoked",
                 "models_used", "compliance_markers")
LIST_KEYS = {"tools_used", "skills_invoked", "models_used"}
HEADER_ONLY = re.compile(
    r"(?:only|just)[^.;]{0,40}\bheader\b|not reviewed|not summari[sz]ed|transcript body not",
    re.I)


def check_validity(obj):
    """List of problems; empty means valid."""
    if not isinstance(obj, dict):
        return ["not an object"]
    problems = []
    if "error" in obj:
        problems.append("error object")
    if not isinstance(obj.get("session_path"), str):
        problems.append("session_path missing")
    if obj.get("outcome") not in OUTCOMES:
        problems.append(f"outcome {obj.get('outcome')!r}")
    findings = obj.get("findings")
    if not isinstance(findings, list):
        problems.append("findings not a list")
    else:
        if len(findings) > 10:
            problems.append("more than 10 findings")
        for i, f in enumerate(findings):
            if not isinstance(f, dict):
                problems.append(f"finding {i} not an object")
                continue
            cat = f.get("category")
            if cat == "assumption_unsurfaced":
                problems.append("retired category assumption_unsurfaced")
            elif cat not in CATEGORIES:
                problems.append(f"finding {i} category {cat!r}")
            if f.get("severity") not in SEVERITIES:
                problems.append(f"finding {i} severity {f.get('severity')!r}")
            for k in ("what", "evidence_excerpt", "proposed_rule"):
                v = f.get(k)
                if not isinstance(v, str) or not v.strip():
                    problems.append(f"finding {i} {k} missing")
    sat = obj.get("satisfaction_signals")
    if not isinstance(sat, dict) or any(v != 0 for v in sat.values()):
        problems.append("satisfaction_signals not all zero")
    ig = obj.get("instructions_given")
    if not isinstance(ig, list) or len(ig) > 3 or not all(isinstance(x, str) for x in ig):
        problems.append("instructions_given invalid")
    return problems


def _norm_list(v):
    if isinstance(v, list):
        try:
            return sorted(v)
        except TypeError:
            return v
    return v


def check_authoritative(obj, stats):
    """Names of authoritative fields that differ from the stats sidecar."""
    bad = []
    for k in AUTHORITATIVE:
        if k not in stats:
            continue
        a, b = obj.get(k), stats[k]
        if k in LIST_KEYS:
            a, b = _norm_list(a), _norm_list(b)
        if a != b:
            bad.append(k)
    return bad


def normalize(s):
    return re.sub(r"\s+", " ", s).strip().lower()


def _collect_strings(v, out):
    """Strings, dict keys and scalar values (so `"is_error": true` is searchable)."""
    if isinstance(v, str):
        out.append(v)
    elif isinstance(v, dict):
        for k, x in v.items():
            out.append(str(k))
            _collect_strings(x, out)
    elif isinstance(v, list):
        for x in v:
            _collect_strings(x, out)
    elif v is not None:
        out.append(json.dumps(v))


def transcript_text(path):
    """All string content of a JSONL transcript, joined and normalized for matching."""
    parts = []
    for line in Path(path).read_text(encoding="utf-8", errors="replace").splitlines():
        try:
            _collect_strings(json.loads(line), parts)
        except json.JSONDecodeError:
            parts.append(line)
    return normalize(" ".join(parts))


def is_grounded(excerpt, haystack, min_ratio=0.85):
    ex = normalize(excerpt)
    if not ex:
        return False
    if ex in haystack:
        return True
    ex = ex.strip(" .…\"'`")
    if not ex or ex in haystack:
        return bool(ex)
    if len(ex) < 12:
        return False
    n = len(ex)
    step = max(1, n // 4)
    sm = difflib.SequenceMatcher(autojunk=False)
    sm.set_seq2(ex)
    for i in range(0, max(1, len(haystack) - n + 1), step):
        sm.set_seq1(haystack[i:i + n])
        if (sm.real_quick_ratio() >= min_ratio and sm.quick_ratio() >= min_ratio
                and sm.ratio() >= min_ratio):
            return True
    return False


# Single quotes only count when they wrap a span (not contractions or stray apostrophes).
QUOTED = re.compile(r"(?<![a-z0-9])'([^']{4,200}?)'(?![a-z0-9])|\"([^\"]{4,200}?)\"|`([^`]{3,200}?)`")
SPECIAL = re.compile(r"[a-z0-9_.\-/:]{6,}")


def compact(s):
    """Lowercase alphanumerics only: matching that ignores spacing and punctuation."""
    return re.sub(r"[^a-z0-9]", "", s.lower())


def anchors(excerpt):
    """Checkable fragments of an excerpt: quoted spans, and tokens containing _ / . or :
    (commands, paths, identifiers). Production L1 often paraphrases with line references
    instead of quoting verbatim, so these are what can still be checked. Fragments with
    no letters (line references such as 84/88/93) are not checkable and are skipped."""
    ex = normalize(excerpt)
    found = [next(g for g in m.groups() if g) for m in QUOTED.finditer(ex)]
    for w in SPECIAL.findall(ex):
        w = w.strip(".:-/")
        if any(c in w for c in "_/.:"):
            found.append(w)
    out, seen = [], set()
    for a in found:
        c = compact(a)
        if len(c) >= 4 and re.search(r"[a-z]", c) and c not in seen:
            seen.add(c)
            out.append(a)
    return out


def ground_finding(excerpt, haystack, min_ratio=0.85, hay_compact=None):
    """'verbatim' (fuzzy match of the whole excerpt), 'anchored' (at least half of its
    quoted/identifier fragments appear in the transcript), 'unverifiable' (nothing
    checkable to look for), or 'ungrounded' (checkable fragments, most of them absent)."""
    if is_grounded(excerpt, haystack, min_ratio):
        return "verbatim"
    a = anchors(excerpt)
    if not a:
        return "unverifiable"
    hc = hay_compact if hay_compact is not None else compact(haystack)
    hits = sum(1 for x in a if compact(x) in hc)
    return "anchored" if hits * 2 >= len(a) else "ungrounded"


def depth_flags(obj, hist_outcome):
    ni = " ".join(x for x in (obj.get("notable_initiatives") or []) if isinstance(x, str))
    return {
        "decided_ref": hist_outcome in DECIDED,
        "abstained": obj.get("outcome") == "unclear_from_transcript",
        "header_only": bool(HEADER_ONLY.search(ni)),
    }


def grade_row(row, case, obj, stats, haystack, cfg):
    """Grade one result row. obj is the parsed findings JSON (or None)."""
    g = {"case_id": row["case_id"], "rep": row["rep"], "status": row["status"],
         "valid": False, "problems": [], "authoritative_ok": None, "auth_mismatch": [],
         "findings_n": 0, "ungrounded_n": 0, "grounding": None, "depth": None}
    if row["status"] != "ok" or obj is None:
        g["problems"] = [row["status"] if row["status"] != "ok" else "unreadable"]
        return g
    g["problems"] = check_validity(obj)
    g["valid"] = not g["problems"]
    if not g["valid"]:
        return g
    g["auth_mismatch"] = check_authoritative(obj, stats)
    g["authoritative_ok"] = not g["auth_mismatch"]
    ratio = cfg["grounding"]["min_ratio"]
    findings = obj["findings"]
    g["findings_n"] = len(findings)
    hc = compact(haystack)
    tiers = [ground_finding(f["evidence_excerpt"], haystack, ratio, hc) for f in findings]
    g["grounding"] = {k: tiers.count(k) for k in ("verbatim", "anchored", "unverifiable", "ungrounded")}
    g["ungrounded_n"] = g["grounding"]["ungrounded"]
    g["depth"] = depth_flags(obj, (case.get("hist") or {}).get("outcome"))
    return g


def evaluate_gate(m, cfg):
    t, failed = cfg["gate"], []
    v = m["validity"]["rate"]
    if v is None or v < t["validity_min"]:
        failed.append("validity")
    a = m["authoritative"]["rate"]
    if a is None or a < t["authoritative_min"]:
        failed.append("authoritative")
    h = m["hallucination"]["rate"]
    if h is not None and h > t["hallucination_max"]:
        failed.append("hallucination")
    x = m["abstain_excess"]["rate"]
    if x is None:
        failed.append("abstain_excess_unmeasured")
    elif x > t["abstain_excess_max"]:
        failed.append("abstain_excess")
    return {"pass": not failed, "failed": failed}


def aggregate(graded, cfg):
    """Rates with Wilson intervals, then the gate. graded = list of grade_row dicts."""
    valid = [g for g in graded if g["valid"]]
    decided = [g for g in valid if g["depth"]["decided_ref"]]
    m = {
        "validity": rate(len(valid), len(graded)),
        "authoritative": rate(sum(1 for g in valid if g["authoritative_ok"]), len(valid)),
        "hallucination": rate(sum(g["ungrounded_n"] for g in valid),
                              sum(g["findings_n"] for g in valid)),
        "abstain_excess": rate(sum(1 for g in decided if g["depth"]["abstained"]), len(decided)),
        "header_only": rate(sum(1 for g in valid if g["depth"]["header_only"]), len(valid)),
        "verbatim": rate(sum(g["grounding"]["verbatim"] for g in valid),
                         sum(g["findings_n"] for g in valid)),
    }
    m["gate"] = evaluate_gate(m, cfg)
    return m


def perf_summary(rows, errors):
    lat = sorted(r["latency_s"] for r in rows if r.get("latency_s") is not None)

    def pct(p):
        return lat[min(len(lat) - 1, int(p * len(lat)))] if lat else None

    def mean_of(key):
        vals = [r["usage"].get(key, 0) for r in rows if r.get("usage")]
        return statistics.mean(vals) if vals else None
    costs = [r["api_cost_usd"] for r in rows if r.get("api_cost_usd") is not None]
    by_class = {}
    for e in errors:
        by_class[e["failure_class"]] = by_class.get(e["failure_class"], 0) + 1
    return {
        "latency_p50_s": pct(0.5), "latency_p95_s": pct(0.95),
        "mean_input_tokens": mean_of("input_tokens"), "mean_output_tokens": mean_of("output_tokens"),
        "mean_cache_creation_tokens": mean_of("cache_creation_input_tokens"),
        "api_cost_usd_per_case": statistics.mean(costs) if costs else None,
        "api_cost_usd_total": sum(costs) if costs else None,
        "errors": by_class, "unverified_served_model": sum(1 for r in rows if r.get("served_verified") is None),
    }


def grade_run(run_dir, cases_path, cfg):
    run_dir = Path(run_dir)
    cases = {c["case_id"]: c for c in read_jsonl(cases_path)}
    data = Path(cases_path).parent
    rows = {}
    for r in read_jsonl(run_dir / "results.jsonl"):
        rows[(r["case_id"], r["rep"])] = r
    errors = list(read_jsonl(run_dir / "errors.jsonl"))
    hay, stats_cache, graded = {}, {}, []
    for (cid, rep), row in sorted(rows.items()):
        case = cases.get(cid)
        if case is None:
            continue
        obj = None
        if row["status"] == "ok":
            try:
                obj = json.loads((run_dir / row["findings_path"]).read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError):
                obj = None
        if cid not in stats_cache:
            stats_cache[cid] = json.loads((data / case["stats"]).read_text(encoding="utf-8"))
            hay[cid] = transcript_text(data / case["transcript"])
        graded.append(grade_row(row, case, obj, stats_cache[cid], hay[cid], cfg))
    meta = {}
    if (run_dir / "run.json").exists():
        meta = json.loads((run_dir / "run.json").read_text(encoding="utf-8"))
    summary = {"label": run_dir.name, "model": meta.get("model"), "effort": meta.get("effort"),
               "rows": len(graded), "metrics": aggregate(graded, cfg),
               "perf": perf_summary(list(rows.values()), errors)}
    with (run_dir / "graded.jsonl").open("w", encoding="utf-8") as f:
        for g in graded:
            f.write(json.dumps(g, ensure_ascii=False) + "\n")
    (run_dir / "summary.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")
    return summary


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--run", required=True)
    ap.add_argument("--cases", default=str(DATA_DIR / "cases.jsonl"))
    ap.add_argument("--config", default=None)
    a = ap.parse_args(argv)
    s = grade_run(a.run, a.cases, load_config(a.config))
    gate = s["metrics"]["gate"]
    print(f"{s['label']}: {s['rows']} rows, gate {'PASS' if gate['pass'] else 'FAIL ' + ','.join(gate['failed'])}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
````

- [ ] **Step 4: Run the test to verify it passes**

```bash
python3 -m unittest discover -s bench/tests -p "test_grade_l1.py" 2>&1 | tail -4
```

Expected: `Ran 39 tests`, `OK`.

- [ ] **Step 5: Commit**

```bash
git add bench/grade_l1.py bench/tests/test_grade_l1.py
git commit -m "feat(bench): objective L1 grader with tiered evidence grounding and gate"
```

---

### Task 5: Candidate runner

**Files:**
- Create: `bench/runner.py`, `bench/run-one-l1.sh`, `bench/tests/fake_claude.sh`, `bench/tests/test_runner.py`

**Interfaces:**
- Consumes (Task 1): `bin/l1-invoke.sh` (`l1_build_prompt`, `l1_invoke_claude`). Consumes (Task 2): `append_jsonl`, `read_jsonl`, `load_config`, `BENCH_DIR`, `DATA_DIR`. Consumes (Task 3): `cases.jsonl` rows.
- Produces (`bench/runner.py`): `served_model_check(cli, requested) -> (served|None, ok|None)`; `classify_failure(rc, stderr, cli, timed_out) -> str|None`; `findings_status(path) -> "ok"|"no_output"|"invalid_json"`; `run_attempt`, `run_job`; `main(argv) -> int`.
- Produces (run directory `bench/data/runs/<label>/`): `results.jsonl` rows (`case_id`, `rep`, `requested_model`, `effort`, `served_model`, `served_verified`, `status`, `findings_path`, `usage`, `api_cost_usd`, `latency_s`, `retries`); `errors.jsonl` rows (`case_id`, `rep`, `failure_class` in `timeout|rate_limit|refusal|cli_error|model_mismatch`, `attempts`, `retries`, `usage`, `latency_s`, `detail`); `run.json`; `findings/`; `cli/`.
- Produces (`bench/run-one-l1.sh MODEL EFFORT FINDINGS_OUT TRANSCRIPT STATS CLI_JSON_OUT`): runs one L1 call with `--output-format json`, stdout to `CLI_JSON_OUT`.

- [ ] **Step 1: Write the failing tests and the fake CLI**

Create `bench/tests/fake_claude.sh`:

````bash
#!/bin/bash
# Fake `claude` for runner tests. Reads the prompt on stdin like the real CLI.
# FAKE_MODE: good | unclear | nooutput | badjson | hang | cli_error | always_rate_limit |
#            rate_limit_then_good | refusal | wrongmodel | nomodelusage
# FAKE_COUNTER: file used by rate_limit_then_good; FAKE_FAIL_FIRST: failures before success.
input=$(cat)
model=""
while [ $# -gt 0 ]; do
  case "$1" in --model) model="$2"; shift 2 ;; *) shift ;; esac
done
out=$(printf '%s\n' "$input" | sed -n '2p' | sed 's/^Write your findings JSON to this literal absolute path: //')
mode="${FAKE_MODE:-good}"
served="$model"
[ "$mode" = wrongmodel ] && served="claude-sonnet-5-5"
case "$mode" in
  hang) sleep 60; exit 0 ;;
  cli_error) echo "boom" >&2; exit 1 ;;
  always_rate_limit) echo "Error: usage limit reached" >&2; exit 1 ;;
  rate_limit_then_good)
    n=$(cat "$FAKE_COUNTER" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$FAKE_COUNTER"
    if [ "$n" -le "${FAKE_FAIL_FIRST:-1}" ]; then echo "API Error: 429 rate limit exceeded" >&2; exit 1; fi ;;
esac
case "$mode" in
  nooutput) : ;;
  badjson) printf 'this is not json' > "$out" ;;
  unclear) printf '{"session_path":"/x","project":"p","outcome":"unclear_from_transcript","satisfaction_signals":{"happy":0,"satisfied":0,"dissatisfied":0,"frustrated":0},"instructions_given":[],"notable_initiatives":["only session header read"],"findings":[]}' > "$out" ;;
  *) printf '{"session_path":"/x","project":"p","outcome":"fully_achieved","satisfaction_signals":{"happy":0,"satisfied":0,"dissatisfied":0,"frustrated":0},"instructions_given":[],"notable_initiatives":["did a thing"],"findings":[]}' > "$out" ;;
esac
stop=end_turn; [ "$mode" = refusal ] && stop=refusal
if [ "$mode" = nomodelusage ]; then mu=''; else
  mu=",\"modelUsage\":{\"$served\":{\"inputTokens\":10,\"outputTokens\":5,\"cacheReadInputTokens\":0,\"cacheCreationInputTokens\":100,\"costUSD\":0.01}}"
fi
printf '{"type":"result","subtype":"success","is_error":false,"stop_reason":"%s","result":"done","total_cost_usd":0.01,"usage":{"input_tokens":10,"output_tokens":5,"cache_creation_input_tokens":100,"cache_read_input_tokens":0}%s}\n' "$stop" "$mu"
````

Create `bench/tests/test_runner.py`:

````python
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import runner  # noqa: E402
from common import append_jsonl, read_jsonl  # noqa: E402

FAKE = str(Path(__file__).resolve().parent / "fake_claude.sh")


class Pure(unittest.TestCase):
    def test_served_model_matches_dated_ids(self):
        cli = {"modelUsage": {"claude-haiku-4-5-20251001": {"inputTokens": 5}}}
        self.assertEqual(runner.served_model_check(cli, "claude-haiku-4-5"), ("claude-haiku-4-5-20251001", True))

    def test_served_model_mismatch_and_dominance(self):
        cli = {"modelUsage": {"claude-haiku-4-5": {"inputTokens": 3}, "claude-opus-5-5": {"inputTokens": 900}}}
        self.assertEqual(runner.served_model_check(cli, "claude-haiku-4-5"), ("claude-opus-5-5", False))

    def test_served_model_prefix_is_not_a_substring_match(self):
        cli = {"modelUsage": {"claude-opus-5-55": {"inputTokens": 1}}}
        self.assertFalse(runner.served_model_check(cli, "claude-opus-5-5")[1])

    def test_unverified_when_no_model_usage(self):
        self.assertEqual(runner.served_model_check({}, "m"), (None, None))
        self.assertEqual(runner.served_model_check(None, "m"), (None, None))

    def test_classify(self):
        c = runner.classify_failure
        self.assertEqual(c(0, "", {"stop_reason": "end_turn"}, False), None)
        self.assertEqual(c(1, "429 rate limit", None, False), "rate_limit")
        self.assertEqual(c(1, "usage limit reached", None, False), "rate_limit")
        self.assertEqual(c(1, "boom", None, False), "cli_error")
        self.assertEqual(c(0, "", {"stop_reason": "refusal"}, False), "refusal")
        self.assertEqual(c(0, "", {}, True), "timeout")

    def test_findings_status(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "f.json"
            self.assertEqual(runner.findings_status(p), "no_output")
            p.write_text("")
            self.assertEqual(runner.findings_status(p), "no_output")
            p.write_text("nope")
            self.assertEqual(runner.findings_status(p), "invalid_json")
            p.write_text("[1]")
            self.assertEqual(runner.findings_status(p), "invalid_json")
            p.write_text('{"a":1}')
            self.assertEqual(runner.findings_status(p), "ok")


class EndToEnd(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.data = Path(self.tmp.name) / "data"
        (self.data / "inputs").mkdir(parents=True)
        self.cases = self.data / "cases.jsonl"
        for cid in ("c1", "c2"):
            (self.data / "inputs" / f"{cid}.jsonl").write_text('{"type":"user"}\n')
            (self.data / "inputs" / f"{cid}.stats.json").write_text("{}")
            append_jsonl(self.cases, {"case_id": cid, "transcript": f"inputs/{cid}.jsonl",
                                      "stats": f"inputs/{cid}.stats.json"})
        self.out = Path(self.tmp.name) / "runs"

    def tearDown(self):
        self.tmp.cleanup()

    def run_main(self, *extra, mode="good", env=None):
        argv = ["--model", "claude-haiku-4-5", "--cases", str(self.cases), "--out", str(self.out),
                "--claude-bin", FAKE, "--backoff-base", "0", "--label", "t", *extra]
        with mock.patch.dict(os.environ, dict({"FAKE_MODE": mode}, **(env or {}))):
            return runner.main(argv)

    def rows(self, name):
        return list(read_jsonl(self.out / "t" / name))

    def test_dry_run_and_missing_confirm_make_no_calls(self):
        self.assertEqual(self.run_main("--dry-run"), 0)
        self.assertEqual(self.run_main(), 2)
        self.assertFalse((self.out / "t" / "results.jsonl").exists())

    def test_good_run_records_model_usage_cost_and_latency(self):
        self.assertEqual(self.run_main("--confirm"), 0)
        rows = self.rows("results.jsonl")
        self.assertEqual(sorted(r["case_id"] for r in rows), ["c1", "c2"])
        r = rows[0]
        self.assertEqual((r["status"], r["served_model"], r["served_verified"]), ("ok", "claude-haiku-4-5", True))
        self.assertEqual(r["usage"]["cache_creation_input_tokens"], 100)
        self.assertEqual(r["api_cost_usd"], 0.01)
        self.assertGreater(r["latency_s"], 0)
        self.assertTrue((self.out / "t" / r["findings_path"]).is_file())

    def test_resume_skips_finished_and_does_not_duplicate(self):
        self.run_main("--confirm")
        self.run_main("--confirm")
        self.assertEqual(len(self.rows("results.jsonl")), 2)

    def test_resume_tolerates_a_truncated_last_line(self):
        self.run_main("--confirm", "--limit", "1")
        with (self.out / "t" / "results.jsonl").open("a") as f:
            f.write('{"case_id":"c2","rep":')
        self.run_main("--confirm")
        self.assertEqual(sorted(r["case_id"] for r in self.rows("results.jsonl")), ["c1", "c2"])

    def test_reps_are_separate_slots(self):
        self.run_main("--confirm", "--reps", "2")
        self.assertEqual(len(self.rows("results.jsonl")), 4)

    def test_no_output_and_bad_json_are_results_not_errors(self):
        self.run_main("--confirm", mode="nooutput")
        self.assertEqual({r["status"] for r in self.rows("results.jsonl")}, {"no_output"})
        self.assertEqual(self.rows("errors.jsonl"), [])

    def test_bad_json_status(self):
        self.run_main("--confirm", mode="badjson")
        self.assertEqual({r["status"] for r in self.rows("results.jsonl")}, {"invalid_json"})

    def test_cli_error_goes_to_errors_only(self):
        self.run_main("--confirm", mode="cli_error")
        self.assertEqual(self.rows("results.jsonl"), [])
        self.assertEqual({e["failure_class"] for e in self.rows("errors.jsonl")}, {"cli_error"})

    def test_refusal_is_classified(self):
        self.run_main("--confirm", mode="refusal")
        self.assertEqual({e["failure_class"] for e in self.rows("errors.jsonl")}, {"refusal"})

    def test_served_model_mismatch_fails_the_attempt(self):
        self.run_main("--confirm", mode="wrongmodel")
        self.assertEqual(self.rows("results.jsonl"), [])
        errs = self.rows("errors.jsonl")
        self.assertEqual({e["failure_class"] for e in errs}, {"model_mismatch"})
        self.assertEqual(errs[0]["served_model"], "claude-sonnet-5-5")

    def test_missing_model_usage_is_recorded_as_unverified(self):
        self.run_main("--confirm", mode="nomodelusage")
        rows = self.rows("results.jsonl")
        self.assertEqual(len(rows), 2)
        self.assertTrue(all(r["served_verified"] is None for r in rows))

    def test_rate_limit_retries_with_backoff_then_succeeds(self):
        counter = Path(self.tmp.name) / "n"
        self.run_main("--confirm", "--limit", "1", mode="rate_limit_then_good",
                      env={"FAKE_COUNTER": str(counter), "FAKE_FAIL_FIRST": "2"})
        rows = self.rows("results.jsonl")
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["retries"], 2)
        self.assertEqual(self.rows("errors.jsonl"), [])

    def test_rate_limit_gives_up_after_max_attempts(self):
        self.run_main("--confirm", "--limit", "1", mode="always_rate_limit")
        errs = self.rows("errors.jsonl")
        self.assertEqual([e["failure_class"] for e in errs], ["rate_limit"])
        self.assertEqual((errs[0]["attempts"], errs[0]["retries"]), (3, 2))

    def test_timeout_kills_the_whole_process_group(self):
        self.run_main("--confirm", "--limit", "1", "--timeout", "1", mode="hang")
        errs = self.rows("errors.jsonl")
        self.assertEqual([e["failure_class"] for e in errs], ["timeout"])
        self.assertEqual(self.rows("results.jsonl"), [])


if __name__ == "__main__":
    unittest.main()
````

```bash
chmod +x bench/tests/fake_claude.sh
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
python3 -m unittest discover -s bench/tests -p "test_runner.py" 2>&1 | tail -4
```

Expected: `ModuleNotFoundError: No module named 'runner'`.

- [ ] **Step 3: Write the driver and the runner**

Create `bench/run-one-l1.sh`:

````bash
#!/bin/bash
# Run ONE L1 triage through the production invocation (bin/l1-invoke.sh).
# Usage: run-one-l1.sh MODEL EFFORT FINDINGS_OUT TRANSCRIPT STATS CLI_JSON_OUT
# The claude CLI runs with --output-format json; its stdout goes to CLI_JSON_OUT so the
# runner can read the served model and usage. stderr passes through to the caller.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
model="$1"; effort="$2"; out="$3"; transcript="$4"; stats="$5"; cli_json="$6"
CLAUDE_BIN="${CLAUDE_BIN:-$HOME/.local/bin/claude}"
export CLAUDE_BIN
# Same token-minimal footprint run.sh exports for its workers.
export CLAUDE_CODE_DISABLE_CLAUDE_MDS=1 DISABLE_TELEMETRY=1 DISABLE_ERROR_REPORTING=1
. "$REPO/bin/l1-invoke.sh"
# Isolated cwd, like run.sh's worker dir, so any AI-title stub never lands in a real bucket.
workdir=$(mktemp -d "${TMPDIR:-/tmp}/bench-l1.XXXXXX") || exit 70
trap 'rm -rf "$workdir"' EXIT
cd "$workdir" || exit 70
l1_build_prompt "$transcript" "$out" "$REPO/prompts/SESSION_TRIAGE.md" "$stats" \
  | l1_invoke_claude "$model" "$effort" json > "$cli_json"
````

Create `bench/runner.py`:

````python
"""Candidate runner for the L1 benchmark. Stdlib only.

Runs one candidate (model, effort) over every frozen case through the production L1
invocation (bin/l1-invoke.sh via bench/run-one-l1.sh, on your CLI subscription). One row
is written per finished (case, rep); resume is idempotent on that key. Infrastructure
failures (timeout, rate limit, refusal, CLI error, served-model mismatch) go to
errors.jsonl and never occupy a result slot.

Usage: python3 bench/runner.py --model M [--effort E] [--reps N] [--dry-run | --confirm]
"""
import argparse
import json
import os
import random
import re
import signal
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path

from common import BENCH_DIR, DATA_DIR, append_jsonl, load_config, read_jsonl

DRIVER = BENCH_DIR / "run-one-l1.sh"
RATE_LIMIT = re.compile(r"rate.?limit|usage limit|overloaded|\b429\b|\b529\b", re.I)
USAGE_KEYS = ("input_tokens", "output_tokens", "cache_creation_input_tokens",
              "cache_read_input_tokens")


def _matches(requested, served):
    return served == requested or served.startswith(requested + "-")


def served_model_check(cli, requested):
    """(dominant served model or None, ok). ok is None when the CLI gave no modelUsage
    (unverified), True when the dominant model is the requested one, else False."""
    mu = cli.get("modelUsage") if isinstance(cli, dict) else None
    if not isinstance(mu, dict) or not mu:
        return None, None

    def weight(v):
        if not isinstance(v, dict):
            return 0
        return sum(v.get(k) or 0 for k in ("inputTokens", "outputTokens",
                                          "cacheReadInputTokens", "cacheCreationInputTokens"))
    dominant = max(mu, key=lambda m: weight(mu[m]))
    info = mu[dominant] if isinstance(mu[dominant], dict) else {}
    canon = info.get("canonicalModel")
    ok = _matches(requested, dominant) or (isinstance(canon, str) and _matches(requested, canon))
    return dominant, ok


def classify_failure(rc, stderr, cli, timed_out):
    """One of timeout / refusal / rate_limit / cli_error, or None when the call succeeded."""
    if timed_out:
        return "timeout"
    if isinstance(cli, dict) and cli.get("stop_reason") == "refusal":
        return "refusal"
    is_err = isinstance(cli, dict) and cli.get("is_error")
    if rc != 0 or is_err:
        blob = (stderr or "") + " " + (json.dumps(cli)[:2000] if cli else "")
        return "rate_limit" if RATE_LIMIT.search(blob) else "cli_error"
    return None


def findings_status(path):
    p = Path(path)
    if not p.is_file() or p.stat().st_size == 0:
        return "no_output"
    try:
        obj = json.loads(p.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return "invalid_json"
    return "ok" if isinstance(obj, dict) else "invalid_json"


def _load_json(path):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None


class Ctx:
    def __init__(self, a, data_dir, run_dir, cfg):
        self.model, self.effort = a.model, a.effort
        self.reps, self.timeout = a.reps, a.timeout
        self.claude_bin = a.claude_bin
        self.max_attempts = cfg["run"]["max_attempts"]
        self.backoff_base = a.backoff_base
        self.data, self.run_dir = data_dir, run_dir
        self.lock = threading.Lock()

    def backoff(self, retries):
        return min(self.backoff_base * 2 ** (retries - 1), 600) * (0.5 + random.random())

    def write(self, name, row):
        with self.lock:
            append_jsonl(self.run_dir / name, row)


def run_attempt(ctx, case, rep):
    cid = case["case_id"]
    findings = ctx.run_dir / "findings" / f"{cid}_rep{rep}.json"
    cli_json = ctx.run_dir / "cli" / f"{cid}_rep{rep}.json"
    for p in (findings, cli_json):
        p.parent.mkdir(parents=True, exist_ok=True)
        p.unlink(missing_ok=True)
    cmd = ["bash", str(DRIVER), ctx.model, ctx.effort, str(findings),
           str(ctx.data / case["transcript"]), str(ctx.data / case["stats"]), str(cli_json)]
    env = dict(os.environ, CLAUDE_BIN=ctx.claude_bin)
    t0 = time.monotonic()
    proc = subprocess.Popen(cmd, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                            text=True, start_new_session=True)
    timed_out = False
    try:
        _, err = proc.communicate(timeout=ctx.timeout)
    except subprocess.TimeoutExpired:
        timed_out = True
        os.killpg(proc.pid, signal.SIGKILL)  # the whole group: bash, the CLI, its children
        _, err = proc.communicate()
    latency = time.monotonic() - t0
    cli = _load_json(cli_json)
    failure = classify_failure(proc.returncode, err or "", cli, timed_out)
    served, ok = served_model_check(cli, ctx.model)
    if failure is None and ok is False:
        failure = "model_mismatch"
    return {"failure": failure, "cli": cli, "latency_s": round(latency, 2), "served": served,
            "served_ok": ok, "findings": findings, "detail": (err or "")[-300:]}


def run_job(ctx, case, rep):
    cid, attempts, retries = case["case_id"], 0, 0
    while True:
        attempts += 1
        a = run_attempt(ctx, case, rep)
        if a["failure"] is None:
            break
        if a["failure"] == "rate_limit" and attempts < ctx.max_attempts:
            retries += 1
            time.sleep(ctx.backoff(retries))
            continue
        cli = a["cli"] if isinstance(a["cli"], dict) else {}
        ctx.write("errors.jsonl", {
            "case_id": cid, "rep": rep, "failure_class": a["failure"], "attempts": attempts,
            "retries": retries, "requested_model": ctx.model, "served_model": a["served"],
            "usage": {k: (cli.get("usage") or {}).get(k, 0) for k in USAGE_KEYS} if cli else None,
            "latency_s": a["latency_s"], "detail": a["detail"]})
        return
    cli = a["cli"] if isinstance(a["cli"], dict) else {}
    ctx.write("results.jsonl", {
        "case_id": cid, "rep": rep, "requested_model": ctx.model, "effort": ctx.effort,
        "served_model": a["served"], "served_verified": a["served_ok"],
        "status": findings_status(a["findings"]),
        "findings_path": str(a["findings"].relative_to(ctx.run_dir)),
        "usage": {k: (cli.get("usage") or {}).get(k, 0) for k in USAGE_KEYS},
        "api_cost_usd": cli.get("total_cost_usd"), "latency_s": a["latency_s"],
        "retries": retries})


def parse_args(argv):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    cfg = load_config()
    ap.add_argument("--model", required=True)
    ap.add_argument("--effort", default="")
    ap.add_argument("--label", default=None)
    ap.add_argument("--reps", type=int, default=1)
    ap.add_argument("--concurrency", type=int, default=cfg["run"]["concurrency"])
    ap.add_argument("--timeout", type=int, default=cfg["run"]["timeout_s"])
    ap.add_argument("--backoff-base", type=float, default=cfg["run"]["backoff_base_s"])
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--cases", default=str(DATA_DIR / "cases.jsonl"))
    ap.add_argument("--out", default=str(DATA_DIR / "runs"))
    ap.add_argument("--claude-bin", default=os.environ.get("CLAUDE_BIN") or str(Path.home() / ".local/bin/claude"))
    ap.add_argument("--dry-run", action="store_true", help="print the plan; make no calls")
    ap.add_argument("--confirm", action="store_true", help="required to make real calls")
    return ap.parse_args(argv)


def main(argv=None):
    a = parse_args(argv)
    cfg = load_config()
    cases = list(read_jsonl(a.cases))
    if a.limit:
        cases = cases[:a.limit]
    if not cases:
        print(f"no cases in {a.cases}; run bench/sample_cases.py first", file=sys.stderr)
        return 2
    label = a.label or f"{a.model}@{a.effort or 'default'}"
    run_dir = Path(a.out) / label
    ctx = Ctx(a, Path(a.cases).parent, run_dir, cfg)
    done = {(r["case_id"], r["rep"]) for r in read_jsonl(run_dir / "results.jsonl")}
    todo = [(c, rep) for c in cases for rep in range(a.reps) if (c["case_id"], rep) not in done]
    print(f"plan: {a.model} effort={a.effort or 'default'} | {len(cases)} cases x {a.reps} reps"
          f" = {len(cases) * a.reps} calls, {len(todo)} to run ({len(done)} already done)"
          f" | concurrency {a.concurrency}, timeout {a.timeout}s")
    print("These calls run on your Claude subscription and count against its usage cap.")
    if a.dry_run:
        return 0
    if not a.confirm:
        print("Not running: pass --confirm to make real calls (or --dry-run).", file=sys.stderr)
        return 2
    run_dir.mkdir(parents=True, exist_ok=True)
    (run_dir / "run.json").write_text(json.dumps({
        "model": a.model, "effort": a.effort, "label": label, "reps": a.reps,
        "started_at": datetime.now(timezone.utc).isoformat()}, indent=2), encoding="utf-8")
    with ThreadPoolExecutor(max_workers=a.concurrency) as pool:
        list(pool.map(lambda job: run_job(ctx, *job), todo))
    ok = sum(1 for _ in read_jsonl(run_dir / "results.jsonl"))
    err = sum(1 for _ in read_jsonl(run_dir / "errors.jsonl"))
    print(f"done: {ok} result rows, {err} error rows in {run_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
````

```bash
chmod +x bench/run-one-l1.sh
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
python3 -m unittest discover -s bench/tests -p "test_runner.py" 2>&1 | tail -4
```

Expected: `Ran 20 tests`, `OK` (about 2 seconds; one test exercises a real timeout kill).

- [ ] **Step 5: Probe every candidate model for the served-model field (real CLI, tiny calls)**

This uses your subscription for one trivial call per candidate and needs network access. It confirms that the CLI's JSON reports each candidate under a key that `served_model_check` accepts (the requested id, optionally followed by `-<date>`).

```bash
probe() { # $1=model  $2=effort ("" = none)
  local args=(--print --output-format json --model "$1" --no-session-persistence --tools ""
              --disable-slash-commands --strict-mcp-config --settings '{"disableAllHooks":true}')
  [ -n "$2" ] && args+=(--effort "$2")
  claude "${args[@]}" "Reply with the single word: ok" \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print(sorted(d.get("modelUsage",{})), d.get("is_error"), d.get("stop_reason"))'
}
probe claude-haiku-4-5 ""
probe claude-sonnet-5-5 low
probe claude-opus-5-5 medium
probe claude-fable-5-1 high
```

Expected: one line per model such as `['claude-haiku-4-5'] False end_turn` (Haiku was verified when this plan was written). If a model prints an empty list, its rows will be marked `served_verified: null` (acceptable, and the report counts them). If it prints a different id, adjust `_matches` in `bench/runner.py` and add a test before continuing.

- [ ] **Step 6: Commit**

```bash
git add bench/runner.py bench/run-one-l1.sh bench/tests/fake_claude.sh bench/tests/test_runner.py
git commit -m "feat(bench): resumable L1 candidate runner on the production invocation"
```

---

### Task 6: Report, historical baseline, wiring, docs

**Files:**
- Create: `bench/report.py`, `bench/import_historical.py`, `bench/tests/test_report.py`, `bench/tests/test_pipeline.py`, `bench/README.md`
- Modify: `tests/run-all.sh`, `README.md`, `AGENTS.md`, `CHANGELOG.md`

**Interfaces:**
- Consumes (Tasks 2 to 5): `DATA_DIR`, `rate`, `append_jsonl`, `read_jsonl`, `findings_status`, `grade_run`, `sample_cases.main`, `runner.main`.
- Produces: `report.render(summaries) -> str`; `report.main(argv) -> int` (writes `bench/data/report.md`); `import_historical.main(argv) -> int` (creates the run directory `bench/data/runs/historical/`).

- [ ] **Step 1: Write the failing report test**

Create `bench/tests/test_report.py`:

````python
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import report  # noqa: E402
from common import rate  # noqa: E402


def summary(label, passed, failed=()):
    return {
        "label": label, "model": label.split("@")[0], "effort": label.split("@")[1], "rows": 20,
        "metrics": {
            "validity": rate(20, 20), "authoritative": rate(20, 20), "hallucination": rate(0, 15), "verbatim": rate(0, 15),
            "abstain_excess": rate(1, 18), "header_only": rate(0, 20),
            "gate": {"pass": passed, "failed": list(failed)},
        },
        "perf": {"latency_p50_s": 12.3, "latency_p95_s": 40.0, "mean_input_tokens": 10,
                 "mean_output_tokens": 500, "mean_cache_creation_tokens": 8000,
                 "api_cost_usd_per_case": 0.0421, "api_cost_usd_total": 0.84,
                 "errors": {"timeout": 1}, "unverified_served_model": 0},
    }


class Render(unittest.TestCase):
    def test_gate_passers_come_first_and_failures_are_named(self):
        md = report.render([summary("b@low", False, ["abstain_excess"]), summary("a@high", True)])
        self.assertLess(md.index("a@high"), md.index("b@low"))
        self.assertIn("FAIL: abstain_excess", md)
        self.assertIn("PASS", md)

    def test_absolute_numbers_and_rates_with_intervals(self):
        md = report.render([summary("a@high", True)])
        self.assertIn("12.3 / 40.0 s", md)
        self.assertIn("$0.042", md)
        self.assertIn("8010 in / 500 out", md)
        self.assertIn("100% (84-100, n=20)", md)
        self.assertIn("timeout:1", md)

    def test_no_blended_score_column(self):
        self.assertNotIn("score", report.render([summary("a@high", True)]).split("## Notes")[0].lower())

    def test_rows_are_identified_by_run_label_not_model(self):
        a, b = summary("m@low", True), summary("m@high", True)
        a["model"] = b["model"] = "same-model"
        md = report.render([a, b])
        self.assertIn("m@low", md)
        self.assertIn("m@high", md)

    def test_empty_rates_render_as_na(self):
        s = summary("a@high", True)
        s["metrics"]["abstain_excess"] = rate(0, 0)
        self.assertIn("n/a", report.render([s]))

    def test_main_writes_file_and_skips_ungraded_runs(self):
        with tempfile.TemporaryDirectory() as d:
            runs = Path(d) / "runs"
            (runs / "a@high").mkdir(parents=True)
            (runs / "a@high" / "summary.json").write_text(json.dumps(summary("a@high", True)))
            (runs / "ungraded").mkdir()
            out = Path(d) / "report.md"
            self.assertEqual(report.main(["--runs", str(runs / "a@high"), str(runs / "ungraded"), "--out", str(out)]), 0)
            self.assertIn("a@high", out.read_text())
            self.assertEqual(report.main(["--runs", str(runs / "ungraded"), "--out", str(out)]), 2)


if __name__ == "__main__":
    unittest.main()
````

- [ ] **Step 2: Run it to verify it fails**

```bash
python3 -m unittest discover -s bench/tests -p "test_report.py" 2>&1 | tail -4
```

Expected: `ModuleNotFoundError: No module named 'report'`.

- [ ] **Step 3: Write `bench/report.py`**

````python
"""Render graded L1 runs as a markdown comparison table. Stdlib only.

No blended score: quality checks, latency, tokens and API-equivalent cost stay in
separate columns. Gate-passers are listed first; Phase 1 has no quality ranking beyond
the gate (Phase 2 adds agreement with the reference).

Usage: python3 bench/report.py [--runs DIR ...] [--out PATH]
"""
import argparse
import json
import sys
from pathlib import Path

from common import DATA_DIR

NOTES = [
    "`abstain_excess` is measured against Haiku's historical outcome for the same session "
    "(the Phase 1 stand-in for the reference), so a Haiku candidate scores 0 by construction.",
    "Rates show a 95% Wilson interval and the denominator. Differences smaller than the "
    "interval are within noise.",
    "Evidence is graded in tiers: verbatim quote, else anchored (its quoted commands and identifiers "
    "appear in the transcript), else unverifiable (nothing checkable) or ungrounded. Only ungrounded "
    "counts as hallucinated. Production L1 mostly paraphrases, so verbatim is informational.",
    "Cost is the CLI's API-equivalent list cost, shown for information: runs use the subscription.",
]


def fmt_rate(r):
    if r is None or r["rate"] is None:
        return "n/a"
    lo, hi = r["ci"]
    return f"{r['rate'] * 100:.0f}% ({lo * 100:.0f}-{hi * 100:.0f}, n={r['n']})"


def fmt_num(v, digits=1, prefix=""):
    return "n/a" if v is None else f"{prefix}{v:.{digits}f}"


def row(s):
    m, p = s["metrics"], s["perf"]
    gate = m["gate"]
    errs = ", ".join(f"{k}:{v}" for k, v in sorted(p["errors"].items())) or "0"
    tokens = "n/a"
    if p["mean_input_tokens"] is not None:
        tokens = (f"{p['mean_input_tokens'] + (p['mean_cache_creation_tokens'] or 0):.0f} in / "
                  f"{p['mean_output_tokens']:.0f} out")
    return "| " + " | ".join([
        s["label"],
        "PASS" if gate["pass"] else "FAIL: " + ", ".join(gate["failed"]),
        str(s["rows"]),
        fmt_rate(m["validity"]), fmt_rate(m["authoritative"]), fmt_rate(m["hallucination"]),
        fmt_rate(m["verbatim"]), fmt_rate(m["abstain_excess"]), fmt_rate(m["header_only"]),
        f"{fmt_num(p['latency_p50_s'])} / {fmt_num(p['latency_p95_s'])} s",
        tokens, fmt_num(p["api_cost_usd_per_case"], 3, "$"), errs,
        str(p["unverified_served_model"]),
    ]) + " |"


def render(summaries):
    order = sorted(summaries, key=lambda s: (not s["metrics"]["gate"]["pass"], s["label"]))
    head = ("| candidate | gate | rows | validity | authoritative | hallucinated evidence | "
            "verbatim evidence | abstain_excess | header-only | latency p50 / p95 | tokens per case | "
            "API-equiv $/case | errors | unverified model |")
    sep = "|" + "---|" * 14
    lines = ["# L1 benchmark (Phase 1: objective checks)", "", head, sep]
    lines += [row(s) for s in order]
    lines += ["", "## Notes", ""] + [f"- {n}" for n in NOTES]
    return "\n".join(lines) + "\n"


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--runs", nargs="*", default=None)
    ap.add_argument("--out", default=str(DATA_DIR / "report.md"))
    a = ap.parse_args(argv)
    runs = [Path(r) for r in a.runs] if a.runs else sorted((DATA_DIR / "runs").glob("*"))
    summaries = []
    for r in runs:
        f = r / "summary.json"
        if f.is_file():
            summaries.append(json.loads(f.read_text(encoding="utf-8")))
        else:
            print(f"skipping {r}: no summary.json (run grade_l1.py first)", file=sys.stderr)
    if not summaries:
        print("nothing to report", file=sys.stderr)
        return 2
    Path(a.out).write_text(render(summaries), encoding="utf-8")
    print(f"wrote {a.out} ({len(summaries)} candidates)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
````

- [ ] **Step 4: Run it to verify it passes**

```bash
python3 -m unittest discover -s bench/tests -p "test_report.py" 2>&1 | tail -4
```

Expected: `Ran 6 tests`, `OK`.

- [ ] **Step 5: Add the importer and the pipeline test**

Create `bench/import_historical.py`:

````python
"""Import the historical L1 outputs for the frozen cases as a benchmark run. Stdlib only.

No model calls: it copies the findings each case already has on disk into a run directory,
so the grader can be calibrated on real production output before any subscription usage
is spent. Its `abstain_excess` is 0 by construction (it is the stand-in reference).

Usage: python3 bench/import_historical.py [--cases PATH] [--out DIR] [--label historical]
"""
import argparse
import json
import shutil
import sys
from pathlib import Path

from common import DATA_DIR, append_jsonl, read_jsonl
from runner import findings_status


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--cases", default=str(DATA_DIR / "cases.jsonl"))
    ap.add_argument("--out", default=str(DATA_DIR / "runs"))
    ap.add_argument("--label", default="historical")
    a = ap.parse_args(argv)
    run_dir = Path(a.out) / a.label
    (run_dir / "findings").mkdir(parents=True, exist_ok=True)
    (run_dir / "results.jsonl").write_text("", encoding="utf-8")
    (run_dir / "run.json").write_text(json.dumps(
        {"model": "historical", "effort": "", "label": a.label, "reps": 1}), encoding="utf-8")
    n = 0
    for case in read_jsonl(a.cases):
        src = Path(case.get("findings_src", ""))
        if not src.is_file():
            continue
        dst = run_dir / "findings" / f"{case['case_id']}_rep0.json"
        shutil.copyfile(src, dst)
        append_jsonl(run_dir / "results.jsonl", {
            "case_id": case["case_id"], "rep": 0, "requested_model": "historical", "effort": "",
            "served_model": None, "served_verified": None, "status": findings_status(dst),
            "findings_path": str(dst.relative_to(run_dir)), "usage": {}, "api_cost_usd": None,
            "latency_s": None, "retries": 0})
        n += 1
    print(f"imported {n} historical outputs into {run_dir}")
    return 0 if n else 2


if __name__ == "__main__":
    sys.exit(main())
````

Create `bench/tests/test_pipeline.py`. It pins the whole chain (sample, run, grade, report, historical import) against the fake CLI, including a miniature of the 2026-09-28 failure (a candidate that abstains and reports "only session header read" must fail on depth). It passes on the first run because it only combines modules that already exist; if it fails, an earlier task's contract has drifted.

````python
"""sample -> run -> grade -> report, end to end, against the fake claude."""
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import grade_l1  # noqa: E402
import import_historical  # noqa: E402
import report  # noqa: E402
import runner  # noqa: E402
import sample_cases  # noqa: E402
from common import load_config, session_hash  # noqa: E402

FAKE = str(Path(__file__).resolve().parent / "fake_claude.sh")


def make_findings_tree(root, sessions, n):
    for i in range(n):
        sp = sessions / f"s{i}.jsonl"
        sp.write_text('{"type":"user","message":{"content":"hello"}}\n')
        h = session_hash(str(sp))
        day = root / "2026-09-01"
        day.mkdir(parents=True, exist_ok=True)
        (day / f"{h}.json").write_text(json.dumps({
            "session_path": str(sp), "project": f"-p{i % 3}", "outcome": "fully_achieved",
            "underlying_goal": None, "findings": []}))
        (day / f"{h}.stats.json").write_text("{}")  # no authoritative keys: nothing to copy


class Pipeline(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        base = Path(self.tmp.name)
        self.findings, self.sessions = base / "findings", base / "sessions"
        self.sessions.mkdir()
        make_findings_tree(self.findings, self.sessions, 6)
        self.data, self.runs = base / "data", base / "runs"
        self.assertEqual(sample_cases.main(["--n", "6", "--findings-root", str(self.findings),
                                            "--out", str(self.data), "--slim-script", "/nonexistent"]), 0)
        self.cfg = load_config()

    def tearDown(self):
        self.tmp.cleanup()

    def candidate(self, label, mode):
        argv = ["--model", "claude-haiku-4-5", "--label", label, "--cases", str(self.data / "cases.jsonl"),
                "--out", str(self.runs), "--claude-bin", FAKE, "--confirm", "--backoff-base", "0"]
        with mock.patch.dict(os.environ, {"FAKE_MODE": mode}):
            self.assertEqual(runner.main(argv), 0)
        return grade_l1.grade_run(self.runs / label, self.data / "cases.jsonl", self.cfg)

    def test_a_good_candidate_passes_the_gate(self):
        s = self.candidate("good", "good")
        self.assertEqual(s["rows"], 6)
        self.assertTrue(s["metrics"]["gate"]["pass"], s["metrics"]["gate"])
        self.assertEqual(s["metrics"]["abstain_excess"]["k"], 0)
        self.assertEqual(s["metrics"]["abstain_excess"]["n"], 6)

    def test_a_header_only_abstaining_candidate_fails_on_depth(self):
        s = self.candidate("shallow", "unclear")
        self.assertEqual(s["metrics"]["gate"]["failed"], ["abstain_excess"])
        self.assertEqual(s["metrics"]["abstain_excess"]["rate"], 1.0)
        self.assertEqual(s["metrics"]["header_only"]["rate"], 1.0)

    def test_an_empty_candidate_fails_on_validity(self):
        s = self.candidate("empty", "nooutput")
        self.assertIn("validity", s["metrics"]["gate"]["failed"])

    def test_report_lists_every_graded_run(self):
        for label, mode in (("good", "good"), ("shallow", "unclear")):
            self.candidate(label, mode)
        out = Path(self.tmp.name) / "report.md"
        self.assertEqual(report.main(["--runs", str(self.runs / "good"), str(self.runs / "shallow"),
                                      "--out", str(out)]), 0)
        md = out.read_text()
        self.assertLess(md.index("good"), md.index("shallow"))
        self.assertIn("FAIL: abstain_excess", md)

    def test_historical_import_creates_a_gradable_run_without_model_calls(self):
        self.assertEqual(import_historical.main(["--cases", str(self.data / "cases.jsonl"),
                                                 "--out", str(self.runs)]), 0)
        run = self.runs / "historical"
        rows = [json.loads(l) for l in (run / "results.jsonl").read_text().splitlines()]
        self.assertEqual(len(rows), 6)
        self.assertEqual({r["status"] for r in rows}, {"ok"})
        s = grade_l1.grade_run(run, self.data / "cases.jsonl", self.cfg)
        self.assertEqual(s["rows"], 6)
        self.assertEqual(s["metrics"]["abstain_excess"]["k"], 0)

    def test_historical_import_with_no_sources_reports_failure(self):
        cases = self.data / "empty.jsonl"
        cases.write_text(json.dumps({"case_id": "x", "findings_src": "/nonexistent"}) + "\n")
        self.assertEqual(import_historical.main(["--cases", str(cases), "--out", str(self.runs)]), 2)

    def test_grade_writes_graded_rows_and_summary(self):
        self.candidate("good", "good")
        rows = [json.loads(l) for l in (self.runs / "good" / "graded.jsonl").read_text().splitlines()]
        self.assertEqual(len(rows), 6)
        self.assertTrue((self.runs / "good" / "summary.json").is_file())
        self.assertEqual(grade_l1.main(["--run", str(self.runs / "good"),
                                        "--cases", str(self.data / "cases.jsonl")]), 0)


if __name__ == "__main__":
    unittest.main()
````

```bash
python3 -m unittest discover -s bench/tests 2>&1 | tail -4
```

Expected: `Ran 86 tests`, `OK`.

- [ ] **Step 6: Calibrate on the real corpus (free, no model calls)**

This grades what production Haiku already produced for 60 real sessions. It validates the grader on real data before any subscription usage is spent.

```bash
python3 bench/sample_cases.py --n 60 --seed 7
python3 bench/import_historical.py
python3 bench/grade_l1.py --run bench/data/runs/historical
python3 bench/report.py
sed -n 3,5p bench/data/report.md
```

Expected when this plan was written (the corpus grows, so expect about these numbers): `historical: 60 rows, gate PASS`, and the table row `historical | PASS | 60 | 100% (94-100, n=60) | 97% (89-99, n=60) | 5% (1-24, n=20) | 0% (0-16, n=20) | 0% (0-7, n=53) | 0% (0-6, n=60)`. Validity 100%, authoritative about 97% (two rows copy `models_used` or `tools_used` imperfectly), hallucinated evidence 1 of 20, verbatim 0 of 20, `abstain_excess` 0 by construction. If the gate fails on `validity`, spot-check three rows in `bench/data/runs/historical/graded.jsonl` before trusting anything: that would be a grader bug, not a Haiku problem.

- [ ] **Step 7: Run the bench unit tests as part of the repo suite**

```bash
python3 - <<'EOF'
from pathlib import Path
p = Path("tests/run-all.sh")
t = p.read_text()
anchor = "\n# Cross-repo drift, last."
assert t.count(anchor) == 1
block = '''
echo
echo "# bench: model benchmark unit tests"
if python3 -m unittest discover -s "$REPO/bench/tests" >/dev/null 2>&1; then
  ok "bench unit tests pass"
else
  no "bench unit tests failed (run: python3 -m unittest discover -s bench/tests)"
fi
'''
p.write_text(t.replace(anchor, block + anchor))
EOF
bash -n tests/run-all.sh && bash tests/run-all.sh 2>&1 | tail -3
```

Expected: `passed: 688   failed: 0`.

- [ ] **Step 8: Write the docs**

Create `bench/README.md`:

````markdown
# bench/ — model benchmark for autodream (Phase 1: L1 objective checks)

Measures which model and effort level works best as the **L1** per-session triage worker,
before you change `AUTODREAM_L1_MODEL` / `AUTODREAM_L1_EFFORT`. Spec:
`docs/superpowers/specs/2026-09-28-model-benchmark-design.md`. Stdlib Python 3 only.

Runs go through the `claude` CLI on your subscription (no API key) and count against its
usage cap. They call the same `bin/l1-invoke.sh` that `bin/run.sh` uses.

## Commands (from the repo root)

```bash
python3 bench/sample_cases.py --n 60 --seed 7          # pick + freeze the case set
python3 bench/import_historical.py                     # grade what production already produced (free)
python3 bench/runner.py --model claude-haiku-4-5 --dry-run       # print the plan, no calls
python3 bench/runner.py --model claude-sonnet-5-5 --effort medium --confirm
python3 bench/grade_l1.py --run bench/data/runs/claude-sonnet-5-5@medium
python3 bench/report.py                                # bench/data/report.md
python3 -m unittest discover -s bench/tests            # unit tests
```

`runner.py` resumes: re-running the same command skips finished (case, rep) pairs.

## What is measured

Per candidate, separate columns and no blended score:

| check | meaning | gate (config.json) |
|---|---|---|
| validity | valid JSON, legal enums, caps, no retired category, zeroed satisfaction_signals | >= 98% |
| authoritative | fields the prompt says to copy equal the stats sidecar | >= 95% of valid rows |
| hallucinated evidence | findings whose evidence has checkable fragments, most absent from the transcript | <= 10% of findings |
| abstain_excess | says `unclear_from_transcript` where historical Haiku decided an outcome | <= 10% |
| header-only, verbatim | informational | none |

Ranking happens only among gate-passers. In Phase 1 the historical Haiku output is the
stand-in reference, so a Haiku candidate scores 0 on `abstain_excess` by construction.

## Data

`bench/data/` is gitignored and holds frozen session content: never commit it.

```
bench/data/cases.jsonl        the frozen case set
bench/data/inputs/            slimmed transcripts + stats sidecars, byte-identical for every candidate
bench/data/runs/<label>/      results.jsonl, errors.jsonl, findings/, cli/, graded.jsonl, summary.json
bench/data/report.md
```
````

Add to `AGENTS.md`, after the Layer 2 line in the architecture section:

```
- **Model benchmark** (`bench/`, see `bench/README.md`): measures candidate L1 models and efforts against the frozen case set before `AUTODREAM_L1_MODEL` or `AUTODREAM_L1_EFFORT` is changed. `bin/l1-invoke.sh` is the L1 call shared by `run.sh` and the benchmark.
```

Add to `CHANGELOG.md` under `### Changed` in the `[Unreleased]` section:

```
- **Model benchmark, Phase 1 (`bench/`).** Stratified frozen case set, a resumable runner on the production L1 invocation (subscription CLI, served-model check, timeout and rate-limit handling), an objective grader (validity, authoritative fields, tiered evidence grounding, depth as `abstain_excess`) with an eligibility gate, a historical-output importer for free calibration, and a markdown report. Spec: `docs/superpowers/specs/2026-09-28-model-benchmark-design.md`.
```

Add to `README.md`, directly after the paragraph that begins "Two layers:":

```
To compare models for L1 before changing `AUTODREAM_L1_MODEL`, see [`bench/README.md`](bench/README.md).
```

- [ ] **Step 9: Commit**

```bash
git add bench/report.py bench/import_historical.py bench/tests/test_report.py bench/tests/test_pipeline.py bench/README.md tests/run-all.sh README.md AGENTS.md CHANGELOG.md
git commit -m "feat(bench): report, historical baseline import, suite wiring, docs"
```

---

### Task 7: Phase 1 acceptance run (uses the subscription; ask first)

**Files:**
- Create: `docs/benchmarks/2026-09-28-l1-phase1.md` (aggregate numbers only)

**Interfaces:**
- Consumes: everything above.
- Acceptance criteria from the spec: Sonnet 5.5 at `low` and at `medium` **fail the gate on `abstain_excess`** (the 2026-09-28 runs returned `unclear_from_transcript` for 18 of 20 non-gated sessions, against a 10% ceiling); the historical Haiku baseline passes.

- [ ] **Step 1: Everything is green before spending anything**

```bash
bash tests/run-all.sh 2>&1 | tail -2
python3 -m unittest discover -s bench/tests 2>&1 | tail -2
```

Expected: `passed: 688   failed: 0` and `OK`.

- [ ] **Step 2: Freeze the real case set and import the baseline**

```bash
python3 bench/sample_cases.py --n 60 --seed 7
python3 bench/import_historical.py
```

Expected: `... froze 60 into .../bench/data/cases.jsonl (57 slimmed)` (about) and `imported 60 historical outputs into .../runs/historical`.

- [ ] **Step 3: Show the plan for each candidate (zero calls)**

```bash
python3 bench/runner.py --model claude-haiku-4-5 --dry-run
python3 bench/runner.py --model claude-sonnet-5-5 --effort low --dry-run
python3 bench/runner.py --model claude-sonnet-5-5 --effort medium --dry-run
```

Expected for each: `plan: <model> effort=<...> | 60 cases x 1 reps = 60 calls, 60 to run (0 already done) | concurrency 2, timeout 900s`.

- [ ] **Step 4: Consent gate**

Tell the user: "Next I will make 60 L1 calls for each of three candidates (Haiku 4.5, Sonnet 5.5 at low, Sonnet 5.5 at medium), 180 calls at concurrency 2, on your subscription. They count against its usage cap and can take a while; the runner resumes if interrupted. Run them?" **Wait for an explicit yes.** Do not run Step 5 on silence.

- [ ] **Step 5: Run the candidates**

```bash
python3 bench/runner.py --model claude-haiku-4-5 --confirm
python3 bench/runner.py --model claude-sonnet-5-5 --effort low --confirm
python3 bench/runner.py --model claude-sonnet-5-5 --effort medium --confirm
```

Run each in the background and poll `wc -l bench/data/runs/*/results.jsonl` for progress. If a run stops (usage cap, crash), re-run the same command: it skips finished pairs. Each ends with `done: N result rows, M error rows in ...`. A non-zero error count is data: check `bench/data/runs/<label>/errors.jsonl` for the failure classes before grading.

- [ ] **Step 6: Grade and report**

```bash
for r in bench/data/runs/*/; do python3 bench/grade_l1.py --run "${r%/}"; done
python3 bench/report.py
cat bench/data/report.md
```

Expected: `historical` and `claude-haiku-4-5@default` PASS. `claude-sonnet-5-5@low` and `claude-sonnet-5-5@medium` show `FAIL: abstain_excess` with an `abstain_excess` rate far above 10% (about 90% in the 2026-09-28 runs).

- [ ] **Step 7: Verify before claiming**

If Sonnet does not fail as expected, or Haiku fails, do not report success. Spot-check three rows of the failing candidate in `bench/data/runs/<label>/graded.jsonl` and its `findings/` files by hand, and check `errors.jsonl` and the `unverified model` column. Say what you found either way.

- [ ] **Step 8: Save the aggregate result**

The report holds only labels and rates, no session content. Check that, then keep it:

```bash
grep -c "/Users/" bench/data/report.md   # expect 0
mkdir -p docs/benchmarks
cp bench/data/report.md docs/benchmarks/2026-09-28-l1-phase1.md
git add docs/benchmarks/2026-09-28-l1-phase1.md
git commit -m "docs(bench): Phase 1 L1 benchmark results"
```

- [ ] **Step 9: Final check**

```bash
bash tests/run-all.sh 2>&1 | tail -2
git status --short
```

Expected: `passed: 688   failed: 0`; the working tree shows no tracked changes (`bench/data/` is ignored).

---

## Self-review

**Spec coverage (Phase 1):** case sampler and frozen inputs (Task 3); shared invocation extraction with `run.sh` unchanged (Task 1); runner with resume, low default concurrency, jittered backoff, hard timeout, failure classes, served-model check, tokens/latency/API-equivalent cost, `--dry-run` and `--confirm` (Task 5); the four objective checks and the gate (Task 4); the report with separate columns and no blended score (Task 6); oracle and null sanity tests, and the copied-findings and induced-CLI-error cases (Tasks 4 and 5); the Sonnet-at-low-and-medium acceptance criterion (Task 7). Not in Phase 1 by design: reference and judge (Phase 2), L2 (Phase 3), codex (Phase 4).

**Known limits:** the case set is 60 sessions from August and September; outcome and finding rates carry wide intervals at that size, and the report shows them. The gate thresholds come from one baseline. Evidence grounding is a heuristic (anchors), so treat a small `hallucinated evidence` rate on slimmed transcripts as noise until Phase 2 adds the judge.
