#!/usr/bin/env bash
# Render a single session's conversation in a minimal AI-readable format.
# Only includes: user text, assistant text, tool call name + input.
# Excludes: reasoning, step markers, file parts, tool output.
#
# Output: Plain text with role delimiters.
#
# Usage:
#   view-session.sh SESSION_ID
#   view-session.sh SESSION_ID -t   # include truncated tool output (200 chars)

set -euo pipefail

INCLUDE_TOOL_OUTPUT=false

while getopts "t" opt; do
  case "$opt" in
    t) INCLUDE_TOOL_OUTPUT=true ;;
  esac
done
shift $((OPTIND - 1))

if [ $# -lt 1 ]; then
  echo "Error: SESSION_ID required" >&2
  exit 1
fi

SESSION_ID="$1"

# Export session to temp file
TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"' EXIT

opencode export "$SESSION_ID" 2>/dev/null > "$TMPFILE"

if [ ! -s "$TMPFILE" ]; then
  echo "Error: Could not export session $SESSION_ID" >&2
  exit 1
fi

# Process messages
jq -r --argjson include_tool_output "$INCLUDE_TOOL_OUTPUT" '
  .messages[] |
  .info.role as $role |
  .parts as $parts |

  # User messages: collect non-synthetic text parts only (skip tool call summaries/results)
  if $role == "user" then
    ($parts | [.[] | select(.type == "text" and (.synthetic | not)) | .text] | join("\n\n")) as $text |
    if ($text | length) > 0 then
      "--- user ---\n\($text)\n"
    else
      empty
    end

  # Assistant messages: collect text parts only (skip reasoning, step markers)
  elif $role == "assistant" then
    ($parts | [.[] | select(.type == "text" and (.synthetic | not)) | .text] | join("\n\n")) as $text |
    if ($text | length) > 0 then
      "--- assistant ---\n\($text)\n"
    else
      empty
    end

  # Tool messages: show tool name, input, status, and optionally output
  elif $role == "tool" then
    ($parts | [.[] | select(.type == "tool")] | map(
      "--- tool: \(.tool) ---\n" +
      ((.state.input // {} | if type == "object" then to_entries | map("\(.key): \(.value)") | join("\n") else tostring end)) +
      "\nstatus: \(.state.status)" +
      (if .state.status == "error" then
        "\nerror: \(.state.error // "unknown")"
      else
        ""
      end) +
      (if $include_tool_output and .state.output then
        "\noutput: \(.state.output | if length > 200 then .[:200] + "..." else . end)"
      else
        ""
      end)
    ) | join("\n\n")) as $tool_text |
    if ($tool_text | length) > 0 then
      "\($tool_text)\n"
    else
      empty
    end

  else
    empty
  end
' "$TMPFILE"
