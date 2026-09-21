#!/usr/bin/env bash
# promote.sh — the human step between a cc-autodream report and durable memory.
#
# Layer 2 never writes memory. It leaves findings/<date>/memory-candidates.json, a JSON
# array of {"cwd","content","kind","evidence"}. This script shows each candidate and, on
# your "y", stores it in Mnemopi via the shared-memory CLI (the same adapter the MCP
# server uses, so the bank is resolved from the candidate's cwd exactly as a session
# there would resolve it). Nothing is written without a per-item answer, unless --yes.
#
# Usage:
#   promote.sh [DATE] [--yes] [--dry-run]
#     DATE       defaults to yesterday's findings dir (the nightly target)
#     --yes      accept every candidate without asking
#     --dry-run  show what would be stored; write nothing
#
# Env: AUTODREAM_DIR (default ~/.claude/autodream), SHARED_MEMORY (default ~/.local/bin/shared-memory)
set -euo pipefail

AUTODREAM_DIR="${AUTODREAM_DIR:-$HOME/.claude/autodream}"
SHARED_MEMORY="${SHARED_MEMORY:-$HOME/.local/bin/shared-memory}"
YES=0; DRY=0; DATE=""
for a in "$@"; do
  case "$a" in
    --yes) YES=1 ;;
    --dry-run) DRY=1 ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) DATE="$a" ;;
  esac
done
[ -n "$DATE" ] || DATE=$(date -v-1d +%F 2>/dev/null || date -d yesterday +%F)
FILE="$AUTODREAM_DIR/findings/$DATE/memory-candidates.json"
PROMOTED="$AUTODREAM_DIR/findings/$DATE/memory-promoted.jsonl"

command -v jq >/dev/null || { echo "promote.sh: jq is required" >&2; exit 2; }
[ -x "$SHARED_MEMORY" ] || { echo "promote.sh: shared-memory CLI not found at $SHARED_MEMORY" >&2; exit 2; }
if [ ! -s "$FILE" ]; then echo "no memory candidates for $DATE ($FILE)"; exit 0; fi
jq -e 'type=="array"' "$FILE" >/dev/null 2>&1 || { echo "promote.sh: $FILE is not a JSON array" >&2; exit 2; }

n=$(jq 'length' "$FILE")
echo "$n candidate(s) for $DATE"
stored=0; skipped=0
for i in $(seq 0 $((n - 1))); do
  cwd=$(jq -r ".[$i].cwd // empty" "$FILE")
  content=$(jq -r ".[$i].content // empty" "$FILE")
  kind=$(jq -r ".[$i].kind // \"project_note\"" "$FILE")
  evidence=$(jq -c ".[$i].evidence // []" "$FILE")
  if [ -z "$cwd" ] || [ -z "$content" ]; then
    echo "  [$((i + 1))] skipped: missing cwd or content"; skipped=$((skipped + 1)); continue
  fi
  if [ ! -d "$cwd" ]; then
    echo "  [$((i + 1))] skipped: cwd does not exist: $cwd"; skipped=$((skipped + 1)); continue
  fi
  if grep -qs -F -- "$content" "$PROMOTED" 2>/dev/null; then
    echo "  [$((i + 1))] already promoted, skipping"; skipped=$((skipped + 1)); continue
  fi
  bank=$("$SHARED_MEMORY" context --cwd "$cwd" | jq -r '.retainBank')
  [ -n "$bank" ] && [ "$bank" != "null" ] || { echo "  [$((i + 1))] skipped: no bank for $cwd"; skipped=$((skipped + 1)); continue; }
  printf '\n  [%d] %s\n      bank: %s (%s)   kind: %s\n      evidence: %s\n' "$((i + 1))" "$content" "$bank" "$cwd" "$kind" "$evidence"
  if [ "$YES" -ne 1 ] && [ "$DRY" -ne 1 ]; then
    read -r -p "      store? [y/N/q] " ans </dev/tty
    case "$ans" in
      y|Y) ;;
      q|Q) echo "stopped: $stored stored, $skipped skipped"; exit 0 ;;
      *) skipped=$((skipped + 1)); continue ;;
    esac
  fi
  payload=$(jq -cn --arg bank "$bank" --arg content "$content" --arg kind "$kind" --arg cwd "$cwd" --arg date "$DATE" --argjson evidence "$evidence" \
    '{bank:$bank, content:$content, source:"cc-autodream", extract:false, extract_entities:false, importance:0.6,
      metadata:{kind:$kind, client:"cc-autodream", cwd:$cwd, report_date:$date, evidence:$evidence, reviewed:true}}')
  if [ "$DRY" -eq 1 ]; then
    echo "      dry-run: would call mnemopi_remember with: $payload"; continue
  fi
  out=$("$SHARED_MEMORY" call mnemopi_remember "$payload" --cwd "$cwd")
  id=$(printf '%s' "$out" | jq -r '.memory_id // empty' 2>/dev/null || true)
  if [ -n "$id" ]; then
    printf '%s\n' "$(jq -cn --arg id "$id" --arg bank "$bank" --arg content "$content" '{memory_id:$id, bank:$bank, content:$content}')" >> "$PROMOTED"
    echo "      stored: $id in $bank"; stored=$((stored + 1))
  else
    echo "      FAILED to store: $out" >&2
  fi
done
echo; echo "done: $stored stored, $skipped skipped (log: $PROMOTED)"
