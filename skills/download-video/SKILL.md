---
name: download-video
description: Download videos from URLs (thisvid.com, gofile.io, porn sites, etc.) using yt-dlp or gofile-downloader, scan them into stash, scrape metadata, and update the scene with title, details, tags, and cover image. Use this skill whenever a user pastes a video URL or asks to download a video from a site.
---

# Download Video Skill

This skill downloads videos from URLs using yt-dlp, adds them to the stash video library, scrapes metadata, and updates the scene with all available information.

## Prerequisites

- yt-dlp is available via `nix run nixpkgs#yt-dlp`
- Stash API is running on localhost:9999
- The video library path in stash is `/data/remote` (mounted at `/mnt/stash-data/remote/` on the host)

> `<skill-path>` below refers to this skill's absolute directory path (where this SKILL.md lives).

## Workflow

### Option A: yt-dlp (default)

#### Step 1: Download the Video

```bash
cd /mnt/stash-data/remote/ && nix run nixpkgs#yt-dlp -- -f "bestvideo[ext=mp4]+bestaudio[ext=m4a]/best[ext=mp4]/best" "VIDEO_URL" -o "%(title)s.%(ext)s"
```

#### Step 2: Trigger Metadata Scan

```bash
curl -s -X POST http://localhost:9999/graphql -H "Content-Type: application/json" \
  -d '{"query":"mutation { metadataScan(input: {paths: [\"/data/remote\"], scanGenerateCovers: true, scanGeneratePreviews: true, scanGenerateSprites: true, scanGeneratePhashes: true, scanGenerateThumbnails: true}) }"}'
```

#### Step 3: Find the New Scene

The scan is asynchronous — the scene may take a moment to appear. You may need to wait a few seconds and retry.

```bash
curl -s -X POST http://localhost:9999/graphql -H "Content-Type: application/json" \
  -d '{"query":"{ findScenes(filter: { q: \"SEARCH_TERM\" }) { scenes { id title urls } } }"}'
```

#### Steps 4-6: Scrape Metadata & Update Scene (combined)

Scrapes title/details/image from the URL and updates the scene in one shot using Python to safely build the JSON.

```bash
nix run nixpkgs#python3 << 'EOF'
import json, urllib.request

VIDEO_URL = "VIDEO_URL"
SCENE_ID = "SCENE_ID"

# Scrape metadata
query = {"query": '{ scrapeSceneURL(url: "' + VIDEO_URL + '") { title details image } }'}
req = urllib.request.Request("http://localhost:9999/graphql", data=json.dumps(query).encode(), headers={"Content-Type": "application/json"})
resp = json.loads(urllib.request.urlopen(req).read().decode())
scraped = resp["data"]["scrapeSceneURL"]

# Build update mutation with proper JSON escaping
update = {
    "query": "mutation { sceneUpdate(input: {id: \"" + SCENE_ID + "\", title: $title, details: $details, urls: [\"" + VIDEO_URL + "\"], cover_image: $image}) { id } }",
    "variables": {
        "title": scraped["title"],
        "details": scraped["details"],
        "image": scraped["image"]
    }
}

req2 = urllib.request.Request("http://localhost:9999/graphql", data=json.dumps(update).encode(), headers={"Content-Type": "application/json"})
result = json.loads(urllib.request.urlopen(req2).read().decode())
print(json.dumps(result, indent=2))
EOF
```

#### Step 7: Infer Tags from Filename

Manually inspect the downloaded filename and pick out meaningful terms, ignoring noise (hashes, timestamps, scene numbers, etc.). Run fuzzy matching on the relevant terms:

```bash
bun <skill-path>/scripts/tag-fuzzy.ts --apply SCENE_ID --pretty "puke" "pmv"
```

### Option B: gofile.io

For gofile.io links, the script is bundled at `scripts/gofile-downloader.ts`. No scraping or URL tagging is needed.

#### Step 1: Download

Just run the URL through the script. If it prints folder contents, ask the user which file to download — never auto-download all contents without explicit instructions.

```bash
cd /mnt/stash-data/remote/ && bun <skill-path>/scripts/gofile-downloader.ts "GOFILE_URL"
```

#### Step 2: Trigger Metadata Scan

```bash
curl -s -X POST http://localhost:9999/graphql -H "Content-Type: application/json" \
  -d '{"query":"mutation { metadataScan(input: {paths: [\"/data/remote\"], scanGenerateCovers: true, scanGeneratePreviews: true, scanGenerateSprites: true, scanGeneratePhashes: true, scanGenerateThumbnails: true}) }"}'
```

#### Step 3: Find the New Scene

```bash
curl -s -X POST http://localhost:9999/graphql -H "Content-Type: application/json" \
  -d '{"query":"{ findScenes(filter: { q: \"SEARCH_TERM\" }) { scenes { id title } } }"}'
```

#### Step 4: Infer Tags from Filename

Manually inspect the downloaded filename and pick out meaningful terms, ignoring noise. Then:

```bash
bun <skill-path>/scripts/tag-fuzzy.ts --apply SCENE_ID --pretty "term1" "term2"
```

### Option C: PMVHaven

1. Run `<skill-path>/scripts/pmvhaven-extract.ts <VIDEO_PAGE_URL>` to get the MP4 URL.
2. Download as Option A but **omit `-f`** — the direct MP4 is best. Rename if hashed.
3. Scan + find + update as Option A, but skip `details` and `cover_image` (causes 422).
4. Extract hashtags with `curl -s "$VIDEO_PAGE" | rg -oP '#\w+'`, then `tag-fuzzy.ts --apply`, then `tag-add.ts pmv`.
5. Infer Tags from Filename: manually pick meaningful terms from the filename, ignoring noise, then `tag-fuzzy.ts --apply --pretty`.

## Step 6: Tag Matching

Now proceed to tag matching. Read `references/tag-matching.md` and follow the workflow to fuzzy-match scraped tags and filename-inferred tags, suggest mappings, get user approval, and apply them.

## When to use me

Use this skill when:
- User pastes a video URL (including gofile.io links)
- User asks to download a video from a site
- User wants to add a new video to their stash library

For gofile.io folder URLs, run the URL through the script first — its output will tell you what to do.
