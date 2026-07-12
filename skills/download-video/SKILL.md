---
name: download-video
description: Download videos from URLs (thisvid.com, gofile.io, MEGA, porn sites, etc.), scan them into stash, scrape metadata, and update the scene with title, details, tags, and cover image. Use this skill whenever a user pastes a video URL or asks to download a video from a site.
---

# Download Video Skill

This skill downloads a video from a URL, adds it to the stash video library, scrapes metadata where the source supports it, and tags the resulting scene.

Every download has the same shape: **pick a download method for the source (A–D), then hand off to the `stash-api` skill to catalog it.** The download command and a few quirks differ per source; scanning, finding the scene, scraping, and tagging are identical for all of them and are owned by the **stash-api** skill (see [Cataloging in Stash](#cataloging-in-stash-after-every-download)).

## Prerequisites

- yt-dlp is available via `nix run nixpkgs#yt-dlp`
- megatools is available via `nix run nixpkgs#megatools`
- Stash API is running on localhost:9999
- The video library path in stash is `/data/remote` (mounted at `/mnt/stash-data/remote/` on the host)

> `<skill-path>` below refers to this skill's absolute directory path (where this SKILL.md lives).
> `<stash-skill-path>` refers to the **stash-api** skill's directory (sibling of this skill, at `../stash-api`). All Stash-side scripts and docs — scan, find, scrape, and tag — live there.

## Choosing a download method

| Source                                      | Method                                       | URL metadata scraping? |
| ------------------------------------------- | -------------------------------------------- | ---------------------- |
| Most sites / porn sites (thisvid.com, etc.) | [Option A: yt-dlp](#option-a-yt-dlp-default) | Yes                    |
| gofile.io links                             | [Option B: gofile.io](#option-b-gofileio)    | No                     |
| PMVHaven pages                              | [Option C: PMVHaven](#option-c-pmvhaven)     | Partial (title only)   |
| MEGA.nz links (`mega.nz/file/...#...`)      | [Option D: MEGA.nz](#option-d-meganz)        | No                     |

The last column decides whether you run the scrape step (stash-api → `scene-ingest.md` step 3). Sources without it are tagged from the filename only.

## Download methods

Run the download, then continue to [Cataloging in Stash](#cataloging-in-stash-after-every-download).

### Option A: yt-dlp (default)

```bash
cd /mnt/stash-data/remote/ && nix run nixpkgs#yt-dlp -- -f "bestvideo[ext=mp4]+bestaudio[ext=m4a]/best[ext=mp4]/best" "VIDEO_URL" -o "%(title)s.%(ext)s"
```

Supports URL scraping — run all catalog steps, including the scrape step.

### Option B: gofile.io

```bash
cd /mnt/stash-data/remote/ && bun <skill-path>/scripts/download-gofile.ts "GOFILE_URL"
```

If the script prints folder contents instead of downloading, ask the user which file they want — never auto-download all contents without explicit instructions. No URL scraping: skip the scrape step.

### Option C: PMVHaven

1. Resolve the direct MP4 URL: `bun <skill-path>/scripts/resolve-pmvhaven.ts "VIDEO_PAGE_URL"`
2. Download it like Option A but **omit `-f`** (the direct MP4 is already best). Rename the file if it downloads with a hashed name.
3. On the scrape step, scrape **title only** (pass `--title-only`) — passing `details` or `cover_image` to `sceneUpdate` 422s on PMVHaven, so drop those fields.
4. PMVHaven exposes hashtags on the page. Collect them and add the `pmv` tag, then feed the hashtags into the tag-matching step alongside filename terms:
   ```bash
   curl -s "VIDEO_PAGE_URL" | rg -oP '#\w+'
   bun <stash-skill-path>/scripts/create-tag.ts SCENE_ID "pmv"
   ```

### Option D: MEGA.nz

```bash
cd /mnt/stash-data/remote/ && nix run nixpkgs#megatools -- dl "MEGA_URL"
```

- Auto-resumes partial downloads via `.part` files — re-run the same command if interrupted.
- Downloads to the current directory with its original filename.
- Large files may need long timeouts (>2 min); run directly in the terminal or use a generous timeout.
- No URL scraping: skip the scrape step. Filename inference is the primary way to categorize MEGA downloads.

## Cataloging in Stash (after every download)

Downloading is done — the rest of the pipeline (scan → find → scrape → tag) is
owned by the **stash-api** skill. Follow `<stash-skill-path>/scene-ingest.md` for
the full sequence. In brief:

1. **Scan + find** — trigger `metadataScan`, then `findScenes` to locate the new
   scene. See stash-api → `scene-ingest.md` steps 1–2.
2. **Scrape** *(Option A; Option C with `--title-only`; skip for gofile.io and MEGA)* —
   scrape title/details/image from the URL and write them back:
   ```bash
   bun <stash-skill-path>/scripts/scrape-scene.ts "VIDEO_URL" SCENE_ID
   ```
   `scrape-scene.ts` prints the scraped tag names (ready-to-paste quoted terms)
   plus any performers/studio for reference — feed those tags into tagging below.
3. **Tag** — categorize the scene. Tags come from two sources that both flow
   through the same fuzzy-matching workflow:
   - **Scraped metadata** — the tag names printed by `scrape-scene.ts`.
   - **Filename inference** — meaningful terms picked from the downloaded
     filename, ignoring noise (hashes, timestamps, scene numbers, etc.).

   Follow `<stash-skill-path>/tags-matching.md`.

## When to use me

Use this skill when:

- User pastes a video URL (including gofile.io links and MEGA links)
- User asks to download a video from a site
- User wants to add a new video to their stash library

For gofile.io folder URLs, run the URL through the script first — its output will tell you what to do.
