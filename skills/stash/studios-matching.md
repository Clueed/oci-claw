# Studio Matching

Attach a studio to a scene. A scene has **exactly one** studio. The studio name
comes from two sources:

1. **Scraped metadata** — the studio printed by `scrape-scene.ts` (Step 3 of
   [scene-ingest.md](./scene-ingest.md)); it comes back as a _name_, never applied.
2. **Other context** — the filename, the source page, or the user.

If there is **no studio information from any source** and you cannot infer one,
**ask the user** rather than guessing.

## Step 1: Fuzzy match the name

Run the finder for the candidate studio name. It prints `<score>  <id>  <name>`
per match (≥ 0.7), best first — nothing is applied.

```bash
bun <skill-path>/scripts/match-studio.ts "Brazzers"
```

**Always also check performers.** For amateur studios especially, the studio is
often named after the performer (e.g. a solo creator uploads under their own
name). So run the performer finder on the same name too and treat a performer
hit as a strong signal that a same-named studio should exist:

```bash
bun <skill-path>/scripts/match-performer.ts "Brazzers"
```

## Step 2: Decide

- **Exact studio match** (score `1.00`) → that's the studio; note its `id`.
- **Ambiguous** (several near matches, or top score < 1.00) → present the
  candidates and **ask the user** which one, or none.
- **No studio match, but a performer of the same name exists** → the studio is
  likely this creator publishing under their own name. **Ask the user whether to
  create a studio with that name** (Step 4).
- **No match anywhere** → the studio is not in the DB yet. If you are **confident
  about the studio** (clear name from the scrape or the source page), **ask the
  user whether to create a new studio** (Step 4). If unsure, ask how to proceed
  instead of creating anything.

**Do not create a studio or attach one without user confirmation** except when
Step 1 yields an exact `1.00` studio match.

## Step 3: Attach to the scene

`studio_id` on `sceneUpdate` sets the scene's single studio (no merging needed —
it replaces whatever was there).

```bash
curl -s -X POST http://localhost:9999/graphql -H "Content-Type: application/json" \
  -d '{"query":"mutation { sceneUpdate(input: {id: \"SCENE_ID\", studio_id: \"STUDIO_ID\"}) { id studio { id name } } }"}'
```

## Step 4: Create a new studio (only if approved)

```bash
curl -s -X POST http://localhost:9999/graphql -H "Content-Type: application/json" \
  -d '{"query":"mutation { studioCreate(input: {name: \"STUDIO_NAME\"}) { id name } }"}'
```

Then attach the returned `id` via Step 3.

Environment variable `STASH_URL` (default `http://localhost:9999/graphql`) can
override the endpoint.
