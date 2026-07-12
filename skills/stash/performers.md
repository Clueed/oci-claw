# Performer Creation & Enrichment

How to flesh out a performer's metadata (aliases, birthdate, physical
attributes, images, URLs, stash_ids, …) after they exist in the DB.

> This is about **enriching a performer record**. For attaching performers to a
> scene during ingest (fuzzy match + confirm + attach), see
> [performers-matching.md](./performers-matching.md).

> `<skill-path>` below refers to this skill's absolute directory (where the
> stash `SKILL.md` lives). Scripts live at `<skill-path>/scripts/`.

The `scrape-performer.ts` script has two modes:

- **Scrape (preview)** — `scrape-performer.ts <local-id>` looks up the local
  performer's name, queries every configured stash-box endpoint, prints each
  candidate as `<hostname>/<remote_id>`, and then web-scrapes any URL those
  candidates carry. Nothing is written.
- **Apply (write)** — `scrape-performer.ts <local-id> --apply <hostname>/<remote_id>`
  re-fetches that one candidate, prints a field-by-field diff, and writes it
  (merging aliases/urls, setting the stash_id).

## Step 1: Scrape the performer

Run the script against the local performer id to preview what's available:

```bash
bun <skill-path>/scripts/scrape-performer.ts LOCAL_ID
```

## Step 2: If there are results, let the user pick

Each candidate is printed with its `<hostname>/<remote_id>` header. Present the
candidates to the user and let them pick the correct one (or none). Then apply
that choice with the same script:

```bash
bun <skill-path>/scripts/scrape-performer.ts LOCAL_ID --apply stashdb.org/REMOTE_ID
```

The apply run prints the diff and writes it. Report the applied changes back to
the user.

## Step 3: If there are no results, find URLs by web search

When no stash-box endpoint returns a match, web-search for the performer's own
pages so the URL scraper has something to work with. Look for:

- OnlyFans
- ManyVids
- Scatbook
- Twitter / X

Present the URLs you find to the user and ask them to confirm they belong to the
right performer. **Do not add anything without confirmation.**

## Step 4: Add a confirmed URL and re-scrape

Once the user confirms a URL is correct, add it to the performer manually
(`performerUpdate` — merge with any existing urls first):

```bash
curl -s -X POST http://localhost:9999/graphql -H "Content-Type: application/json" \
  -d '{"query":"mutation { performerUpdate(input: {id: \"LOCAL_ID\", urls: [\"EXISTING_URL\", \"CONFIRMED_URL\"]}) { id urls } }"}'
```

Then run the scraper again — it will web-scrape the performer's URLs and print
what it finds:

```bash
bun <skill-path>/scripts/scrape-performer.ts LOCAL_ID
```

Tell the user the scraped results. If they're good, apply them the same way as
Step 2.

Environment variable `STASH_URL` (default `http://localhost:9999/graphql`) can
override the endpoint.
