---
name: torrent
description: Manage Transmission BitTorrent client via CLI. Use this skill whenever the user wants to manage torrents - adding, removing, pausing, resuming, selecting/deselecting files, checking status, or any other torrent operations. The Transmission remote CLI (transmission-remote) is the primary interface.
---

# Transmission BitTorrent Client Skill

This skill manages the Transmission BitTorrent client via the `transmission-remote` CLI tool.

## Key Commands

### List all torrents
```bash
transmission-remote -l
```

### Get torrent info (files, status)
```bash
transmission-remote -t <id> -f          # List files in torrent
transmission-remote -t <id> -i           # Detailed torrent info
transmission-remote -t <id> -pi         # List peers
```

### Start/Stop/Resume
```bash
transmission-remote -t <id> --stop      # Pause
transmission-remote -t <id> --start     # Resume
transmission-remote -t <id> --start     # Force restart if stuck on "Idle"
```

### Manage Files

File selection uses `-g` (get/enabled) or `-G` (no-get/disabled) with comma-separated indices or ranges:
```bash
transmission-remote -t <id> -G 0-185    # Unselect all files (0 to 185)
transmission-remote -t <id> -g 67      # Select file 67 only
```

Find specific file by name:
```bash
transmission-remote -t <id> -f | grep <filename>
```

### Add/Remove Torrents
```bash
transmission-remote -a <torrent-file-or-url>   # Add torrent
transmission-remote -t <id> --remove          # Remove torrent
```

### Reannounce (refresh peers)
```bash
transmission-remote -t <id> --reannounce
```

## Workflow Example (file deselection)

1. List torrents: `transmission-remote -l`
2. Identify most recent torrent (last line, lowest ID that is stopped/new)
3. List files: `transmission-remote -t <id> -f`
4. Unselect all: `transmission-remote -t <id> -G <first>-<last>`
5. Select specific file: `transmission-remote -t <id> -g <index>`
6. Resume: `transmission-remote -t <id> --start`

## Notes

- Torrent IDs are listed in the first column of `transmission-remote -l`
- Most recently added torrents have the highest ID numbers
- Use `--stop` then `--start` if torrent gets stuck on "Idle" after resume
- Use `--reannounce` if download speed stays at 0 despite being resumed