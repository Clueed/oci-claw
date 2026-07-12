---
name: stash-api
description: Interact with the Stash API (stashbox/Gamma) for managing scenes, performers, studios, tags, and movies. Owns the scene-cataloging pipeline (metadata scan, find, URL scrape, tag) and the tag-matching workflow/scripts. Use this skill when the user wants to query, create, update, or delete stash objects, when they mention stash metadata/scenes/performers/studios/tags, or when another skill (e.g. download-video) needs to scan, scrape, or tag a scene.
---

# Stash API Skill

Stash API runs at `http://localhost:9999/graphql`.

> `<skill-path>` below refers to this skill's absolute directory path (where this SKILL.md lives). Runnable scripts live at `<skill-path>/scripts/`.

## Ingesting a new scene

**If a new file was just added to the library and needs cataloging** (e.g. handed off from the download-video skill after a download), read **[scene-ingest.md](./scene-ingest.md)** and follow it end-to-end.

## Tag References

For the tagging workflow (fuzzy match, alias rules, auto-apply via scripts), see [tags-matching.md](./tags-matching.md).
For tag operations (find, create, update, hierarchy, aliases, orphan cleanup, merge), see [tags.md](./tags.md).
For full GraphQL schema details (filter types, mutation inputs, sort options), see [tags-details.md](./tags-details.md).
For tag naming/alias/hierarchy conventions, see [tags-rules.md](./tags-rules.md).

## Scripts

Runnable helpers at `<skill-path>/scripts/` (all default to `STASH_URL=http://localhost:9999/graphql`):

- `scrape-scene.ts <url> <scene-id> [--title-only]` — scrape a source URL via `scrapeSceneURL` and write scalar fields back; prints scraped tags/performers/studio.
- `match-tag.ts [--apply <scene-id>] <terms...>` — fuzzy-match terms against the tag DB; `--apply` auto-adds exact matches.
- `create-tag.ts <scene-id> <names...>` — add tags to a scene by name (fuzzy-matched, idempotent).
- `create-tag-alias.ts "<tag-name>" "<alias>"` — idempotently add one alias to a tag.


## When to use me

Use this skill when:

- User wants to query, create, update, or delete stash objects
- User mentions stash metadata, scenes, performers, studios, tags
- User wants to interact with their stash database via GraphQL
