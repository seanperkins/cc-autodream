# Model benchmark for autodream L1 and L2 — design

Status: draft for review, 2026-09-28. Not yet planned or implemented.

## Purpose

Autodream runs two model roles: **L1** (one triage worker per session, writes a findings JSON) and **L2** (one aggregator per night, writes the report and `memory-candidates.json`). Today the model for each role is chosen by hand. On 2026-09-28, moving L1 from Haiku 4.5 to Sonnet 5.5 at `--effort low` and then `medium` returned `outcome: unclear_from_transcript` for 18 of 21 sessions and no findings, and nothing caught it until the L2 report warned about it.

This design adds a repeatable benchmark so a candidate model (and effort level) can be measured in either role before it is adopted. It reports quality, latency, and token use as separate numbers and never blends them into one score.

Success criteria:

- Given a candidate model and effort, it produces a per-role report the user can read to decide adopt / reject.
- The 2026-09-28 failure is caught: Sonnet 5.5 at `low` and `medium` must fail the L1 depth check when run through Phase 1.
- Re-running with a new model is one command and does not touch the production runner's behavior.

## Decisions taken with the user

1. "Best" for L1 = quality against a frozen reference, with cost and latency reported alongside. Not cheapest-first and not judged only through the final report.
2. The reference is a 3-lineage majority: Opus 5.5 and Fable 5.1 (via `claude`) plus GPT-6 Astra (via `codex`), all at high effort, run once and frozen. Where at least two agree, that is the reference. The user rules only on three-way splits and about 15 random spot-checks.
3. The case set is about 60 sessions, stratified. The user can raise it later.
4. Money is not a constraint: the user runs on a Claude/Codex subscription. Real limits are usage caps and rate limits, so the runner must throttle, back off, and resume. Dollar figures are an API-equivalent estimate shown for information only.
5. Runs go through the `claude --print` and `codex exec` CLIs, not the API, so they use the subscription and exercise the same call path as production.
6. Benchmark L1 and L2 as two separate evals (one flow per eval). L2 consumes frozen L1 output. A secondary end-to-end smoke check (Phase 3) feeds a candidate L1's real output into the current production L2, to catch output shapes that break aggregation.
7. Applying a winner stays manual: the benchmark recommends, the user sets the model.

## Non-goals

- Automatically changing production models.
- Blending quality, cost, and latency into one number.
- Benchmarking the other L1 consumers (`promote.sh`, `review.sh`).
- Comparing prompt or tool-schema variants. The benchmark varies model, effort, and harness only, with the production prompt held fixed.
- Committing session content to git.

## Architecture

A `bench/` directory in `cc-autodream`, run through the CLIs.

```
bench/
  sample-cases.sh        pick ~60 sessions, freeze slimmed copies + stats sidecars
  build-reference.sh     run the 3 reference models once, majority-vote, write adjudication sheet
  run-l1.sh              one candidate (model, effort, harness) over all cases
  grade-l1.py            objective checks + judge calls -> results.jsonl
  run-l2.sh              one candidate over the frozen day fixtures
  grade-l2.py            objective checks + rubric judge -> results.jsonl
  report.sh              build report.html from results (skill's lite report builder)
  lib/l1-invoke.sh       the L1 command line, shared with bin/run.sh
  data/                  gitignored: frozen transcripts, fixtures, reference, results
```

**Shared invocation.** The `claude --print ... --append-system-prompt ...` L1 command in `bin/run.sh` is extracted into `lib/l1-invoke.sh`, a claude-harness-only function taking `model`, `effort`, `output-format`, a prompt file, and an output path. `run.sh` calls it with production defaults (`--output-format` unset, stdout discarded); `run-l1.sh` calls it with `--output-format json`. The benchmark therefore measures the production call, and the two cannot drift. The same is done for the L2 command. Extraction must leave `run.sh` behavior unchanged, verified by the existing test suite (679 checks).

**One adapter per harness, no branching in the shared file.** Other harnesses (Phase 4: `codex exec`) get their own adapter implementing the same contract (prompt file and output path in, findings file out) and are called only by the benchmark. `lib/l1-invoke.sh` never grows benchmark-specific branches, and production never calls another harness's adapter.

**Frozen inputs.** Only about 464 of the 5,120 historical session transcripts still exist on disk (395 from September, 69 from August), and Claude Code may prune them. `sample-cases.sh` copies the exact slimmed transcript and stats sidecar for each chosen session into `bench/data/`, so every candidate reads identical bytes and the corpus survives pruning. These files contain session content and may contain secrets: `bench/data/` is gitignored, never committed, and never sent anywhere except to the models being benchmarked. 377 of the 464 surviving sessions exceed the slim threshold (262,144 bytes), so slimming is the normal path.

**Case sampling.** Stratified by project, size bucket, and the Haiku historical outcome, with at least some sessions that had findings, some that were gated as trivial, and some subagent sessions. The chosen ids and strata are written to `cases.jsonl`.

**Runner behavior (both roles).**

- One row written per (case, model, effort, rep) as it finishes; resume is idempotent on that key.
- Concurrency defaults low (2) and backs off with jitter on rate-limit or usage-cap errors, recording the retry count.
- Hard per-case wall-clock ceiling; a timeout is recorded as a timeout, not a zero.
- Every failed attempt gets a failure class: refusal, harness/serving error, timeout, or genuine failure. Failed attempts go to `errors.jsonl` and never occupy a result slot.
- **Served model.** Production discards L1 stdout and the worker prints only `done`, so it carries no model information. The benchmark invokes with `--output-format json` and reads the served model from the CLI's usage metadata (expected: the `modelUsage` keys of the result object). Phase 1's first task is to confirm the field exists for every candidate. A served model that differs from the requested one fails the attempt. If the CLI exposes no served-model field, rows are marked `served_model: unverified` and the report says so, because the L2 prompt itself warns that the CLI can silently fall back on an unrecognized model string.
- Records tokens, wall-clock time, and an API-equivalent dollar estimate. Latency and tokens are absolute numbers first, relative changes second.
- `--dry-run` prints models × cases × reps and makes zero calls. A real run requires an explicit confirm flag.

## L1 grading

Objective checks need no reference and no judge:

1. **Validity.** Valid JSON at the requested path, all enum values legal, findings capped at 10, no retired category (`assumption_unsurfaced`), `satisfaction_signals` all zero, no `error` object.
2. **Authoritative fields.** `turn_count`, `tool_call_count`, `tools_used`, `skills_invoked`, `models_used`, and `compliance_markers` must equal the stats sidecar exactly, because the L1 prompt says to copy them.
3. **Evidence grounding.** Each finding's `evidence_excerpt` must fuzzy-match text in the frozen transcript. Reported as a hallucinated-evidence rate.
4. **Depth.** Count of sessions where the candidate says `unclear_from_transcript` but the reference decided an outcome, plus header-only phrases in `notable_initiatives` ("only session header read", "not reviewed"). In Phase 1, before the reference exists, Haiku's historical outcome for the same session stands in for it. Definition: `abstain_excess` = sessions where the candidate says `unclear_from_transcript` and the reference (or historical stand-in) decided an outcome, divided by sessions where the reference decided an outcome. Gated sessions (the runner writes a `skipped: below_noise_gate` stub with no outcome), sessions with no historical outcome, and error rows are excluded from the denominator; the report shows the denominator next to the rate.

Reference-based checks, with a judge only where wording legitimately varies:

- **Outcome:** exact match, plus distance on the ordered scale `fully_achieved` → `mostly_achieved` → `partially_achieved` → `not_achieved`; `unclear_from_transcript` is scored separately.
- **`underlying_goal` and `instructions_given`:** judge rates same / partial / different.
- **Findings:** precision and recall against the reference findings. Category match first, programmatically; then a judge decides whether two findings with the same category describe the same pattern.
- **Judge:** Fable 5.1, or Opus 5.5 when the candidate is Fable. Blind to which model wrote the output. Candidate and reference text are treated as untrusted data. The judge may answer `tie` or `both_bad`. Output is a JSON schema, not free text.

**Reporting.** Per (model, effort): each check above, latency p50 and p95, tokens, and API-equivalent cost. A gate decides eligibility, and ranking is only among gate-passers: validity at least 98%, authoritative fields exact on 100% of valid rows, hallucinated-evidence rate at most 2%, and `abstain_excess` at most 10%. The thresholds are starting values, set in the config file and adjustable after the first run. With about 60 cases, outcome agreement has roughly ±10 points of noise; differences smaller than the interval are shown as ties, with a Wilson interval on every rate.

**Sanity tests the eval must pass before any number is trusted.** The reference, scored as a candidate against itself, scores about 100%. An empty output scores about 0% and fails the gate. A candidate whose output is valid JSON that copies another session's findings fails grounding. An induced CLI error lands as an error row, not a zero.

## L2 grading

**Fixtures.** About 6 frozen day fixtures. `prompts/PROMPT.md` tells L2 to read more than the findings: the per-session findings and stderr, installed skills (for validating `missed_skill` findings), the global rules (`CLAUDE.md`, `rules/*.md`, `docs/guardrails/*.md`), the installed hooks (`~/.claude/hooks/*.sh` and the `hooks` block of `~/.claude/settings.json`), the three most recent reports' `## Triage decisions`, the upstream changelog check output, operator notes (`operator-notes.md` and the `~/.claude/autodream/notes.md` source it is merged from), and bookmark inputs. Each fixture therefore contains a frozen copy of every input the prompt can read: the reference L1 findings and stderr, `run-stats.txt`, a skills manifest (name and description frontmatter), snapshots of the rules files, snapshots of the hook scripts and the `hooks` block, three prior reports, the changelog output, `operator-notes.md` and `notes.md`, and bookmark files. Where an input is legitimately absent for that day (for example `operator-notes.md`, whose absence makes the prompt fall back to `notes.md`), the fixture keeps it missing: the substituted path points at a path that does not exist inside the fixture. An empty file is used only where presence and emptiness mean the same thing to the prompt, never for an input the prompt reads "if present" or uses as a fallback trigger. Chosen for shape: a heavy day with findings; a quiet day; a day with a failed night in `unassembled_dates`; a day with settled decisions that must not be re-asked; a day with a planted known issue (for example sibling subagents inflating `overlap-stats.sh` counts); and a degraded-input day built from the 2026-09-28 Sonnet-low L1 output, to test whether L2 warns that triage looks shallow.

**Fixture-only reads.** The benchmark builds each L2 prompt with the live paths substituted by fixture paths, and runs L2 with `--output-format stream-json` so every tool call is recorded. A `Read`, `Glob`, or `Write` outside the fixture directory is a violation: the attempt is flagged and excluded from scoring, so reruns depend on the fixture and not on current machine state.

**Objective checks.**

- All mandated sections present and in order.
- The report ends with its final section, `## Memory candidates` (with its `None.` or numbered items). This is the benchmark's own completeness test. It does not rely on the runner's `report_complete()` (see Risks).
- `<!-- autodream:open-questions=N -->` equals the number of listed numbered questions, each with a bold lead-in.
- Activity-snapshot numbers (session count, turns, tool calls, projects, outcome counts, skills) equal values computed from the fixture.
- `memory-candidates.json` parses and every candidate cites a session id present in the fixture.
- Fraction of runs that produced a complete report (by the benchmark's own test above) on attempt 1 of 3.

**Judged, with concrete rubric claims, and pairwise against a frozen Opus 5.5 reference report:**

- Surfaced the planted issue in that fixture.
- Every ranked pattern traces to a real L1 finding (no invented patterns).
- Did not re-ask a question the fixture's triage decisions already settled.
- Every open question clears the triviality gate.
- On the degraded-input fixture, said that L1 triage looked shallow instead of reporting a clean day.

**Noise.** 6 fixtures × 3 reps is small. The report states which differences are within noise. Fixtures can be added over time.

## Testing the benchmark

- Unit tests for each grader using oracle and null inputs.
- Integration test using the same mock-`claude` approach as `tests/run-all.sh`, covering resume after a crash, rate-limit backoff, timeout classification, and served-model mismatch.
- The extraction of the shared invocation is covered by the existing 679-check suite staying green.

## Build order

1. **Phase 1 — L1 objective benchmark.** Sampler, frozen inputs, shared invocation extraction, `run-l1.sh`, the four objective checks, the report. Compares candidates on validity, fidelity, grounding, and depth against Haiku's historical output. Acceptance: Sonnet 5.5 at `low` and `medium` fail the gate on `abstain_excess` (the 2026-09-28 runs returned `unclear_from_transcript` for 18 of 20 non-gated sessions, against a 10% ceiling). Because Haiku is its own Phase 1 stand-in, its `abstain_excess` is 0 by construction; the report notes that, and Phase 2 replaces the stand-in.
2. **Phase 2 — reference and judge.** `build-reference.sh` with adjudication sheet, reference-based checks, judge.
3. **Phase 3 — L2.** Fixtures, `run-l2.sh`, `grade-l2.py`. Plus `run-e2e.sh`, a smoke check: take a candidate L1's actual findings for a fixture day, run the current production L2 on them, and apply the L2 objective checks and the degraded-input check. It answers whether a candidate's output shape breaks aggregation; it is not a ranking.
4. **Phase 4 — codex candidates.** `codex exec` adapter for GPT-6 Luna/Sol/Astra as L1/L2 candidates. Risk: L1 needs file Read/Write tools, so this starts as a spike that checks whether Codex can follow the L1 contract at all.

Initial candidate matrix (config file, not hard-coded): Haiku 4.5; Sonnet 5.5 at low/medium/high; Opus 5.5 at low/medium/high; Fable 5.1 at high; GPT-6 Luna/Sol/Astra once Phase 4 exists.

## Risks and open items

- The reference is a consensus, not ground truth. The spot-checks measure how far it can be trusted.
- The judge is a model. Graded examples are shown to the user before the judge is trusted, and the judge never grades its own output.
- Subscription usage caps may throttle large runs. The runner resumes, so a capped run can be continued later.
- The set is 60 sessions from August–September only; it may underrepresent other kinds of session.
- **Production completeness check is weaker than its comment says.** `report_complete()` (`bin/run.sh:1106`) accepts any report containing `autodream:open-questions=`. `PROMPT.md` places that marker at the end of the Open questions section and then requires a `## Memory candidates` section after it, so a report truncated after the marker passes. Found in design review. Out of scope for the benchmark, but it should be fixed separately: add a true terminal marker to `PROMPT.md` and check it in `report_complete()`.
- The production `bin/run.sh` currently carries an uncommitted L1 setting (`--effort medium`) from the 2026-09-28 experiment, and the pushed commit `59f2eb8` has `--effort low`. That is separate from this work and should be resolved first.
