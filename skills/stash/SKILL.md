---
name: stash
description: Interact with the Stash API (stashbox/Gamma) for managing scenes, performers, studios, tags, and groups. Use this skill when the user wants to query, create, update, or delete stash objects, when they mention stash metadata/scenes/performers/studios/tags.
---

# Stash API Skill

Stash API runs at `http://localhost:9999/graphql`.

> `<skill-path>` below refers to this skill's absolute directory path (where this SKILL.md lives). Runnable scripts live at `<skill-path>/scripts/`.

## Ingesting a new scene

**If a new file was just added to the library and needs cataloging** (e.g. handed off from the download-video skill after a download), read **[scene-ingest.md](./scene-ingest.md)** and follow it end-to-end.

## Choosing a scraper

**Never guess a scraper id, and never loop over many scrapers.** With ~750
installed, guessing produces wrong metadata and gets the host IP blocked. Read
**[scrapers.md](./scrapers.md)** and use `scrape-auto.ts`, which ranks the
handful of scrapers that can actually match a scene and only trusts results
whose identity is proven (source URL or fingerprint).

## Tag References

For the tagging workflow (fuzzy match, alias rules, auto-apply via scripts), see [tags-matching.md](./tags-matching.md).
For tag operations (find, create, update, hierarchy, aliases, orphan cleanup, merge), see [tags.md](./tags.md).
For full GraphQL schema details (filter types, mutation inputs, sort options), see [tags-details.md](./tags-details.md).
For tag naming/alias/hierarchy conventions, see [tags-rules.md](./tags-rules.md).

## Performer References

For enriching a performer record (stash-box/URL scrape, apply, web-search fallback), see [performers.md](./performers.md).
For matching/attaching performers to a scene during ingest, see [performers-matching.md](./performers-matching.md).

## Scripts

Runnable helpers at `<skill-path>/scripts/` (all default to `STASH_URL=http://localhost:9999/graphql`):

- `bun <skill-path>/scripts/scrape-auto.ts [--run] [--all] [--json] <scene-id>` — pick and run the right scrapers for a scene via a precision-ordered ladder (URL → fingerprint → filename regex → guesses). Without `--run` it only prints the plan. Also `--health` / `--unbench`. See [scrapers.md](./scrapers.md).
- `bun <skill-path>/scripts/scraper-index.ts [--refresh|--show <id>]` — build/inspect the index of installed scrapers (URL patterns, fragment regexes, selectivity) used by `scrape-auto.ts`.
- `bun <skill-path>/scripts/scrape-scene.ts <url> <scene-id> [--title-only]` — scrape a source URL via `scrapeSceneURL` and write scalar fields back; prints scraped tags/performers/studio.
- `bun <skill-path>/scripts/match-tag.ts [--apply <scene-id>] <terms...>` — fuzzy-match terms against the tag DB; `--apply` auto-adds exact matches.
- `bun <skill-path>/scripts/create-tag.ts <scene-id> <names...>` — add tags to a scene by name (fuzzy-matched, idempotent).
- `bun <skill-path>/scripts/create-tag-alias.ts "<tag-name>" "<alias>"` — idempotently add one alias to a tag.
- `bun <skill-path>/scripts/match-performer.ts <name>` — fuzzy-match a name against the performer DB; prints `<score>  <name>` per match.
- `bun <skill-path>/scripts/scrape-performer.ts <local-id> [--apply <hostname>/<remote_id>]` — scrape a local performer from stash-box endpoints and their own URLs (preview); `--apply` writes one chosen candidate. See [performers.md](./performers.md).
