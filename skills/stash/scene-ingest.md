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

**Start here regardless of whether you have a source URL:**

```bash
bun <skill-path>/scripts/scrape-auto.ts --run SCENE_ID
```

This walks the scraper ladder in [scrapers.md](./scrapers.md) — source URL
first, then an oshash/phash lookup against the stash-boxes, then narrower
fallbacks — and prints what each returned.

- **`CONFIRMED`** — identity is proven. Re-run with `--apply` to write the
  scalar fields; tags/performers/studio are printed for Steps 4–6 as usual.
- **`UNCONFIRMED`** — a plausible but unproven match. Treat it as a *hint* for
  Steps 4–6, never as truth. `--apply` deliberately refuses these.
- **nothing** — fall through to the URL table below, then to filename tagging.

This matters most for the `none` rows in the table: a gofile/MEGA link or a
scene with no URL at all has no scraper, but its **fingerprint** is often still
known to a stash-box. That path only exists because Step 1 scans with
`scanGeneratePhashes: true` — so don't skip it.

If it resolves the scene, Steps 4–6 still apply; the title casing rule below
still applies too.

### Scraping from a source URL

If you do have a source URL and want to drive the scrape from it directly,
classify the URL against this table:

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

For `none`, there is no Stash scraper for the URL. If the fingerprint lookup at
the top of this step didn't resolve it either, skip to Step 4 and tag from the
filename.

### Title casing

Every scene title must be in **Title Case** — capitalize the first letter of
each significant word (minor words like `a`, `an`, `the`, `and`, `or`, `of`,
`in`, `on`, `to` stay lowercase unless they're the first or last word).
Abbreviations stay **UPPER CASE** (e.g. `A2M`, `POV`, `MILF`, `BBC`, `DP`).

The scrape writes the source title verbatim, so after any scrape (Step 3) check
the written title and re-normalize it with a direct `sceneUpdate` (see below) if
it isn't already Title Case with upper-case abbreviations. The same rule applies
to any title you set from the filename or other context.

## Step 4: Tag the scene

Tag the scene by following [tags-matching.md](./tags-matching.md). Feed it the tags
the Step 3 scrape returned as well as all other context (filename, source page, user input).

## Step 5: Attach performers

Performer names come from the Step 3 scrape (printed, never auto-applied) or from
other context (filename, source page). Match them against the performer DB,
attach exact matches, and confirm the rest with the user — including whether to
create a performer that doesn't exist yet. Follow
[performers-matching.md](./performers-matching.md).

## Step 6: Attach the studio

Attach the studio by following [studios-matching.md](./studios-matching.md).
Feed it the studio the Step 3 scrape returned as well as all other context
(filename, source page, user input).

## Update a scene directly

For fields you already have (no scraping):

```bash
curl -s -X POST http://localhost:9999/graphql -H "Content-Type: application/json" \
  -d '{"query":"mutation { sceneUpdate(input: {id: \"ID\", title: \"TITLE\", details: \"DETAILS\", urls: [\"URL\"]}) { id } }"}'
```
