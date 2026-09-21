#!/bin/bash
# Deterministic, model-free session statistics sidecar for cc-autodream L1 triage.

set -u

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <transcript.jsonl> <out.stats.json>" >&2
  exit 2
fi

transcript="$1"
output="$2"

[ -r "$transcript" ] || {
  echo "session-stats: transcript is not readable: $transcript" >&2
  exit 1
}

bytes=$(wc -c < "$transcript" | tr -d ' ')
mtime=$(stat -f %m "$transcript" 2>/dev/null) || {
  echo "session-stats: could not read transcript mtime: $transcript" >&2
  exit 1
}

mkdir -p "$(dirname "$output")" || exit 1

jq -R -s \
  --argjson transcript_bytes "${bytes:-0}" \
  --argjson transcript_mtime "${mtime:-0}" \
  '
  [
    split("\n")[]
    | fromjson?
    | select(type == "object")
  ] as $lines
  | [
      $lines[]
      | select(.type == "user" and .isMeta != true)
      | .message.content
      | select(
          type == "string"
          or (
            type == "array"
            and any(.[]?; .type == "text")
            and all(.[]?; .type != "tool_result")
          )
        )
    ] as $user_messages
  | (
      [
        $lines[]
        | select(.type == "user" and .isMeta != true)
        | select(
            (.message.content) as $c
            | ($c | type) == "string"
            or (
              ($c | type) == "array"
              and any($c[]?; .type == "text")
              and all($c[]?; .type != "tool_result")
            )
          )
        | .timestamp
        | select(type == "string")
        | try (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) catch empty
      ] | sort
    ) as $user_turn_timestamps
  | [
      $lines[]
      | select(.isMeta != true and (.type == "user" or .type == "assistant"))
    ] as $turns
  | [
      $lines[]
      | select(.type == "assistant" and (.message.content | type) == "array")
      | .message.content[]
      | select(.type == "tool_use")
    ] as $tool_uses
  | [
      $lines[]
      | select(.type == "assistant")
      | .message.model
      | select(type == "string" and length > 0 and . != "<synthetic>")
    ] as $models
  | [
      $lines[]
      | select(has("timestamp"))
      | .timestamp
      | select(type == "string")
      | try (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) catch empty
    ] as $timestamps
  | [
      $lines[]
      # Marker counting is top-level-session-only (advisor-cabinet spec):
      # sidechain (subagent) assistant text never contributes markers.
      | select(.type == "assistant" and .isSidechain != true and (.message.content | type) == "array")
      | .message.content[]
      | select(.type == "text" and (.text | type) == "string")
      | .text
    ]
    | join("\n") as $assistant_text
  | {
      user_message_count: ($user_messages | length),
      turn_count: ($turns | length),
      tool_call_count: ($tool_uses | length),
      tools_used: (
        $tool_uses
        | map(.name)
        | map(select(type == "string"))
        | unique
        | sort
      ),
      skills_invoked: (
        [
          $tool_uses[]
          | select(.name == "Skill")
          | .input.skill
          | select(type == "string" and length > 0)
        ]
        + [
          $lines[]
          | select(.type == "user")
          | .message.content
          | if type == "string" then .
            elif type == "array" then .[] | select(.type == "text") | .text
            else empty end
          | select(type == "string")
          | capture("^<command-message>[^<]+</command-message>\\s*<command-name>/(?<skill>[^<\\s]+)</command-name>")
          | .skill
        ]
        | unique | sort
      ),
      models_used: ($models | unique | sort),
      duration_minutes: (
        if ($timestamps | length) < 2 then 0
        else (((($timestamps | max) - ($timestamps | min)) / 60) * 10 | round) / 10
        end
      ),
      compliance_markers: (
        # Line-start counting (2026-07-20, advisor-cabinet spec): a marker counts
        # only when it BEGINS a line of assistant text and is outside a ``` fence,
        # so quoted reports and rule-file examples cannot inflate the counts.
        reduce ($assistant_text | split("\n"))[] as $l (
          {fence: false, rb: 0, fp: 0, dl: 0, dok: 0};
          if ($l | test("^\\s*```")) then .fence = (.fence | not)
          elif .fence then .
          elif ($l | startswith("RETRY-BUDGET:")) then .rb += 1
          elif ($l | startswith("FETCH-PIVOT:")) then .fp += 1
          elif ($l | startswith("DELEGATED:")) then .dl += 1
          elif ($l | startswith("DIRECT-OK:")) then .dok += 1
          else . end
        )
        | {"RETRY-BUDGET": .rb, "FETCH-PIVOT": .fp, "DELEGATED": .dl, "DIRECT-OK": .dok}
      ),
      transcript_bytes: $transcript_bytes,
      transcript_mtime: $transcript_mtime,
      isSidechain: (any($lines[]?; .isSidechain == true)),
      user_turn_timestamps: $user_turn_timestamps
    }
  ' "$transcript" > "$output"
