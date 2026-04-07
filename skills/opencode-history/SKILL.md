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

## Scripts

Three scripts are available at `~/.agents/skills/opencode-history/scripts/`:

### list-sessions.sh

List all sessions as JSON (sorted most recent first).

```bash
# All sessions
list-sessions.sh

# Filter by keyword in title (case-insensitive)
list-sessions.sh -s "devenv"

# Limit to N most recent
list-sessions.sh -n 5

# Combine both
list-sessions.sh -s "nix" -n 10
```

Output: JSON array of `{id, title, directory, created, updated}`. Pipe to `jq` for further filtering.

### search-sessions.sh

Search across all user messages in all sessions that have local storage.

```bash
# Search for keyword
search-sessions.sh "transmission"

# Include N context messages before/after each match
search-sessions.sh "transmission" -c 2
```

Output: JSON array of `{session_id, session_title, message_id, message_index, snippet, context_before, context_after}`.

### view-session.sh

Render a single session's conversation in plain text with role delimiters.

```bash
# View session (user + assistant text + tool calls without output)
view-session.sh <sessionID>

# Include truncated tool output (200 chars)
view-session.sh <sessionID> -t
```

Output: Plain text with `--- user ---`, `--- assistant ---`, and `--- tool: NAME ---` delimiters.

## Typical workflow

1. **Find** - Use `list-sessions.sh -s KEYWORD` to find relevant sessions
2. **Search** - Use `search-sessions.sh KEYWORD` for full-text search across messages
3. **Read** - Use `view-session.sh <sessionID>` to review a specific conversation


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
