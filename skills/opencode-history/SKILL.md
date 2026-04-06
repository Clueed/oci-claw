---
name: opencode-history
description: Analyze, search, and summarize past OpenCode conversations stored locally on disk
license: MIT
compatibility: opencode
metadata:
  audience: developers
  workflow: analysis
---

## What I do

- List all past OpenCode sessions with titles, dates, and project directories
- Export and read full conversation transcripts from any session
- Search across all conversations for specific topics, commands, or decisions
- Summarize what was discussed in past sessions
- Find specific messages or solutions from previous work

## Storage locations

OpenCode stores all data locally at `~/.local/share/opencode/`:

- **Sessions**: `storage/session/` — JSON files with session metadata (id, title, project, timestamps)
- **Messages**: `storage/message/<sessionId>/` — Message metadata (role, model, tokens, cost)
- **Parts**: `storage/part/<messageId>/` — Actual message content (text, reasoning, tool calls)
- **SQLite DB**: `opencode-local.db` — ~44MB database with indexed data
- **Logs**: `log/` — Per-session log files

## How to list sessions

```bash
# List all sessions (JSON format)
opencode session list --format json

# List last N sessions
opencode session list --format json -n 10

# List all sessions with title and directory
opencode session list --format json | jq -r '.[] | "\(.id) | \(.title) | \(.directory)"'
```

## How to export a session

```bash
# Export a single session to JSON
opencode export <sessionID>

# Export and view in editor
opencode export <sessionID> | less
```

## How to read messages directly from storage

Each session has message files and part files:

```bash
# List sessions for a project
ls ~/.local/share/opencode/storage/session/<projectHash>/

# Read session metadata
cat ~/.local/share/opencode/storage/session/<projectHash>/ses_<id>.json

# List messages for a session
ls ~/.local/share/opencode/storage/message/ses_<id>/

# Read a message (metadata)
cat ~/.local/share/opencode/storage/message/ses_<id>/msg_<id>.json

# Read actual message content (text)
cat ~/.local/share/opencode/storage/part/msg_<id>/prt_<id>.json
```

## How to search conversations

```bash
# Search all user messages across sessions for a keyword
for msgDir in ~/.local/share/opencode/storage/message/*/; do
  for msgFile in "$msgDir"*.json; do
    role=$(jq -r '.role' "$msgFile" 2>/dev/null)
    if [ "$role" = "user" ]; then
      msgId=$(basename "$msgFile" .json)
      for partFile in ~/.local/share/opencode/storage/part/"$msgId"/*.json; do
        grep -l "KEYWORD" "$partFile" 2>/dev/null && echo "  Found in: $msgFile"
      done
    fi
  done
done

# Extract all text from exported session
opencode export <sessionID> | jq -r '.messages[].parts[] | select(.type == "text") | .text'
```

## How to get stats

```bash
# Show token usage and cost statistics
opencode stats

# Stats for last N days
opencode stats --days 30

# Include model breakdown
opencode stats --models 10
```

## When to use me

Use this skill when you need to:
- Find a past solution or decision from a previous conversation
- Search for a specific command, error, or fix discussed before
- Review what was done in a past session
- Summarize work done across multiple sessions
- Find a session by topic or keyword
