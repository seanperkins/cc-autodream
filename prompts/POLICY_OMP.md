---

# SOURCE OVERRIDE — this session is Oh My Pi (`omp`), not Claude Code

Everything above describes Claude Code. **This transcript is from a different harness**, and it was appended here because the runner detected that. Where the two disagree, this section wins. The schema, the severity bar, the evidence rule, the 10-finding cap and the facets are unchanged — only the harness-specific signals below are.

Read the transcript the same way. It has been normalized to the live conversation already (an OMP session file is a tree; the runner collapsed it to the chain the user actually kept and dropped abandoned branches). The first line is an `autodream_meta` record from the runner, not session content.

## Translations

| Claude Code | Oh My Pi | Consequence for triage |
|---|---|---|
| `tool_use` / `tool_result` entries | `{"type":"message"}` entries whose `message.content[]` holds `toolCall` / a `message.role":"toolResult"` | Same meaning; count and quote them the same way |
| `Bash`, `Read`, `Edit`, `Write`, `Grep`, `Glob`, `Task` | lowercase `bash`, `read`, `edit`, `write`, `grep`, `glob`, `task` — plus `hub`, `todo`, `eval`, `yield`, `advise`, `browser`, `lsp`, `debug`, `ast_edit`, `web_search`, `recall`, `retain`, `reflect` | Emit `tools_used` with the spellings the transcript uses. Never "correct" them to Claude names |
| MCP tools as `mcp__server__tool` | device writes to `xd://mcp__<server>_<tool>`, and built-in devices as `xd://<tool>` | A `write` whose path starts `xd://` is a tool invocation, not a file write. Never report it as an unexpected write |
| `skill_listing` attachment | a `<skills>` block in the system prompt; skills are read via `skill://<name>` | **The absence of a `skill_listing` attachment means nothing here.** Never infer a fabricated or missing tool from it |
| `.claude/settings.json` allowlist/denylist | omp config (`~/.omp/agent/config.yml`), `--approval-mode`, `--permission-mode`, and per-tool policy | A `permission_prompt` finding must propose an omp surface. Never propose a `.claude/settings.json` edit for an omp session |
| `dangerouslyDisableSandbox: true` retries | `Tool "<name>" not available`, `Blocked: Use the <tool> tool instead`, `Skipped due to pending system advisory` | These are the `sandbox_friction` signals here. There is no `dangerouslyDisableSandbox` in omp |
| `MEMORY.md` / `CLAUDE.md` pins, `claude-memory gc` | mnemopi (`recall` / `retain` / `reflect` / `memory_edit`), `memory://` URIs | A `memory_miss` proposed_rule must name mnemopi, never a `MEMORY.md` edit |
| subagents via `Task`, sidechain transcripts | subagents via the `task` tool and `hub` coordination; children are separate nested session files | A nested child transcript has no human in it. Judge it as delegated work, not as a conversation |

## Rules that do NOT apply to this session

1. **`compliance_markers` are a Claude-rules artifact.** `RETRY-BUDGET:`, `FETCH-PIVOT:`, `DELEGATED:` and `DIRECT-OK:` come from rule files loaded by Claude Code. OMP does not load them, so their absence is **descriptive, not a compliance breach**. Emit all four as `0` and write **no finding** about missing markers. In particular, a `tool_loop` here is never downgraded for "no RETRY-BUDGET marker" and never flagged for lacking one — judge the loop on its own behaviour.

2. **The `StructuredOutput` / `SendMessage` / `Task` HARD RULE generalises.** Any tool the transcript uses successfully is harness-provided. `yield`, `advise`, `hub`, `todo` and any `xd://` device are real omp tools. `fabricated_id` still applies to invented SHAs, PR numbers and line numbers, but a tool existing is never evidence of fabrication.

3. **`missed_skill` requires positive evidence.** Flag it only when the transcript itself shows the skill was available — the `<skills>` block lists it, or the user names it — AND the agent did the work by hand anyway. Do not reason from Claude's skill catalogue: a skill installed for Claude Code may be invisible to this harness. When in doubt, emit nothing. (Four `missed_skill` findings on 2026-08-18 were exactly this mistake, and the aggregator had to spend its top-ranked slot retracting them.)

## Signals that are specific to this harness

**Use the existing categories — never invent one.** These are observations to look for, not new category names. The schema's category list is closed, and a coined category (an `eval_state_loss` appeared in the 2026-08-18 run precisely because this section did not say so) splinters the aggregator's grouping and cannot be ranked against history. Map each onto the categories in the main document:

| Observation | File it under |
|---|---|
| A tool erroring `not available`, then succeeding later in the same session | `sandbox_friction` |
| `Blocked: Use the <tool> tool instead`, re-attempted instead of switched | `sandbox_friction`; `tool_loop` if retried ≥3 times |
| `eval` cells losing globals, or re-importing in every cell | `tool_loop` when it is a repeated cycle; otherwise emit nothing |
| An advisory obeyed without checking that the transcript then shows was wrong | `sandbox_friction` |
| A parent redoing a child's work, or children duplicating each other | `missed_skill` when a skill covered it, else `tool_loop` |

Judge them as you would any other finding — evidence quoted, severity honest:

- **Tool-availability churn.** A tool erroring `not available` and later succeeding in the same session is a real friction finding; quote both turns.
- **Harness redirects treated as failures.** `Blocked: Use the read tool instead` is the harness steering, not a permission denial. Repeatedly re-attempting the blocked form instead of switching tools is the finding.
- **Advisory handling.** An advisory (`Skipped due to pending system advisory`, or an injected advisory message) that the agent obeys without checking, when the transcript shows it was factually wrong, is worth a finding — as is ignoring one that was right.
- **`eval` state loss.** The `eval` tool keeps a persistent kernel; re-importing or re-declaring in every cell, or losing globals between cells, is a real workflow finding.
- **Nested-session coordination.** A parent that spawns children and then redoes their work, or children that duplicate each other, is a delegation finding.

## Reminder

`project` is derived by the runner from the session's `cwd`, so an omp session and a Claude session in the same directory belong to the same project. That is intended — do not try to distinguish them in the `project` field.
