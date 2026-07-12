# Stash Scene Ingest — scan, find, scrape, tag

The pipeline for ingesting a new file into Stash and fully cataloging it.

> `<skill-path>` below refers to this skill's absolute directory (where the
> stash `SKILL.md` lives). Scripts live at `<skill-path>/scripts/`.

## Step 1: Trigger a metadata scan

Picks up new files on disk. The library path in stash is `/data/remote`.

```bash
curl -s -X POST http://localhost:9999/graphql -H "Content-Type: application/json" \
  -d '{"query":"mutation { metadataScan(input: {paths: [\"/data/remote\"], scanGenerateCovers: true, scanGeneratePreviews: true, scanGenerateSprites: true, scanGeneratePhashes: true, scanGenerateThumbnails: true}) }"}'
```

## Step 2: Find the scene

The scan is asynchronous — the scene may take a moment to appear. Wait a few
seconds and retry if it's not there yet.

```bash
curl -s -X POST http://localhost:9999/graphql -H "Content-Type: application/json" \
  -d '{"query":"{ findScenes(filter: { q: \"SEARCH_TERM\" }) { scenes { id title urls } } }"}'
```

## Step 3: Scrape metadata & update the scene

Whether a source URL can be scraped — and how much of it can be written back — is
determined here, from the URL alone. Classify the URL against this table:

| Source                                      | Scrape support | How to scrape                           |
| ------------------------------------------- | -------------- | --------------------------------------- |
| Most sites / porn sites (thisvid.com, etc.) | `full`         | `scrape-scene.ts "URL" ID`              |
| PMVHaven pages                              | `title-only`   | `scrape-scene.ts --title-only "URL" ID` |
| gofile.io links                             | `none`         | skip this step — tag from filename      |
| MEGA.nz links (`mega.nz/file/...`)          | `none`         | skip this step — tag from filename      |
| No source URL                               | `none`         | skip this step — tag from filename      |

For `full`, scrape the whole field set (title/details/date/image/studio/
performers/tags) via `scrapeSceneURL` and write the scalar fields (plus the
source URL) back in one shot. Tags, performers, and studio come back as _names_,
so they are printed for you rather than applied — tags then go through
[tags-matching.md](./tags-matching.md).

```bash
bun <skill-path>/scripts/scrape-scene.ts "VIDEO_URL" SCENE_ID
```

For `title-only`, scrape and write just the title. PMVHaven 422s when
`details`/`cover_image` are passed to `sceneUpdate`, so it must use this mode:

```bash
bun <skill-path>/scripts/scrape-scene.ts --title-only "VIDEO_URL" SCENE_ID
```

For `none`, there is no Stash scraper for the URL — skip straight to Step 4 and
tag from the filename.

## Step 4: Tag the scene

All tagging — from scraped metadata or from filename inference — flows through
the same fuzzy-matching workflow. Follow [tags-matching.md](./tags-matching.md).

## Update a scene directly

For fields you already have (no scraping):

```bash
curl -s -X POST http://localhost:9999/graphql -H "Content-Type: application/json" \
  -d '{"query":"mutation { sceneUpdate(input: {id: \"ID\", title: \"TITLE\", details: \"DETAILS\", urls: [\"URL\"]}) { id } }"}'
```
