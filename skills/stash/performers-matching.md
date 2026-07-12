# Performer Matching

Attach performer(s) to a scene. Performer names come from two sources:

1. **Scraped metadata** — performers printed by `scrape-scene.ts` (Step 3 of
   [scene-ingest.md](./scene-ingest.md)); they come back as _names_, never applied.
2. **Other context** — the filename, the source page, or the user.

If there is **no performer information from any source** and you cannot infer one,
**ask the user** rather than guessing.

## Step 1: Fuzzy match each name

Run the finder for each candidate name. It prints `<score>  <id>  <name>` per
match (≥ 0.7), best first — nothing is applied.

```bash
bun <skill-path>/scripts/match-performer.ts "Malafalda"
```

## Step 2: Decide per name

- **Exact match** (score `1.00`) → that's the performer; note its `id`.
- **Ambiguous** (several near matches, or top score < 1.00) → present the
  candidates and **ask the user** which one, or none.
- **No match** → the performer is not in the DB yet. If you are **confident about
  who the performer is** (clear name from the scrape or the source page), **ask
  the user whether to create a new performer** (Step 4). If you are unsure, ask
  the user how to proceed instead of creating anything.

**Do not create a performer or attach one without user confirmation** except when
Step 2 yields an exact `1.00` match.

## Step 3: Attach to the scene

`performer_ids` on `sceneUpdate` replaces the full list, so merge with the
existing performers first.

```bash
# fetch current performer ids
curl -s -X POST http://localhost:9999/graphql -H "Content-Type: application/json" \
  -d '{"query":"{ findScene(id: \"SCENE_ID\") { performers { id } } }"}'

# write the merged set (existing + new)
curl -s -X POST http://localhost:9999/graphql -H "Content-Type: application/json" \
  -d '{"query":"mutation { sceneUpdate(input: {id: \"SCENE_ID\", performer_ids: [\"EXISTING_ID\", \"NEW_ID\"]}) { id performers { id name } } }"}'
```

## Step 4: Create a new performer (only if approved)

```bash
curl -s -X POST http://localhost:9999/graphql -H "Content-Type: application/json" \
  -d '{"query":"mutation { performerCreate(input: {name: \"PERFORMER_NAME\"}) { id name } }"}'
```

Then attach the returned `id` via Step 3.

Environment variable `STASH_URL` (default `http://localhost:9999/graphql`) can
override the endpoint.
