#!/bin/bash
# Slim an oversized Claude Code session transcript so the L1 haiku worker can read it.
#
# Some sessions are enormous (4500+ lines, ~10MB, base64 images and giant tool
# outputs). The worker can't even read 20 such lines without blowing the 25k-token
# Read limit, so it gives up and returns an error finding instead of triaging — and
# those big sessions are often the most interesting ones. This caps the damage:
#   1. truncate every line to a max width (kills base64 blobs / huge tool outputs),
#   2. keep head + tail and elide the middle (which is usually repetitive churn),
#   3. hard-cap total bytes as a final safety net.
# Triage is fuzzy pattern-spotting, not strict JSON parsing, so a lossy but
# representative transcript still yields useful findings. run.sh only invokes this
# for sessions over AUTODREAM_SLIM_BYTES; smaller ones are read verbatim.
#
# Usage: slim-transcript.sh <src.jsonl> <dst>
# Tunables (env): AUTODREAM_SLIM_MAXLINE (400 chars), _HEAD (400 lines),
#                 _TAIL (200 lines), _CAP (262144 bytes),
#                 _TOOLRESULT (600 chars), _THINKING (800 chars).
#                 AUTODREAM_SLIM_FULL=1 keeps every line and ignores _HEAD/_TAIL/_CAP.
set -u

# Everything this script writes is derived from a session transcript (mode 0600) and the
# day slice is the UNSTRIPPED record stream, so none of it may be readable by another local
# account whatever umask the caller has. The temp files are removed on every exit path,
# including a signal, so an interrupted run does not leave a raw copy at a predictable path.
umask 077
win_tmp=""
pre_tmp=""
cleanup_tmp() { [ -n "$win_tmp" ] && rm -f "$win_tmp"; [ -n "$pre_tmp" ] && rm -f "$pre_tmp"; return 0; }
trap cleanup_tmp EXIT
trap 'exit 130' INT TERM HUP

src="${1:?usage: slim-transcript.sh <src> <dst>}"
dst="${2:?usage: slim-transcript.sh <src> <dst>}"
maxline="${AUTODREAM_SLIM_MAXLINE:-400}"
headn="${AUTODREAM_SLIM_HEAD:-400}"
tailn="${AUTODREAM_SLIM_TAIL:-200}"
cap="${AUTODREAM_SLIM_CAP:-262144}"
case "$cap" in ""|*[!0-9]*) cap=262144 ;; esac   # a non-numeric cap made head -c fail and left only the footer
trmax="${AUTODREAM_SLIM_TOOLRESULT:-600}"
tkmax="${AUTODREAM_SLIM_THINKING:-800}"

[ -r "$src" ] || { echo "slim-transcript: cannot read $src" >&2; exit 1; }

# `>` onto a file that already exists keeps THAT file mode, so a 0644 leftover from an older run
# at one of these predictable paths would stay world-readable while the unstripped slice was
# written into it. The scratch files are this script own, so they are removed first. The
# destination is NOT removed (a caller such as the claude adapter reserves it with mktemp and
# hands it in; deleting it would drop that reservation); an existing one is made private instead.
# Scratch names carry the PID, so they can never collide with the input or with a stale file; the
# legacy fixed names are still removed (never when one of them is the input itself).
[ "$src" = "$dst.win.jsonl" ] || rm -f "$dst.win.jsonl"
[ "$src" = "$dst.pre.jsonl" ] || rm -f "$dst.pre.jsonl"
[ -f "$dst" ] && chmod 600 "$dst" 2>/dev/null

lines=$(wc -l < "$src" | tr -d ' ')
bytes=$(wc -c < "$src" | tr -d ' ')

# Report-day window (run.sh exports the bounds). A multi-day orchestrator is one
# file, so without the slice the worker would read every day of it on every night
# it is triaged. The slice runs FIRST because it needs each record's ORIGINAL
# timestamp. An empty slice means the file has no records the window can place
# (enumeration already refused any file that HAS timestamps and none in the day),
# so the whole transcript is used, as a transcript with no clock always was.
work_src="$src"
win_tmp=""
if [ -n "${AUTODREAM_WINDOW_START_EPOCH:-}" ] && [ -n "${AUTODREAM_WINDOW_END_EPOCH:-}" ]; then
  swin="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/session-window.sh"
  if [ -x "$swin" ]; then
    win_tmp="$dst.win.$$.jsonl"
    if "$swin" slice "$src" "$AUTODREAM_WINDOW_START_EPOCH" "$AUTODREAM_WINDOW_END_EPOCH" > "$win_tmp" 2>/dev/null && [ -s "$win_tmp" ]; then
      work_src="$win_tmp"
      lines=$(wc -l < "$work_src" | tr -d ' ')
    else
      rm -f "$win_tmp"; win_tmp=""
      echo "slim-transcript: window slice was empty or failed; using the whole transcript" >&2
    fi
  else
    echo "slim-transcript: session-window.sh not found beside this script; not slicing" >&2
  fi
fi

# Pre-pass: when jq is available, strip the bulky payloads that tool calls leave
# behind, before the line-based head/tail/truncate pass. Two transcript schemas
# show up here and they store tool output in completely different places:
#
#   Claude Code  content blocks of .type == "tool_result" inside .message.content
#   OMP          whole records with .message.role == "toolResult", carrying the
#                payload in .message.details + .message.content, plus a
#                .message.providerPayload blob on assistant turns
#
# Handling only the first schema is worse than doing nothing: jq still exits 0 and
# writes a valid file, so the fallback never fires, and the line pass below then
# spends its 400-char budget on ~190 chars of OMP envelope (id/parentId/timestamp/
# toolCallId/toolName) and cuts off at '"content":[' — the worker gets ID soup with
# no payload and no goal, and returns no findings. Both schemas are stripped here.
# The line-based pass still runs as a safety net for stragglers. Falls back
# transparently if jq isn't installed or the stream isn't parseable JSONL.
pre_src="$work_src"
pre_tmp=""
if command -v jq >/dev/null 2>&1; then
  pre_tmp="$dst.pre.$$.jsonl"
  if jq -c --argjson tr "$trmax" --argjson tk "$tkmax" '
    # tostring is applied ONLY when the value is over the cap, and never to null.
    # The first version ran it unconditionally, which did three wrong things: a
    # toolResult with .content null came out carrying the literal string "null",
    # a record with NO .content had the key invented and set to "null", and a
    # structured .arguments object was flattened to an escaped JSON string even
    # when it was 40x under the cap — destroying the very structure triage reads.
    # Verified against this exact program with jq before and after.
    # PRESENCE IS NOT A PAYLOAD. A presence check is true when the field is
    # null, so every guard below turned a null into a marker announcing that a
    # payload had been stripped -- the same false claim these guards exist to
    # stop, one level in. An absent key reads as null in jq, so this subsumes
    # the presence check. An empty object counts as no payload, since an
    # image_url of {} carries no url.
    def payload: . != null and (type != "object" or length > 0);

    def trunc($n):
      if . == null then null
      elif type == "string" then
        (if length > $n then .[0:$n] + "…[autodream: truncated]" else . end)
      else
        (tostring as $s
         | if ($s | length) > $n then $s[0:$n] + "…[autodream: truncated]" else . end)
      end;
    # CLAUDE CODE BOOKKEEPING AND REPLAY NOISE (measured 2026-10-02 on a 3,479-line
    # session: 36% conversation, 24% hook and reminder attachments, 21% mode,
    # permission-mode, last-prompt and bridge-session records). The head/tail pass
    # is positional, so on the raw stream it spent its whole budget on these and the
    # worker saw about 2% of the conversation. Dropped by an explicit DENYLIST of
    # Claude Code types and never an allowlist of user/assistant: OMP transcripts
    # come through here too, and an allowlist would delete every one of their records.
    # Kept on purpose: attachment/queued_command (the user typing mid-turn, the only
    # place that text lives), attachment/skill_listing (SESSION_TRIAGE.md names it twice:
    # the StructuredOutput HARD RULE and the missed_skill category), system records other
    # than stop_hook_summary and turn_duration (compact_boundary is the compaction marker
    # drift_after_compaction needs), pr-link and summary records.
    def noise:
      (.type | IN("bridge-session", "last-prompt", "permission-mode", "mode", "atis-latch",
                  "ai-title", "queue-operation", "file-history-snapshot",
                  "file-history-delta", "dev-mods"))
      or (.type == "attachment" and (.attachment.type | IN("queued_command", "skill_listing") | not))
      or (.type == "system" and (.subtype | IN("stop_hook_summary", "turn_duration")));
    def claude_type: .type | IN("user", "assistant", "attachment", "system");
    # RESHAPE. Claude Code writes message before timestamp, so the 400-char line cut
    # dropped the timestamp from a third of the lines, and the envelope (parentUuid,
    # uuid, cwd, sessionId, version, gitBranch, userType, toolUseResult, and the
    # message id/model/usage) used about 185 chars before the content began. Build the
    # record with type then timestamp FIRST and only the fields triage reads. A key is
    # added only when the source has it, because inventing a null is the exact bug the
    # guards elsewhere in this program exist to stop. The thinking signature is a
    # base64 blob that filled whole lines on its own.
    def reshape:
      if claude_type then
        ({type: .type}
         + (if has("timestamp") then {timestamp: .timestamp} else {} end)
         + with_entries(select(.key | IN("isSidechain", "isMeta", "isCompactSummary",
                                         "subtype", "level", "content", "message", "attachment"))))
        | (if (.message | type) == "object"
             then .message |= with_entries(select(.key | IN("role", "content")))
             else . end)
        | (if (.message.content | type) == "array"
             then .message.content |= map(if .type == "thinking" then del(.signature) else . end)
             else . end)
      else . end;
    select(noise | not) | reshape |
    if (.message | type) == "object" then
      .message |= (
        # Raw provider round-trip, never useful for triage.
        del(.providerPayload)
        # OMP: a whole record is one tool result.
        | (if .role == "toolResult" then
             (if (.details | payload) then .details = "[autodream: details stripped]" else . end)
             # has() guard, not a bare assignment: `.content = (...)` CREATES the
             # key on a record that never had one.
             | (if has("content") then .content = (.content | trunc($tr)) else . end)
           else . end)
        # Claude Code: tool results are blocks. Also caps oversized thinking and
        # tool-call arguments in either schema.
        | (if (.content | type) == "array" then
             .content |= map(
               if .type == "tool_result" then
                 # Preserve tool_use_id + is_error so triage can still tell which
                 # call failed; only the heavy content array goes. has() guard for
                 # the same reason as everywhere else in this program: without it a
                 # block carrying no content came out ASSERTING that content was
                 # stripped, which is a claim about a payload that never existed.
                 (if (.content | payload)
                    then .content = "[autodream: tool_result payload stripped]"
                    else . end)
               elif .type == "thinking" then
                 # has() guard and NO `// ""`. The first version wrote
                 # `.thinking = ((.thinking // "") | trunc($tk))`, which invented
                 # `thinking: ""` on a block that never carried the key and turned
                 # an explicit null into an empty string — the same fabrication
                 # the parent commit fixed for .content and .arguments, at the
                 # third site of the same class three lines away. trunc handles
                 # null on its own now, so the `//` was doing nothing but harm.
                 (if has("thinking") then .thinking = (.thinking | trunc($tk)) else . end)
               elif .type == "toolCall" then
                 del(.partialArgs)
                 | (if has("arguments") then .arguments = (.arguments | trunc($tr)) else . end)
               # The two image shapes keep their payload in DIFFERENT places, and
               # collapsing them cost this branch its entire purpose. Claude puts
               # the base64 in .source; an OpenAI-style image_url block puts it in
               # .image_url.url. Setting .source on BOTH left the image_url payload
               # completely intact and added a marker claiming it had been removed
               # — a file whose header promises to strip base64 image data, shipping
               # the base64 and a receipt for its deletion. Each shape is stripped
               # where its data actually lives, and only if it is there.
               elif .type == "image" then
                 (if (.source | payload) then .source = "[autodream: image stripped]" else . end)
                 # OMP keeps its image payload in .data, which this branch did not
                 # touch at all. But .data is NOT always a payload: measured across
                 # 400 real OMP transcripts on this host, all 289 image blocks carry
                 # `blob:sha256:<hash>`, a 76-char content-addressed reference
                 # totalling 22KB against a 262144-byte cap. Replacing those with a
                 # marker would delete an identifier triage can use and save
                 # nothing. Only an inline data: URI is a payload, so only that is
                 # stripped; anything else goes through trunc as a backstop for a
                 # shape neither of us has seen.
                 | (if (.data | payload) then
                      .data = (if (.data | type) == "string" and (.data | startswith("data:"))
                                 then "[autodream: image stripped]"
                                 else (.data | trunc($tr)) end)
                    else . end)
               elif .type == "image_url" then
                 (if (.image_url | payload) then .image_url = "[autodream: image stripped]" else . end)
               else . end)
           else . end)
      )
    else . end
  ' "$work_src" > "$pre_tmp" 2>/dev/null && [ -s "$pre_tmp" ]; then
    pre_src="$pre_tmp"
    # Re-measure: head/tail/cap math below should reflect post-strip size.
    lines=$(wc -l < "$pre_src" | tr -d ' ')
  else
    rm -f "$pre_tmp"; pre_tmp=""
  fi
fi

# AUTODREAM_SLIM_FULL=1 is for the chunker: keep every surviving line and apply no
# byte cap, because the chunker does its own sizing at line boundaries. Without it
# the default is unchanged, except that head and tail now count lines left AFTER the
# pre-pass dropped the noise records, so the budget lands on conversation.
full="${AUTODREAM_SLIM_FULL:-0}"
{
  if [ "$full" = "1" ] || [ "$lines" -le $((headn + tailn)) ]; then
    cut -c1-"$maxline" "$pre_src"
  else
    head -n "$headn" "$pre_src" | cut -c1-"$maxline"
    printf '...[%d of %d lines elided by autodream for size]...\n' $((lines - headn - tailn)) "$lines"
    tail -n "$tailn" "$pre_src" | cut -c1-"$maxline"
  fi
} | { if [ "$full" = "1" ]; then cat; else head -c "$cap"; fi; } > "$dst"

[ -n "$pre_tmp" ] && rm -f "$pre_tmp"
[ -n "$win_tmp" ] && rm -f "$win_tmp"

# The footer is plain text. In full mode the output is cut into chunks, so it would land in the last
# chunk as a non-JSON line the worker reads as transcript content; the chunk note and the triage
# prompt already say that long lines are cut, so full mode appends none.
[ "$full" = "1" ] || printf '\n...[autodream slimmed this transcript: original %s bytes / %s lines; lines truncated to %s chars]...\n' \
  "$bytes" "$lines" "$maxline" >> "$dst"
