#!/usr/bin/env bash
# List all sessions with metadata for finding relevant conversations.
# Output: JSON array of session objects sorted by most recent first.
#
# Usage:
#   list-sessions.sh              # all sessions
#   list-sessions.sh -s KEYWORD   # filter by keyword in title
#   list-sessions.sh -n N         # limit to N most recent

set -euo pipefail

KEYWORD=""
MAX_COUNT=""

while getopts "s:n:" opt; do
  case "$opt" in
    s) KEYWORD="$OPTARG" ;;
    n) MAX_COUNT="$OPTARG" ;;
  esac
done

CMD="opencode session list --format json"
[ -n "$MAX_COUNT" ] && CMD="$CMD -n $MAX_COUNT"

eval "$CMD" 2>/dev/null | jq --arg keyword "$KEYWORD" '
  sort_by(.updated) | reverse |
  if $keyword == "" then .
  else
    ($keyword | ascii_downcase) as $kw |
    [.[] | select(.title | ascii_downcase | contains($kw))]
  end |
  [.[] | {id, title, directory, created, updated}]
'
