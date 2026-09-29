# bench/ — model benchmark for autodream (Phase 1: L1 objective checks)

Measures which model and effort level works best as the **L1** per-session triage worker,
before you change `AUTODREAM_L1_MODEL` / `AUTODREAM_L1_EFFORT`. Spec:
`docs/superpowers/specs/2026-09-28-model-benchmark-design.md`. Stdlib Python 3 only.

Runs go through the `claude` CLI on your subscription (no API key) and count against its
usage cap. They build the call from the claude adapter's `l1-argv` (`bench/l1-prod.sh`), the same command `bin/run.sh` starts for a nightly worker.

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
