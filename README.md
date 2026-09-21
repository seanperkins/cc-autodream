# cc-autodream

Nightly memory consolidation for Claude Code. While you sleep it reads yesterday's
session transcripts and leaves you one short report: the mistakes you keep making,
where you lost time, and what's worth remembering.

## Why

You have dozens of Claude Code sessions a week. The useful lessons — a wrong
assumption you made twice, a flag that always trips you up, a fix worth pinning to
memory — are buried in transcripts you'll never reread. Claude starts each session
fresh and rediscovers the same friction.

cc-autodream does the rereading for you. Every night it looks across **all** of
yesterday's sessions, ranks what recurs by frequency × severity (so you see the
patterns, not the one-offs), and writes a dated digest you can skim in a minute. The
highest-confidence, highest-severity findings become *memory candidates*; after the
morning triage, `bin/promote.sh <date>` writes the ones you accept to your durable memory
store (Mnemopi), so the next session already knows. Nothing is remembered without a human
looking at it first.

This is the cross-session view the built-in per-project auto-memory doesn't give you.
cc-autodream is a *signal extractor* — it reads full transcripts and tells you what
happened; the memory store stays authoritative and reviewed.

## What you get

A report at `~/.claude/dreams/YYYY-MM-DD.md`. See
[`example/2026-05-25.md`](example/2026-05-25.md) for a real one (60 sessions, seven
ranked patterns, five open questions). The shape:

```markdown
# Dream report — 2026-05-29   (21 sessions)

## Top patterns
1. **Editing files before reading them** ×6  ·  high
   Six sessions hit "File has not been read yet". Read-before-Edit isn't sticking.
   → Memory candidate: always Read a file in-session before the first Edit.
2. **$() in Bash triggers permission prompts** ×4  ·  medium
3. **Assuming the host TZ is Pacific** ×2  ·  medium

## Upstream Claude Code changes
- v2.x.y added `--foo`; relevant to the rush project's deploy script.

## Open questions for the user
1. Add a Read-before-Edit reminder to the project CLAUDE.md?
```

Three ways you actually interact with it:

- **It runs unattended.** A launchd job fires overnight (with morning catch-up
  triggers in case the Mac was asleep). You do nothing.
- **It opens itself.** When a report lands, `notify.sh` writes its open questions to a
  text file and pops it open in your editor — so it's in front of you with morning
  coffee, not waiting to be discovered.
- **It has an interactive suggestion solver.** `review.sh` opens a Claude session
  preloaded with the report and walks the open questions one at a time — restate,
  recommend, then **approve / modify / skip / discuss** — executing the ones you
  approve and logging each decision back into the report.
- **It stays quiet when there's nothing to say.** Most nights the report has no
  open questions, and opening a session just to be told "nothing to do" costs a
  session's tokens to print one line. `review.sh` detects that itself and prints
  the line instead. Same for a report you've already triaged. Anything it can't
  classify still opens the session — a wasted session is cheaper than a buried
  question. `--force` overrides.

## Install

```bash
git clone https://github.com/STRML/cc-autodream ~/git/cc-autodream
cd ~/git/cc-autodream
./install.sh
```

This symlinks `bin/*.sh`, `prompts/*.md` and the `adapters/` tree into `~/.claude/autodream/`, creates
`~/.claude/dreams/`, and on macOS installs and bootstraps the nightly launchd
schedule for you (auto-detecting your username, paths, and `claude`/`git` location —
no plist editing). Because the scripts are symlinks, editing the repo copy takes
effect immediately. Requires the `claude` CLI on PATH (override with `CLAUDE_BIN`).

Install also detects every Claude config dir on the machine — `~/.claude-nous`,
`~/.claude-ds4`, `~/.claude-sigint`, and any other `~/.claude*/projects` bucket — and
asks whether to index each one (on a non-interactive install it indexes them all and
says so). The choices land in `~/.claude/autodream/root-choices.conf`, and the enabled
set is written to `config` as `SESSION_ROOTS`. You can add or remove a folder later by
editing that file and re-running `./install.sh`.

The schedule fires `run.sh` at 03:15 with morning catch-up triggers (06:15/09:15/12:15)
in case the Mac was asleep; the idempotency guard makes all but the first a one-second
no-op. To skip scheduling and only symlink the scripts:

```bash
./install.sh --no-schedule
```

launchd won't *wake* the Mac, so to guarantee the 03:15 trigger runs at all, add a
scheduled wake:

```bash
sudo pmset repeat wake MTWRFSU 03:10:00
```

The hand-editable template lives at `launchd/com.user.autodream.plist.example` if you'd
rather install the job yourself.

## Running it by hand

```bash
~/.claude/autodream/run.sh $(date -v-1d +%Y-%m-%d)       # process yesterday
AUTODREAM_FORCE=1 ~/.claude/autodream/run.sh 2026-05-29  # rebuild a date
~/.claude/autodream/review.sh                            # solve the latest report's questions
~/.claude/autodream/review.sh 2026-05-29                 # triage a specific report
~/.claude/autodream/review.sh --force 2026-05-29         # open it even if there's nothing to triage
```

`review.sh` exits without opening a session when the report has no open questions
or already carries a `## Triage decisions` section, printing where the report is
and the `--force` line to open it anyway. It reads the
`<!-- autodream:open-questions=N -->` marker that `PROMPT.md` makes the nightly run
emit; reports written before that marker existed fall back to a prose check, and
anything ambiguous opens the session as before.

By default `review.sh` runs the triage session inline in the current terminal —
and if you launch it as a shell script, macOS hands it to whatever app is the
default handler for shell scripts (often iTerm2). To make it open in its own
cmux workspace instead, drop a config file at `~/.claude/autodream/config`
(see `example/config.example`):

```bash
AUTODREAM_TRIAGE_SURFACE=cmux    # inline (default) | cmux
```

## Leaving notes for the next run

Notes you leave get answered in the report's **Operator notes** section, with evidence
from that night's sessions — "how often did I actually use /graphify, and did it work?"
comes back as a count and a verdict, not a guess.

From a terminal:

```bash
~/.claude/autodream/autodream-note.sh "evaluate how often /graphify is used"
~/.claude/autodream/autodream-note.sh --expires 2026-10-01 "check the codemaps hook overhead"
```

From anywhere else, including your phone, point autodream at a folder in a synced
vault and drop a markdown file in its inbox:

```bash
# in ~/.claude/autodream/config — quote it, the iCloud path has spaces
AUTODREAM_VAULT_DIR="$HOME/Library/Mobile Documents/iCloud~md~obsidian/Documents/vault/autodream"
```

The run creates the rest on its own:

| path | what it holds |
| --- | --- |
| `<vault>/inbox/*.md` | drop a note here; one file per note, any filename |
| `<vault>/processed/<date>/` | where a note moves once a report has read it |
| `<vault>/reports/<date>.md` | the nightly report, copied in so you can read it in bed |

Add `expires: YYYY-MM-DD` as YAML frontmatter to a note that should retire itself. A
note is only archived after a report actually read it, so a failed run leaves your
inbox alone, and so does a note you write while a run is in flight.

## Ideas from your X bookmarks

Point autodream at your X bookmarks and the report gains an **Ideas from bookmarks**
section: what you saved, crossed against what you actually worked on that day. A
bookmark that connects to nothing gets left out — the section is the intersection, not
a reading list.

X's official API can't do this (the bookmarks endpoint needs the $200/mo Basic tier),
so this reads the same web endpoint your browser does, with your session cookies:

1. Open x.com in a browser, logged in. DevTools → Application → Cookies → `https://x.com`.
2. Copy the values of `auth_token` and `ct0`.
3. Put them in `~/.claude/autodream/x-credentials`:

```bash
X_AUTH_TOKEN=paste_auth_token_here
X_CT0=paste_ct0_here
```

```bash
chmod 600 ~/.claude/autodream/x-credentials
~/.claude/autodream/x-bookmarks.sh status   # check it took
```

Bookmarks are marked read once a report has covered them, so each one gives you an
idea once. Without that file the feature is simply off. When the cookies expire the
report says so and tells you to re-paste; the run itself never fails over it.

## Running long jobs

A full run usually takes more than 10 minutes. If you're kicking it off from
something that kills long jobs (a Claude Code background task, a flaky ssh session),
use `autodream-now.sh` — it hands the run to launchd, which has no time cap and keeps
going after you disconnect:

```bash
~/.claude/autodream/autodream-now.sh                    # yesterday, right now
~/.claude/autodream/autodream-now.sh 2026-05-29 --force # a specific date, rebuild
~/.claude/autodream/autodream-now.sh 2026-05-29 --watch # follow the log until the report lands
```

## How it works (short version)

Two layers: a cheap per-session pass (`haiku`) extracts structured findings from each
transcript, then a single smarter pass (`claude-opus-4-7`, overridable with `AUTODREAM_L2_MODEL`) ranks them across the whole day and
writes the report. It also diffs the upstream Claude Code changelog over the day so
the report can flag releases that change how you work.

Everything lives on disk (findings JSON, the report, run logs, stats) and every step
is idempotent, so you can rerun any date. Configuration knobs are documented in
`bin/run.sh`'s header.

Reading sessions is done through a **harness adapter**, so the runner does not know
which agent produced a transcript. Today there is one; the seam is what lets a second
arrive without forking the pipeline.

- `adapters/<name>/` — one directory per harness: `manifest.json` (data, read with
  `jq`, never sourced), `adapter.sh` (enumerate, normalize, project, stats, slim,
  is-self, memory-root), and `facts.md` (the remedy vocabulary for that harness, so
  a fix is phrased in terms the harness actually has) → `adapters/claude/facts.md`
- `bin/adapters.sh` — adapter discovery, identity validation and containment
- `bin/lib-project.sh` — the canonical project encoding and artifact hash every
  adapter must agree on
- `bin/preflight.sh` — the shared-dependency gate, run before anything is enumerated

For the internals — data flow, file map, state layout, environment overrides, the
lean-query pattern, the adapter contract, and the "don't eat your own tail"
self-pollution defenses — see **`codemaps/architecture.md`**, **`AGENTS.md`**, and
**`docs/design/unify-harness-adapters-2026-08-23.md`** for the subcommand table
the adapter contract is defined by.

## Caveats

- macOS-only as written (BSD `date`, `launchd`, `osascript`/`open`). The core pipeline
  is portable; the scheduling and notify bits are mac-specific. The morning
  open-questions file opens with your default `.md` app; set `AUTODREAM_OPEN`
  (e.g. `subl`, `code -g`, `open -a Obsidian`) to pick a specific editor.
- Runs in `bypassPermissions` mode (workers Write findings; the aggregator writes the
  report and the candidates sidecar). Don't run it in a shared environment.
- The first run clones `anthropics/claude-code` (small) for the changelog window; it
  degrades gracefully with no git/network.

## License

MIT — see LICENSE.
