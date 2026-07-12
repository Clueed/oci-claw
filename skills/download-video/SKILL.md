---
name: download-video
description: Download videos from URLs (thisvid.com, gofile.io, MEGA, porn sites, etc.), scan them into stash, scrape metadata, and update the scene with title, details, tags, and cover image. Use this skill whenever a user pastes a video URL or asks to download a video from a site.
---

# Download Video Skill

This skill downloads a video from a URL, adds it to the stash video library, scrapes metadata where the source supports it, and tags the resulting scene.

Every download has the same shape: **pick a download method for the source (A–D), then hand off to the `stash-api` skill to catalog it.** The download command and a few quirks differ per source; everything after the file lands on disk — scanning, finding the scene, scraping, tagging — is owned by the **stash-api** skill (see [Hand off to stash-api](#hand-off-to-stash-api)). This skill does not care whether a source is scrapable; that's entirely stash-api's concern.

## Prerequisites

- yt-dlp is available via `nix run nixpkgs#yt-dlp`
- megatools is available via `nix run nixpkgs#megatools`
- Stash API is running on localhost:9999
- The video library path in stash is `/data/remote` (mounted at `/mnt/stash-data/remote/` on the host)

> `<skill-path>` below refers to this skill's absolute directory path (where this SKILL.md lives).

## Choosing a download method

| Source                                      | Method                                       |
| ------------------------------------------- | -------------------------------------------- |
| Most sites / porn sites (thisvid.com, etc.) | [Option A: yt-dlp](#option-a-yt-dlp-default) |
| gofile.io links                             | [Option B: gofile.io](#option-b-gofileio)    |
| PMVHaven pages                              | [Option C: PMVHaven](#option-c-pmvhaven)     |
| MEGA.nz links (`mega.nz/file/...#...`)      | [Option D: MEGA.nz](#option-d-meganz)        |

## Download methods

Run the download, then continue to [Hand off to stash-api](#hand-off-to-stash-api).

### Option A: yt-dlp (default)

```bash
cd /mnt/stash-data/remote/ && nix run nixpkgs#yt-dlp -- -f "bestvideo[ext=mp4]+bestaudio[ext=m4a]/best[ext=mp4]/best" "VIDEO_URL" -o "%(title)s.%(ext)s"
```

### Option B: gofile.io

```bash
cd /mnt/stash-data/remote/ && bun <skill-path>/scripts/download-gofile.ts "GOFILE_URL"
```

If the script prints folder contents instead of downloading, ask the user which file they want — never auto-download all contents without explicit instructions.

### Option C: PMVHaven

1. Resolve the direct MP4 URL: `bun <skill-path>/scripts/resolve-pmvhaven.ts "VIDEO_PAGE_URL"`
2. Download it like Option A but **omit `-f`** (the direct MP4 is already best). Rename the file if it downloads with a hashed name.
3. PMVHaven exposes hashtags on the page — collect them and carry them, plus a `pmv` tag, as **extra tags** (see below):
   ```bash
   curl -s "VIDEO_PAGE_URL" | rg -oP '#\w+'
   ```

### Option D: MEGA.nz

```bash
cd /mnt/stash-data/remote/ && nix run nixpkgs#megatools -- dl "MEGA_URL"
```

- Auto-resumes partial downloads via `.part` files — re-run the same command if interrupted.
- Downloads to the current directory with its original filename.
- Large files may need long timeouts (>2 min); run directly in the terminal or use a generous timeout.

## Hand off to stash-api

The file is now in the Stash library (`/data/remote`). Everything else — scan,
find, scrape, tag — belongs to the **stash-api** skill. Read its `SKILL.md` and
follow the new-scene ingest flow, passing the **source URL** that was downloaded
(or noting there is none). stash-api decides on its own whether and how that URL
can be scraped.

**Extra tags** If the source
surfaced tags of its own (e.g. PMVHaven's `pmv` and page hashtags), apply them to
the scene once stash-api reports the catalogued scene ID:

## When to use me

Use this skill when:

- User pastes a video URL (including gofile.io links and MEGA links)
- User asks to download a video from a site
- User wants to add a new video to their stash library

For gofile.io folder URLs, run the URL through the script first — its output will tell you what to do.
