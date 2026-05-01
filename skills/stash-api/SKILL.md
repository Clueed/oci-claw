---
name: stash-api
description: Interact with the Stash API (stashbox/Gamma) for managing scenes, performers, studios, tags, and movies. Use this skill when the user wants to query, create, update, or delete stash objects, or when they mention stash metadata, stash scenes, or interacting with their stash database.
---

# Stash API Skill

Stash API runs at `http://localhost:9999/graphql`.

## Tag References

For tag operations (find, create, update, hierarchy, aliases, orphan cleanup, merge), see [tags.md](./tags.md).
For full GraphQL schema details (filter types, mutation inputs, sort options), see [tags-details.md](./tags-details.md).

## Authentication

Set `STASH_API_KEY` environment variable (from `/run/secrets/stash_api_key`).

## Common Operations

### Find Scenes
```bash
curl -s -X POST http://localhost:9999/graphql -H "Content-Type: application/json" \
  -H "ApiKey: $STASH_API_KEY" \
  -d '{"query":"{ findScenes(filter: { q: \"SEARCH_TERM\" }, scene_filter: {}) { scenes { id title urls paths { webp } } } }"}'
```

### Scrape Scene URL
```bash
curl -s -X POST http://localhost:9999/graphql -H "Content-Type: application/json" \
  -H "ApiKey: $STASH_API_KEY" \
  -d '{"query":"{ scrapeSceneURL(url: \"URL\") { title details date image studio { name } performers { name } tags { name } } }"}'
```

### Update Scene
```bash
curl -s -X POST http://localhost:9999/graphql -H "Content-Type: application/json" \
  -H "ApiKey: $STASH_API_KEY" \
  -d '{"query":"mutation { sceneUpdate(input: {id: \"ID\", title: \"TITLE\", details: \"DETAILS\", urls: [\"URL\"]}) { id } }"}'
```

### Metadata Scan
```bash
curl -s -X POST http://localhost:9999/graphql -H "Content-Type: application/json" \
  -H "ApiKey: $STASH_API_KEY" \
  -d '{"query":"mutation { metadataScan(input: {paths: [\"/data/remote\"], scanGenerateCovers: true}) }"}'
```

### Find Performers
```bash
curl -s -X POST http://localhost:9999/graphql -H "Content-Type: application/json" \
  -H "ApiKey: $STASH_API_KEY" \
  -d '{"query":"{ findPerformers(filter: { q: \"NAME\" }) { performers { id name image } } }"}'
```

### Find Studios
```bash
curl -s -X POST http://localhost:9999/graphql -H "Content-Type: application/json" \
  -H "ApiKey: $STASH_API_KEY" \
  -d '{"query":"{ findStudios(filter: { q: \"NAME\" }) { studios { id name url } } }"}'
```

## When to use me

Use this skill when:
- User wants to query, create, update, or delete stash objects
- User mentions stash metadata, scenes, performers, studios, tags
- User wants to interact with their stash database via GraphQL