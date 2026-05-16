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

```bash
curl -s -X POST http://localhost:9999/graphql -H "Content-Type: application/json" \
  -d '{"query":"{ findScenes(filter: { q: \"SEARCH_TERM\" }) { scenes { id title urls } } }"}'
```

#### Step 4: Scrape Metadata from URL

```bash
curl -s -X POST http://localhost:9999/graphql -H "Content-Type: application/json" \
  -d '{"query":"{ scrapeSceneURL(url: \"VIDEO_URL\") { title details date image studio { name } performers { name } tags { name } } }"}'
```

#### Step 5: Update the Scene

```bash
curl -s -X POST http://localhost:9999/graphql -H "Content-Type: application/json" \
  -d '{"query":"mutation { sceneUpdate(input: {id: \"SCENE_ID\", title: \"TITLE\", details: \"DETAILS\", urls: [\"VIDEO_URL\"]}) { id } }"}'
```

#### Step 6: Set Cover Image

```bash
curl -s -X POST http://localhost:9999/graphql -H "Content-Type: application/json" \
  -d '{"query":"{ scrapeSceneURL(url: \"VIDEO_URL\") { image } }"}' > /tmp/scrape_result.json
nix run nixpkgs#python3 << 'EOF'
import json
with open('/tmp/scrape_result.json') as f:
    data = json.load(f)
image = data['data']['scrapeSceneURL']['image']
mutation = {"query": f'mutation {{ sceneUpdate(input: {{id: "SCENE_ID", cover_image: "{image}"}}) {{ id }} }}'}
with open('/tmp/mutation.json', 'w') as f:
    json.dump(mutation, f)
EOF
curl -s -X POST http://localhost:9999/graphql -H "Content-Type: application/json" -d @/tmp/mutation.json
```

### Option B: gofile.io

For gofile.io links, the script is bundled at `gofile-downloader.ts` in this directory. No scraping or URL tagging is needed.

#### Step 1: Download

```bash
cd /mnt/stash-data/remote/ && bun /home/claw/nixos/skills/download-video/gofile-downloader.ts "GOFILE_URL"
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

## When to use me

Use this skill when:
- User pastes a video URL (including gofile.io links)
- User asks to download a video from a site
- User wants to add a new video to their stash library
