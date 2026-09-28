# Codemap — architecture

Token-lean map of cc-autodream. See `AGENTS.md` for the decisions and gotchas behind it.

## Data flow

```
launchd (com.samuelreed.autodream, several morning triggers)
      │
      ▼
bin/run.sh  TARGET_DATE
      │
      ├─ idempotency guard: report exists for date? → exit 0 (unless AUTODREAM_FORCE=1)
      │
      ├─ probe_roots: resolve SESSION_ROOTS (env/config | PROJECTS_DIR | root-probe autodetect)
      │     └─ write findings/<date>/unindexed-roots.txt (folders found but not indexed; before guard)
      ├─ preflight.sh: hard-dep gate (jq, shasum, realpath, find, the L2 engine) — fatal before any scan
      ├─ adapters.sh: load adapters/<name>/ (manifest.json validated, basename = identity, realpath-contained)
      │     └─ refusals recorded to a FILE (adapters_rejected); accepting none is fatal
      ├─ enumerate: adapter_run <name> enumerate <root> <date> <next> → NUL-delimited paths
      │     │   (claude adapter = find *.jsonl in [TARGET_DATE, NEXT_DATE); inline fallback if the
      │     │    installed adapters/ link is stale — claude only, never a second adapter's roots)
      │     ├─ sessions.txt.raw (bare paths, sort -u) + sessions.txt.src (<adapter>\t<path>)
      │     └─ prune-self-sessions.sh --filter                → sessions.txt   (drops autodream's own)
      │
      ├─ L1 retry loop (AUTODREAM_L1_ROUNDS):
      │     dispatch_l1: xargs -P FANOUT → claude --print (claude-sonnet-5-5, low effort, lean flags) per session
      │       reads session .jsonl, writes findings/<date>/<sha>.json   (idempotent; .err on fail)
      │     l1_missing_count → wait_for_network → retry the still-missing
      │
      ├─ run-stats.txt          (self-audit telemetry)
      ├─ changelog_window()      → findings/<date>/changelog-window.md  (git log -p on claude-code CHANGELOG)
      │
      ├─ L2 retry loop (AUTODREAM_L2_ATTEMPTS):
      │     claude --print (claude-opus-5-5 or AUTODREAM_L2_MODEL, lean flags) with PROMPT.md
      │       reads per-session findings + changelog-window.md + run-stats.txt
      │       writes memory-candidates.json first, then dreams/<date>.md (proposals only)
      │
      ├─ no memory application: the human later runs bin/promote.sh for approved candidates
      ├─ notify.sh → open-questions inbox file ($AUTODREAM_OPEN, default `open`)
      └─ question-streaks.sh update → question-streaks.tsv
            at AUTODREAM_QUESTION_ESCALATE_AT consecutive reports: a second banner
            + findings/<date>/question-escalations.txt
            (also called on the early no-sessions path, so a question-free night clears streaks)
```

## Files

| File | Role |
|---|---|
| `bin/run.sh` | orchestrator: guard, preflight, adapter load, enumerate+filter, L1 retry loop, changelog, L2 retry loop, notify. Never reads/writes memory. Every fatal goes through `log_fatal`/`fatal_exit` (marker + banner) |
| `adapters/<name>/` | one harness. `manifest.json` (DATA — jq-parsed, never sourced) + `adapter.sh` + `facts.md`. Subcommands: `enumerate normalize project memory-root stats slim is-self skills-inventory` (`memory-root` is unused since pins moved to Mnemopi); contract table in `docs/design/unify-harness-adapters-2026-08-23.md`. `_fixture` is test-only (leading `_` excludes it) |
| `bin/adapters.sh` | adapter discovery + dispatch. Identity is the DIRECTORY BASENAME (dispatch builds a path from it), must agree with `manifest.name`; realpath containment; refusals go to a file because `adapters_list` runs inside `$(...)` |
| `bin/lib-project.sh` | the canonical project key every adapter must agree on: `encode_project` (everything outside `[A-Za-z0-9-]` → `-`), `canonical_project` (realpath first), `session_hash` (12 lowercase hex, validated) |
| `bin/preflight.sh` | shared-dependency gate, run before anything is enumerated. Fatal on a missing hard dep rather than a quiet empty night |
| `bin/autodream-now.sh` | run NOW via a transient one-shot launchd agent (escapes the ~10-min cap on bg tasks/ssh). `[DATE] [--force] [--watch] [--dry-run]`. RunAtLoad only (no kickstart → no double run); picks the scheduled plist that runs `run.sh` for its label namespace |
| `bin/prune-self-sessions.sh` | self-session predicate (single source of truth): list / `--delete` / `--filter` |
| `bin/oversized-gate.sh` | recompute the #12 measurement gate over a trailing window from the sidecars/findings on disk (`--days N`, or explicit findings dirs). Recovers dates whose `run-stats.txt` predates the counters; artifacts only, no model calls |
| `bin/question-streaks.sh` | counts how many consecutive reports asked each open question, keyed by its bold title, and escalates stale ones with a second banner. `update <report> [findings-dir]` / `status` / `clear all\|<key>`. State in `$AUTODREAM_DIR/question-streaks.tsv`. Listed in `shared-with-sibling.txt`: identical to omp-autodream's copy |
| `bin/check-shared-drift.sh` | compares the files listed in `shared-with-sibling.txt` against the sibling omp-autodream checkout, full-line comments stripped. Run last by `tests/run-all.sh`; prints SKIPPED and exits 0 when it finds no sibling (CI) |
| `shared-with-sibling.txt` | the helpers meant to stay identical in both repos |
| `bin/root-probe.sh` | detect the `~/.claude*/projects` buckets and decide which to index. `--consolidated`/`--unindexed`/`--list` (read-only, nightly), `--ask`/`--default-index` (install-time; writes root-choices.conf + the managed `SESSION_ROOTS` config section). Artifacts only, no model calls |
| `bin/notify.sh` | extract "Open questions" → inbox file, counted from the `open-questions=N` marker, opened via `$AUTODREAM_OPEN` |
| `bin/review.sh` | interactive morning triage (`claude --append-system-prompt <report>`); `AUTODREAM_TRIAGE_SURFACE=cmux` (config/env) launches it in its own cmux workspace instead of inline. Skips the session entirely (prints a notice) when the report has 0 open questions or is already triaged — reads the `<!-- autodream:open-questions=N -->` marker, falls back to prose, launches on anything ambiguous; `--force` overrides. Skip check runs before the cmux branch so a skip never spawns a workspace |
| `bin/promote.sh` | manual approved promotion from `memory-candidates.json` to Mnemopi; resolves the bank from cwd and records accepted entries in `memory-promoted.jsonl`. Never called by the nightly |
| `prompts/SESSION_TRIAGE.md` | L1 prompt: per-session JSON schema |
| `prompts/PROMPT.md` | L2 prompt: report sections incl. Upstream changes + Autodream self-audit, memory rules |
| `tests/run-all.sh` | integration tests for `run.sh` vs `mock-claude.sh` (offline), plus adapter, project, preflight, transcript and manual-promotion unit suites |
| `tests/{lib-project,preflight,adapters,adapter-claude,adapter-contract}.sh` | unit suites: project key, dep gate, adapter loading/containment, the claude adapter, and the contract every adapter must satisfy |
| `tests/review-skip.sh` | tests for `review.sh`'s skip/launch decision (offline; inline mock claude) |
| `tests/mock-claude.sh` | stand-in claude; modes: good / l1_incomplete / l1_flaky |
| `launchd/com.user.autodream.plist.example` | schedule (multi-trigger catch-up + pmset note) |
| `install.sh` | symlink scripts/prompts into `~/.claude/autodream/`; by default also generates + bootstraps the nightly launchd schedule (auto-detected label/PATH/dirs; `--no-schedule` to skip) |

## Key invariants

- L1 worker is **idempotent**: a session with a non-empty `<sha>.json` is skipped. Failures leave no JSON (retry target); deterministic errors (unreadable file) write a JSON (done).
- A `dreams/<date>.md` exists only after a successful L2 → it is the "done" signal for the idempotency guard.
- `prune-self-sessions.sh` matches only the FIRST user turn against autodream's own prompt framing → human sessions about autodream are not false positives.
- **The manifest is data.** JSON, read with jq, never sourced. `$HOME` is substituted, never evaluated.
- **Identity is the directory basename**, never a manifest field, because dispatch builds a command path from it. A basename check is not containment — every adapter dir is realpath-resolved and required to stay under the adapters root.
- **`sessions.txt` stays BARE PATHS.** Provenance lives in the `.src` sidecar. Anything that adds a column to `sessions.txt` breaks every consumer that reads it as a path list.
- A variable assigned inside `$(...)` never reaches the caller. Every cross-boundary signal in this repo (adapter refusals, the broken-log marker, fetch failure reasons) is a FILE for that reason.
- claude is always invoked with the lean flags + subscription auth; never `--bare`/`CLAUDE_CODE_SIMPLE` (breaks auth).
- `question-streaks.tsv` holds the streaks and their watermark in one file: first line `#last<TAB>YYYY-MM-DD`, then one row per streak. Every write is a temp file in the same directory plus one rename. Do not split state that must change together across two files.
- A report without the `<!-- autodream:open-questions=N -->` marker is incomplete, and `question-streaks.sh` refuses to count it.
- Memory candidates (`cwd`, `content`, `kind`, `evidence`) are proposals, not settled decisions. Only prior reports' `## Triage decisions` supply settled context. Archived `MEMORY.md` files are never read or written.

## Environment overrides

All optional; full list (with defaults) is documented in `bin/run.sh`'s header. The ones you reach for most:

| Variable | Default | Purpose |
|---|---|---|
| `CLAUDE_BIN` | `$HOME/.local/bin/claude` | path to `claude` CLI |
| `SESSION_ROOTS` | autodetected | colon-separated dirs to scan for session JSONLs (every `$HOME/.claude*/projects`). Wins over `PROJECTS_DIR` |
| `PROJECTS_DIR` | `$HOME/.claude/projects` | single root, kept for compat (one dir); `WORK_BUCKET` isolation is keyed off this |
| `AUTODREAM_DIR` | `$HOME/.claude/autodream` | scripts + runtime state |
| `DREAMS_DIR` | `$HOME/.claude/dreams` | where reports are written |
| `FANOUT` | `8` | L1 parallelism |
| `AUTODREAM_FORCE` | `0` | `1` rebuilds even if a report exists |
| `AUTODREAM_CHANGELOG` | `1` | `0` skips the upstream-changelog check |
| `CLAUDE_CODE_REPO` / `CHANGELOG_REMOTE` | cache dir / anthropics/claude-code | changelog clone source/cache |
| `AUTODREAM_L1_ROUNDS` / `AUTODREAM_L2_ATTEMPTS` | `5` / `3` | sleep-resilient retry bounds |
| `AUTODREAM_NETCHECK` / `AUTODREAM_RETRY_WAIT` | `1` / `60` | network-wait between retry rounds |
| `AUTODREAM_SLIM_BYTES` | `262144` | sessions larger than this are slimmed for L1 |
| `AUTODREAM_OPEN` | `open` | how `notify.sh` opens the inbox file; a `sh -c` snippet, so flags work (`subl`, `code -g`, `open -a Obsidian`). `SUBL` is a deprecated alias |
| `AUTODREAM_TRIAGE_SURFACE` | `inline` | `review.sh` triage surface: `inline` (current terminal) or `cmux` (own workspace) |
| `AUTODREAM_TRIAGE_FOCUS` | `false` | cmux surface only: `true` switches to the new workspace on launch, `false` opens it in the background |
| `CMUX_BIN` | `/Applications/cmux.app/.../bin/cmux` then PATH | cmux CLI, used when surface is `cmux` |
| `AUTODREAM_CONFIG` | `$AUTODREAM_DIR/config` | sourced KEY=VALUE config (env vars override it) |
| `AUTODREAM_QUESTION_ESCALATE_AT` | `3` | consecutive reports before a repeated open question escalates |
| `AUTODREAM_QUESTION_STATE` | `$AUTODREAM_DIR/question-streaks.tsv` | streak store |

## Lean queries / no self-pollution (see CLAUDE.md for full detail)

- Both layers call `claude --print` with composed lean flags (`--no-session-persistence --disable-slash-commands --strict-mcp-config --settings '{"disableAllHooks":true}'` + `CLAUDE_CODE_DISABLE_CLAUDE_MDS=1` …) — minimal footprint while keeping subscription/OAuth auth.
- `--no-session-persistence` stops workers leaving their own transcripts; the enumeration also pipes through `prune-self-sessions.sh --filter` to drop any left by older runs. Without this, ~90% of a night's corpus is autodream re-reading itself.
