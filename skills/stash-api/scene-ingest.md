# Stash Scene Ingest — scan, find, scrape, tag

The pipeline for ingesting a new file into Stash and fully cataloging it. Each step
is a standalone Stash operation; callers (e.g. the `download-video` skill) run
whichever steps apply to their source.

> `<skill-path>` below refers to this skill's absolute directory (where the
> stash-api `SKILL.md` lives). Scripts live at `<skill-path>/scripts/`.

## Step 1: Trigger a metadata scan

Picks up new files on disk. The library path in stash is `/data/remote`.

```bash
curl -s -X POST http://localhost:9999/graphql -H "Content-Type: application/json" \
  -H "ApiKey: $STASH_API_KEY" \
  -d '{"query":"mutation { metadataScan(input: {paths: [\"/data/remote\"], scanGenerateCovers: true, scanGeneratePreviews: true, scanGenerateSprites: true, scanGeneratePhashes: true, scanGenerateThumbnails: true}) }"}'
```

## Step 2: Find the scene

The scan is asynchronous — the scene may take a moment to appear. Wait a few
seconds and retry if it's not there yet.

```bash
curl -s -X POST http://localhost:9999/graphql -H "Content-Type: application/json" \
  -H "ApiKey: $STASH_API_KEY" \
  -d '{"query":"{ findScenes(filter: { q: \"SEARCH_TERM\" }) { scenes { id title urls } } }"}'
```

## Step 3: Scrape metadata & update the scene

Only for sources with a Stash scraper for the URL. Scrapes title/details/date/
image/studio/performers/tags via `scrapeSceneURL` and writes the scalar fields
(plus the source URL) back to the scene in one shot. Tags, performers, and
studio come back as *names*, so they are printed for you rather than applied —
tags then go through [tags-matching.md](./tags-matching.md).

```bash
bun <skill-path>/scripts/scrape-scene.ts "VIDEO_URL" SCENE_ID
```

Some sources 422 when `details`/`cover_image` are passed to `sceneUpdate`
(e.g. PMVHaven). Use `--title-only` there to scrape and write just the title:

```bash
bun <skill-path>/scripts/scrape-scene.ts --title-only "VIDEO_URL" SCENE_ID
```

## Step 4: Tag the scene

All tagging — from scraped metadata or from filename inference — flows through
the same fuzzy-matching workflow. Follow [tags-matching.md](./tags-matching.md).

## Update a scene directly

For fields you already have (no scraping):

```bash
curl -s -X POST http://localhost:9999/graphql -H "Content-Type: application/json" \
  -H "ApiKey: $STASH_API_KEY" \
  -d '{"query":"mutation { sceneUpdate(input: {id: \"ID\", title: \"TITLE\", details: \"DETAILS\", urls: [\"URL\"]}) { id } }"}'
```
