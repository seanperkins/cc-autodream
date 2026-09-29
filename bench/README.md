# bench/ — model benchmark for autodream (L1)

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
| abstain_excess | says `unclear_from_transcript` where the reference (Phase 2; historical Haiku in Phase 1) decided an outcome | <= 15% |
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

## Phase 2: agreement with a frozen reference

Phase 1's gate needs no reference. Phase 2 adds one: a majority vote of three reference models
(`reference.models` in `config.json`): Opus 5.5 and Fable 5.1 through `claude`, GPT-6 Astra through
`codex`. Each triages every frozen case once; `build_reference.py` turns the three outputs into one
reference row per case:

- **outcome**: the majority value; a three-way (or 1-1) split goes to you.
- **goal**: the first goal another model's goal is judged the same as, else none (not scored).
- **findings and instructions**: clusters of items judged the same pattern (same category first).
  A cluster reported by two or more models is *confirmed*; a single-model item is *unconfirmed*.

```bash
python3 bench/runner.py --model claude-opus-5-5 --effort high --label ref-opus --timeout 1800 --confirm
python3 bench/runner.py --model claude-fable-5-1 --effort high --label ref-fable --timeout 1800 --confirm
python3 bench/runner.py --harness codex --model gpt-6-astra --effort high --label ref-astra --timeout 1800 --confirm
python3 bench/build_reference.py build     # majority vote -> bench/data/reference/reference.jsonl
python3 bench/build_reference.py sheet     # writes bench/data/reference/adjudicate.md
# edit adjudicate.md: rule on each outcome split, mark each spot check OK or BAD
python3 bench/build_reference.py apply
python3 bench/grade_ref.py --run bench/data/runs/<label>
python3 bench/report.py
```

`grade_ref.py` re-grades a run with the reference as the depth baseline (`abstain_excess` no longer
uses the historical Haiku stand-in) and adds outcome agreement and distance, goal agreement, and
finding and instruction recall and precision. Precision is reported strict (matches a confirmed
finding) and lenient (also matches an unconfirmed one).

The judge (`judge.py`) only compares wording: goal, instruction and finding pairs as same, partial or
different. It is blind (prompts never name a model), never the candidate under test (Fable, or Opus
when the candidate is Fable), schema-validated, and cached in `bench/data/reference/judge-cache.jsonl`
so reruns are free. A failed call is counted as `unjudged` and never guessed.

The codex harness (`run-one-l1-codex.sh`) sends the same L1 prompt plus the worker instructions
production gives `claude` through `--append-system-prompt`, and one added sentence: a slimmed
transcript has lines cut off mid-JSON, which are plain text, never an error. Without it GPT-6 Astra
ran a strict JSON parser over the slimmed transcript and returned the prompt's own error object for
every real case tried (6 of 6); with it 4 of 4 were valid. Codex reports no served model, so its rows
are marked unverified.
