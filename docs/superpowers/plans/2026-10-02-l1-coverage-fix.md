# L1 Coverage Fix Implementation Plan

> **Status: executed, and superseded in the details.** The code and the "What L1 actually reads" section of `AGENTS.md` are authoritative. Differences from this plan, all found in review or by the test suite: chunk outputs live in `findings/<date>/.chunks/<hash>/` with a `.chunkout` suffix (never `.json`); the chunker prints `COUNT ELIDED` on stdout; the adapter is unchanged and `run.sh` passes it a far upper date (report day plus five years) as its existing third argument; the slimmer keeps `skill_listing` and every `system` record except `stop_hook_summary` and `turn_duration`; a chunk answer is accepted only if it is a findings object with no error; the window, chunker and merge sit behind one `L1_COVERAGE` gate; a no-clock file is placed by its mtime; `AUTODREAM_L1_ESCALATE_EFFORT` was dropped.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans (native, inline) to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Layer 1 triage sees the conversation of large sessions instead of 17% of their lines, reviews multi-day orchestrators one day at a time, and spends a stronger model only where friction was measured.

**Architecture:** (1) `bin/slim-transcript.sh` reshapes Claude Code records (denylist of noise types, explicit key order with `timestamp` first, `message` reduced to `role`+`content`) so the 400-char line budget goes to payload. (2) A new `bin/session-window.sh` converts the local report day to epoch bounds and slices or tests a transcript by in-record timestamp; enumeration stops excluding files still being written. (3) A chunker splits the reshaped transcript at line boundaries; L1 runs once per chunk; a jq merge produces the one-findings-JSON-per-session contract L2 already reads. (4) `session-stats.sh` counts friction signals; `dispatch_l1` escalates the model by a config knob.

**Tech Stack:** bash (macOS, BSD `date`/`stat`), jq. No python. Tests are the existing shell suites plus `tests/mock-claude.sh`.

**Spec:** this document is self-contained; the evidence is a 2026-10-02 triage of the previous night's autodream report, summarised under "Measured background" below.

## Measured background (2026-10-02, do not re-derive)

- Session A (37.4 MB, 3,479 lines): 1,260 conversation lines, ~830 attachment lines, 724 `mode`/`permission-mode`/`last-prompt`/`bridge-session` lines. Current slim keeps 603 lines (17%, 192 KB); only 74 contain `"text":`. Conversation-only reshape: 1,262 lines, 505 KB (~126k tokens).
- 3-arm test on that session: Haiku+current slim 0 findings; Haiku+conversation-only 0; Opus 5.5+conversation-only 1 real finding (evidence at raw line 1976, elided by the current slim). Opus cost $2.61 vs Haiku $0.15-0.18 per run (API-equivalent).
- Record types across 7 real transcripts (counts): assistant 9875, attachment/hook_success 6716, user 5635, attachment/total_tokens_reminder 4258, attachment/deferred_tools_record 2493, bridge-session 2279, last-prompt 2275, permission-mode 2271, mode 2271, atis-latch 2270, ai-title 2263, queue-operation 890, system/stop_hook_summary 319, attachment/queued_command 280 (user text typed mid-turn: KEEP), system/turn_duration 164, file-history-delta 167, file-history-snapshot 158, pr-link 86 (keep), system/away_summary 82 (keep), dev-mods 72.
- OMP records use `.type` of `message`, `custom`, `custom_message`, `title`, `session`, `title_change`, `thinking_level_change`; none collide with the Claude denylist. OMP records must pass through unchanged.
- Key order puts `timestamp` AFTER `message` on user/assistant lines, so the 400-char cut drops it (3,560 of 11,782 parent lines carried no timestamp). Assistant `message` content starts ~185 chars in.
- Multi-day orchestrator session B (199 MB): reshape + existing strip = 3.4 MB / 11,782 lines over 4 UTC days; roughly 0.4-1.2 MB per day. Chunking is required.
- `omp-autodream` has no `slim-transcript.sh` (it windows with a 447-line python `daily-window.py`, OMP-specific). Do not port it; do not change it.

## Global Constraints

- bash + jq only; BSD `date`/`stat`; scripts keep `set -u`. No apostrophes inside any function body a caller embeds in a single-quoted `bash -c '...'` block (see `bin/l1-invoke.sh`).
- `AUTODREAM_SLIM_BYTES` (default 262144) stays the oversized threshold; `oversized_total` and its gate key on it. Change only the cap and elision logic.
- Slimmer denylist is by Claude Code `.type`, never an allowlist; OMP and unknown schemas pass through unchanged.
- One findings JSON per session at the existing path; L2 and `run-stats` contracts do not change.
- `bin/session-stats.sh`, `bin/slim-transcript.sh`, `bin/run.sh`, `adapters/claude/adapter.sh` are not in `shared-with-sibling.txt`; `tests/run-all.sh` ends with `check-shared-drift.sh`, which must still pass.
- Scratch in `./.tmp/<task-dir>/` (ignored). No commits, no `install.sh`, no merge, no `/debate:run tight` without the user's explicit yes. Nightly runs from `~/.claude/autodream/`, so nothing here affects tonight.

## Review Focus

1. An OMP-schema record passes through the slimmer byte-for-byte unchanged (a denylist bug here deletes every OMP record).
2. A transcript with zero in-window records is not triaged (dropping the upper `find` bound must not re-triage stale sessions nightly).
3. Records with a missing or unparseable `timestamp` neither crash the filter nor get attributed to the wrong day; compaction `summary` records are kept when not windowing.
4. Chunks cut only at line boundaries, each chunk parses as JSONL, and a tool_use/tool_result pair split across two chunks is still readable (chunk note tells the worker to expect that).
5. A chunk failure partway leaves no partial session marked complete; a retry reuses finished chunk outputs.
6. DST days (23h/25h) get correct window bounds.
7. Friction counts come from `is_error:true` tool_result blocks only, never from system-prompt text.

---

### Task 1: Slimmer reshape

**Files:**
- Modify: `bin/slim-transcript.sh` (jq pre-pass; line budget)
- Test: `tests/slim-transcript.sh` (add cases using its `ok/no/assert_eq/has/hasnt/jq_is` helpers)

**Interfaces:**
- Produces: `slim-transcript.sh SRC DST` keeps today's CLI. New env: `AUTODREAM_SLIM_FULL=1` = no head/tail elision and no byte cap (used by the chunker); default behavior otherwise unchanged except the reshaped lines and a head/tail count taken over conversation lines.

- [ ] **Step 1: failing tests.** Fixture JSONL with: a `user` record with `toolUseResult` and a huge `message.usage`; an `assistant` thinking block with a 2,000-char `signature`; records of type `attachment/hook_success`, `attachment/queued_command`, `bridge-session`, `last-prompt`, `permission-mode`, `mode`, `atis-latch`, `ai-title`, `queue-operation`, `file-history-snapshot`, `file-history-delta`, `dev-mods`, `system/stop_hook_summary`, `system/turn_duration`, `system/away_summary`, `pr-link`, a `summary` record; and an OMP record `{"type":"message","message":{"role":"toolResult",...}}`. Assert: dropped types absent; `queued_command`, `away_summary`, `pr-link`, `summary` present; every kept Claude line starts with `{"type":` and has `timestamp` within the first 80 chars; no `signature` key; `message` has only `role`,`content`; `toolUseResult`, `parentUuid`, `uuid` absent; the OMP record output equals the existing pre-pass output for the same input (compare against `git stash`-free golden JSON in the test); empty haystack = failure (existing `hasnt` guard).
- [ ] **Step 2: run, expect FAIL:** `bash tests/slim-transcript.sh`
- [ ] **Step 3: implement** in the pre-pass, before the existing `.message |=` program:

```jq
def noise:
  (.type | IN("bridge-session","last-prompt","permission-mode","mode","atis-latch",
              "ai-title","queue-operation","file-history-snapshot","file-history-delta","dev-mods"))
  or (.type == "attachment" and .attachment.type != "queued_command")
  or (.type == "system" and (.subtype | IN("stop_hook_summary","turn_duration")));
def claude_type: .type | IN("user","assistant","attachment","system");
def reshape:
  if claude_type then
    ({type, timestamp} + (with_entries(select(.key | IN("isSidechain","isMeta","isCompactSummary","subtype","level","content","message","attachment")))))
    | (if (.message | type) == "object" then .message |= {role, content} else . end)
    | (if (.message.content | type) == "array"
         then .message.content |= map(if .type == "thinking" then del(.signature) else . end)
         else . end)
  else . end;
select(noise | not) | reshape
```
  Then the existing tool_result/image/toolCall stripping runs on the result unchanged. Head/tail counting uses the surviving lines (they are already only conversation lines for Claude). With `AUTODREAM_SLIM_FULL=1`, skip elision and `head -c`.
- [ ] **Step 4: run tests, expect PASS;** also run `bash tests/run-all.sh`.
- [ ] **Step 5: measure.** Re-run the session A reshape; record lines/bytes in the task notes. Expect ~1,262 lines, ~500 KB with FULL=1, and default mode now keeps head/tail of conversation lines only.
- [ ] **Step 6: Commit** only if the user has approved commits; otherwise leave uncommitted.

### Task 2: Day windowing

**Files:**
- Create: `bin/session-window.sh`, `tests/session-window.sh`
- Modify: `adapters/claude/adapter.sh:26-28` and `bin/run.sh:740-743` (drop the `! -newermt NEXT` bound), `bin/run.sh` (call the in-window filter after enumeration; export `AUTODREAM_WINDOW_START_EPOCH`/`_END_EPOCH`), `bin/slim-transcript.sh` and `bin/session-stats.sh` (slice by window when the env is set), `tests/run-all.sh` (new suite + an integration case), `tests/adapter-claude.sh` / `tests/adapter-contract.sh` if they assert the old upper bound.
- Test: `tests/session-window.sh`

**Interfaces:**
- `session-window.sh bounds DATE NEXT_DATE` prints `START_EPOCH END_EPOCH` (local midnight to local midnight, via BSD `date -j -f '%Y-%m-%d %H:%M:%S'`).
- `session-window.sh in-window FILE START END` exits 0 if any record has a timestamp in `[START,END)`, **or if no record in the file has a parseable timestamp** (bias to triage, like the noise gate); exit 1 otherwise. Streams with `jq -n 'first(inputs | select(...))'` so a 199 MB file stops at the first hit.
- `session-window.sh slice FILE START END` writes in-window records to stdout (records with no timestamp are dropped when a window is set).
- Epoch comparison uses `sub("\\.[0-9]+Z$";"Z") | fromdateiso8601` (the stats script's idiom), not string comparison.

- [ ] **Step 1: failing tests** (`tests/session-window.sh`): bounds for a normal day and for a DST day (`TZ=America/New_York`, 2026-03-08 = 23h, 2026-11-01 = 25h); `in-window` true/false/no-timestamps cases; fractional-second timestamp at the boundary second; `slice` drops outside records and malformed JSON lines without crashing. Integration (in `tests/run-all.sh`): a fixture session whose file mtime is AFTER the target day but whose records are in the day is enumerated and triaged; a fixture whose mtime is after the day but whose records are all earlier is NOT triaged.
- [ ] **Step 2: run, expect FAIL.**
- [ ] **Step 3: implement** `session-window.sh`; remove the upper bound in both `find` sites; wire `in-window` into the worklist build; export the epochs; apply `slice` at the top of the slimmer and as `$lines |= map(select(in window))` in the stats jq (so stats match the slice L1 is told are authoritative, and the noise gate judges the slice).
- [ ] **Step 4: run suites, expect PASS;** `bash tests/run-all.sh`.
- [ ] **Step 5: re-measure the orchestrator session B** for one report day: record lines/bytes of the windowed slice; this sets the chunk count in Task 3.

### Task 3: Chunking and merge

**Files:**
- Create: `bin/chunk-transcript.sh`, `tests/chunk-transcript.sh`
- Modify: `bin/l1-invoke.sh` (optional 5th arg to `l1_build_prompt`), `prompts/SESSION_TRIAGE.md` (one short chunk-note paragraph; review-gated), `bin/run.sh` `dispatch_l1` (chunk loop + merge), `bench/run-one-l1.sh` (pass-through, optional), `tests/mock-claude.sh` (record the `--model` and chunk args it receives), `tests/run-all.sh`.
- Test: `tests/chunk-transcript.sh`, integration case in `tests/run-all.sh`

**Interfaces:**
- `chunk-transcript.sh SRC OUTDIR CHUNK_BYTES MAX_CHUNKS` writes `OUTDIR/chunk-01.jsonl ...` cut only at line boundaries, prints the chunk count. Over `MAX_CHUNKS`: keep the first `ceil(MAX/2)` and last `floor(MAX/2)` chunks and print `elided=N` on stderr. Defaults: `AUTODREAM_L1_CHUNK_BYTES=300000`, `AUTODREAM_L1_MAX_CHUNKS=8`.
- `l1_build_prompt TRANSCRIPT OUTPUT TRIAGE_MD [STATS_JSON] [CHUNK_NOTE]`: when `CHUNK_NOTE` is non-empty it is printed after the stats block (for example `Chunk 2 of 4 of one session: the transcript continues across chunks; a tool call and its result can be split between chunks.`).
- Merge (jq, no model call), inputs are the per-chunk JSONs in order: `findings` = union with each item gaining `chunk: <index>`, exact duplicates on (`category`,`what`) removed; `outcome` = last chunk's; `underlying_goal` = first non-null; `notable_initiatives`, `instructions_given` = unique union; `satisfaction_signals` = sum; `meta.chunks` = N, `meta.chunks_elided` = N. Stats-derived fields come from the stats sidecar as today.
- Chunk outputs live at `$FINDINGS_DIR/$hash.chunk-NN.json`; on retry an existing non-empty chunk output is reused; all are deleted after a successful merge. Failure of any chunk after the round leaves `$output` absent (the existing retry/metadata-stub logic applies).

- [ ] **Step 1: failing tests:** chunker line-boundary and MAX_CHUNKS cases (every chunk parses as JSONL; `cat chunks == source` when not elided); merge cases (outcome from last, goal from first, dedupe, summed signals); mock integration: a 3-chunk session produces ONE merged findings file with `meta.chunks == 3`; `MOCK_MODE` chunk failure on chunk 2 leaves no output and a retry only re-runs chunk 2.
- [ ] **Step 2: run, expect FAIL.**
- [ ] **Step 3: implement** chunker, prompt arg, `dispatch_l1` loop and merge.
- [ ] **Step 4: run suites, expect PASS;** `bash tests/run-all.sh`.
- [ ] **Step 5: prompt change goes through the review gate** (held; listed in Task 5).

### Task 4: Friction signals and model escalation

**Files:**
- Modify: `bin/session-stats.sh` (two new fields), `bin/run.sh` (`dispatch_l1` model choice; counters in `run-stats`), `tests/run-all.sh`, `README.md`/`AGENTS.md` (knob docs).
- Test: stats unit assertions in `tests/run-all.sh` or a small `tests/session-stats.sh`.

**Interfaces:**
- Stats gain `error_result_count` (count of `tool_result` blocks with `is_error == true`) and `permission_denial_count` (those whose text content matches `permission|not allowed|denied|auto mode`, case-insensitive), computed over the windowed `$lines`.
- `AUTODREAM_L1_ESCALATE=off|friction|all` (default decided by the user), `AUTODREAM_L1_ESCALATE_MODEL` (default `claude-opus-5-5`), `AUTODREAM_L1_ESCALATE_MIN` (default calibrated in Step 1; escalate when `error_result_count + 3 * permission_denial_count >= MIN`), `AUTODREAM_L1_ESCALATE_MAX` per run (default 6, highest friction first). `run-stats` gains `l1_escalated: N`.

- [ ] **Step 1: calibrate** `MIN`: compute both counts on session A, the 7 sampled transcripts and a few quiet ones; pick the MIN that separates them; record the numbers.
- [ ] **Step 2: failing tests:** a fixture with errors (including an `is_error` permission denial) vs one whose system-prompt text mentions "permission" but has no errors; `friction` mode escalates only the first; `off` never; `all` always; MAX caps the count; mock logs the model used.
- [ ] **Step 3: implement.** **Step 4: run suites, expect PASS.**

### Task 5: Validate, document, hold the gates

- [ ] Re-run the 3-arm comparison (current slim vs new Haiku vs new Opus) on 3-5 large sessions with the new pipeline; append results and the branch name to `~/.claude/dreams/2026-10-01.md` under `## Triage decisions`.
- [ ] `bash tests/run-all.sh` fully green; run the workflow's separate suites (`cookie-cadence`, `review-skip`, `x-bookmarks`).
- [ ] Update `AGENTS.md` (slimmer reshape and why, windowing, chunking, escalation knobs; note the sibling has no slimmer and a different windowing design), `README.md` knobs, `CHANGELOG.md`.
- [ ] **Hold for the user's explicit yes, each separately:** `/debate:run tight` (AGENTS.md merge gate; sends the diff to Codex, Gemini and DeepSeek), merge to `main`, `bash install.sh`.
