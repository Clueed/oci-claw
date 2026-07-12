---
name: download-video
description: Download videos from URLs (thisvid.com, gofile.io, MEGA, porn sites, etc.), scan them into stash, scrape metadata, and update the scene with title, details, tags, and cover image. Use this skill whenever a user pastes a video URL or asks to download a video from a site.
---

# Download Video Skill

This skill downloads a video from a URL, adds it to the stash video library, scrapes metadata where the source supports it, and tags the resulting scene.

Every download has the same shape: **pick a download method for the source (A–D), then run the shared pipeline.** The download command and a few quirks differ per source; scanning, finding the scene, scraping, and tagging are identical for all of them, so they live once under [Shared steps](#shared-steps-run-after-every-download).

## Prerequisites

- yt-dlp is available via `nix run nixpkgs#yt-dlp`
- megatools is available via `nix run nixpkgs#megatools`
- Stash API is running on localhost:9999
- The video library path in stash is `/data/remote` (mounted at `/mnt/stash-data/remote/` on the host)

> `<skill-path>` below refers to this skill's absolute directory path (where this SKILL.md lives).

## Choosing a download method

| Source                                      | Method                                       | URL metadata scraping? |
| ------------------------------------------- | -------------------------------------------- | ---------------------- |
| Most sites / porn sites (thisvid.com, etc.) | [Option A: yt-dlp](#option-a-yt-dlp-default) | Yes                    |
| gofile.io links                             | [Option B: gofile.io](#option-b-gofileio)    | No                     |
| PMVHaven pages                              | [Option C: PMVHaven](#option-c-pmvhaven)     | Partial (title only)   |
| MEGA.nz links (`mega.nz/file/...#...`)      | [Option D: MEGA.nz](#option-d-meganz)        | No                     |

The last column decides whether you run the scrape/update step ([Shared step 3](#step-3-scrape-metadata--update-scene)). Sources without it are tagged from the filename only.

## Download methods

Run the download, then continue to [Shared steps](#shared-steps-run-after-every-download).

### Option A: yt-dlp (default)

```bash
cd /mnt/stash-data/remote/ && nix run nixpkgs#yt-dlp -- -f "bestvideo[ext=mp4]+bestaudio[ext=m4a]/best[ext=mp4]/best" "VIDEO_URL" -o "%(title)s.%(ext)s"
```

Supports URL scraping — run all shared steps, including step 3.

### Option B: gofile.io

```bash
cd /mnt/stash-data/remote/ && bun <skill-path>/scripts/gofile-downloader.ts "GOFILE_URL"
```

If the script prints folder contents instead of downloading, ask the user which file they want — never auto-download all contents without explicit instructions. No URL scraping: skip shared step 3.

### Option C: PMVHaven

1. Resolve the direct MP4 URL: `bun <skill-path>/scripts/pmvhaven-extract.ts "VIDEO_PAGE_URL"`
2. Download it like Option A but **omit `-f`** (the direct MP4 is already best). Rename the file if it downloads with a hashed name.
3. On shared step 3, scrape **title only** — passing `details` or `cover_image` to `sceneUpdate` 422s on PMVHaven, so drop those fields.
4. PMVHaven exposes hashtags on the page. Collect them and add the `pmv` tag, then feed the hashtags into the tag-matching step alongside filename terms:
   ```bash
   curl -s "VIDEO_PAGE_URL" | rg -oP '#\w+'
   bun <skill-path>/scripts/tag-add.ts SCENE_ID "pmv"
   ```

### Option D: MEGA.nz

```bash
cd /mnt/stash-data/remote/ && nix run nixpkgs#megatools -- dl "MEGA_URL"
```

- Auto-resumes partial downloads via `.part` files — re-run the same command if interrupted.
- Downloads to the current directory with its original filename.
- Large files may need long timeouts (>2 min); run directly in the terminal or use a generous timeout.
- No URL scraping: skip shared step 3. Filename inference is the primary way to categorize MEGA downloads.

## Shared steps (run after every download)

### Step 1: Trigger metadata scan

```bash
curl -s -X POST http://localhost:9999/graphql -H "Content-Type: application/json" \
  -d '{"query":"mutation { metadataScan(input: {paths: [\"/data/remote\"], scanGenerateCovers: true, scanGeneratePreviews: true, scanGenerateSprites: true, scanGeneratePhashes: true, scanGenerateThumbnails: true}) }"}'
```

### Step 2: Find the new scene

The scan is asynchronous — the scene may take a moment to appear. Wait a few seconds and retry if it's not there yet.

```bash
curl -s -X POST http://localhost:9999/graphql -H "Content-Type: application/json" \
  -d '{"query":"{ findScenes(filter: { q: \"SEARCH_TERM\" }) { scenes { id title urls } } }"}'
```

### Step 3: Scrape metadata & update scene

**Only for sources that support URL scraping** (Option A; Option C with title only). Skip entirely for gofile.io and MEGA.

Scrapes title/details/image from the URL and writes them back to the scene (along with the source URL) in one shot:

```bash
bun <skill-path>/scripts/scrape-update.ts "VIDEO_URL" SCENE_ID
```

> **PMVHaven (Option C):** add `--title-only` — passing `details` or `cover_image` to `sceneUpdate` 422s on PMVHaven, so the flag scrapes and writes just the title:
>
> ```bash
> bun <skill-path>/scripts/scrape-update.ts --title-only "VIDEO_URL" SCENE_ID
> ```

### Step 4: Tag matching

This is where scenes get categorized. Tags come from two sources that both flow through the same fuzzy-matching workflow:

1. **Scraped metadata** — where step 3 ran, `scrape-update.ts` prints the scraped tag names (as ready-to-paste quoted terms), plus any scraped performers/studio for reference. Feed those tags into the matcher.
2. **Filename inference** — inspect the downloaded filename and pick out meaningful terms, ignoring noise (hashes, timestamps, scene numbers, etc.).

Read `references/tag-matching.md` and follow it.

## When to use me

Use this skill when:

- User pastes a video URL (including gofile.io links and MEGA links)
- User asks to download a video from a site
- User wants to add a new video to their stash library

For gofile.io folder URLs, run the URL through the script first — its output will tell you what to do.
