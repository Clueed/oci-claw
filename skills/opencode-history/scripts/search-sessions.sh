#!/usr/bin/env bash
# Search across all user messages in all sessions for a keyword.
# Output: JSON array of match objects with session context and message snippet.
#
# Usage:
#   search-sessions.sh KEYWORD
#   search-sessions.sh KEYWORD -c N   # context lines (default 1)

set -euo pipefail

STORAGE="$HOME/.local/share/opencode/storage"
CONTEXT=1
KEYWORD=""

while getopts "c:" opt; do
  case "$opt" in
    c) CONTEXT="$OPTARG" ;;
  esac
done
shift $((OPTIND - 1))

if [ $# -lt 1 ]; then
  echo '{"error": "KEYWORD argument required"}' >&2
  exit 1
fi

KEYWORD="$1"

# Collect all session IDs that have message storage
results="[]"

for msg_dir in "$STORAGE/message/"*/; do
  [ -d "$msg_dir" ] || continue
  session_id=$(basename "$msg_dir")

  # Load session metadata
  session_title=""
  for sf in "$STORAGE/session/"*/"$session_id".json; do
    if [ -f "$sf" ]; then
      session_title=$(jq -r '.title // ""' "$sf" 2>/dev/null)
      break
    fi
  done

  # Get all user messages in chronological order
  user_messages=()
  for msg_file in "$msg_dir"*.json; do
    [ -f "$msg_file" ] || continue
    role=$(jq -r '.role' "$msg_file" 2>/dev/null)
    if [ "$role" = "user" ]; then
      msg_id=$(jq -r '.id' "$msg_file" 2>/dev/null)
      text=""
      part_dir="$STORAGE/part/$msg_id"
      if [ -d "$part_dir" ]; then
        for part_file in "$part_dir"/*.json; do
          [ -f "$part_file" ] || continue
          part_type=$(jq -r '.type' "$part_file" 2>/dev/null)
          if [ "$part_type" = "text" ]; then
            part_text=$(jq -r '.text // empty' "$part_file" 2>/dev/null)
            [ -n "$text" ] && text="$text $part_text" || text="$part_text"
          fi
        done
      fi
      [ -n "$text" ] && user_messages+=("$msg_id|$text")
    fi
  done

  # Search through user messages
  for i in "${!user_messages[@]}"; do
    msg_data="${user_messages[$i]}"
    msg_id="${msg_data%%|*}"
    msg_text="${msg_data#*|}"

    if echo "$msg_text" | grep -qiF "$KEYWORD"; then
      # Find keyword position for snippet
      match_pos=$(echo "$msg_text" | grep -boiF "$KEYWORD" | head -1 | cut -d: -f1)
      [ -z "$match_pos" ] && match_pos=0

      start=$((match_pos > 100 ? match_pos - 100 : 0))
      snippet=$(echo "$msg_text" | cut -c$((start + 1))-$((start + 200)))

      context_before=""
      context_after=""

      if [ $i -gt 0 ]; then
        prev_idx=$((i - CONTEXT < 0 ? 0 : i - CONTEXT))
        for ((j=prev_idx; j<i; j++)); do
          prev_preview=$(echo "${user_messages[$j]#*|}" | head -c 150)
          [ -n "$context_before" ] && context_before="$context_before | $prev_preview" || context_before="$prev_preview"
        done
      fi

      next_idx=$((i + 1))
      end_idx=$((i + CONTEXT < ${#user_messages[@]} ? i + CONTEXT : ${#user_messages[@]} - 1))
      if [ $next_idx -le $end_idx ]; then
        for ((j=next_idx; j<=end_idx; j++)); do
          next_preview=$(echo "${user_messages[$j]#*|}" | head -c 150)
          [ -n "$context_after" ] && context_after="$context_after | $next_preview" || context_after="$next_preview"
        done
      fi

      results=$(echo "$results" | jq -c \
        --arg session_id "$session_id" \
        --arg session_title "$session_title" \
        --arg message_id "$msg_id" \
        --argjson message_index "$i" \
        --arg snippet "$snippet" \
        --arg context_before "$context_before" \
        --arg context_after "$context_after" \
        '. + [{
          session_id: $session_id,
          session_title: $session_title,
          message_id: $message_id,
          message_index: $message_index,
          snippet: $snippet,
          context_before: $context_before,
          context_after: $context_after
        }]')
    fi
  done
done

echo "$results" | jq '.'
