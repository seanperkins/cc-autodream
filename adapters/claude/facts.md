Sessions from this source ran under Claude Code. When you propose a remedy for a
finding whose evidence is a `claude` session, these are the surfaces that exist:

- `sandbox_friction` — a `permissions.allow` entry in `~/.claude/settings.json`.
- `missed_skill` — a trigger phrase in the skill's `SKILL.md` frontmatter
  `description`. Skills live under `~/.claude/skills/` and
  `~/.claude/plugins/*/skills/`. A skill compiled into the binary has no file on
  disk, so absence from a directory listing is not absence of the skill.
- `memory_miss` — a proposal in `memory-candidates.json`, never an automatic write.
  Only the user's explicit approval through `bin/promote.sh` stores it in Mnemopi.
- `compliance_failure` — cite `~/.claude/CLAUDE.md` or the project's `CLAUDE.md`.
