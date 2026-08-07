# Choosing a Scraper

Stash has ~750 scene scrapers installed. Picking one is a search problem, and
the naive answers are both wrong:

- **Trying them all** is ~373 network calls per scene, and it gets the host IP
  blocked. This already happened: `10Musume-JP` was run against 12 non-10Musume
  scenes, produced 12 garbage URLs, and the site now returns `403 Forbidden` to
  this server for every request — including legitimate ones.
- **Guessing by name** silently produces wrong metadata. A file called
  `gachiPPV-1045-1.wmv` matches the `S1` scraper's ID regex on `1045` and comes
  back with a real, confident, completely unrelated Japanese scene.

Use `scrape-auto.ts`, which walks a precision-ordered ladder and stops at the
first result whose identity is actually proven.

```bash
bun <skill-path>/scripts/scrape-auto.ts 1233              # plan only, no network
bun <skill-path>/scripts/scrape-auto.ts --run 1233        # execute the ladder
bun <skill-path>/scripts/scrape-auto.ts --run --all 1233  # don't stop early
bun <skill-path>/scripts/scrape-auto.ts --json --run 1233 # machine-readable
```

Measured on this library over 15 random scenes: ~7.5 candidates per scene
instead of 373, with 9 resolving to a proven identity, 2 returning only
unconfirmed guesses, and 4 finding nothing. Nearly every confirmed hit comes
from tier 1 — the fingerprint lookup — including scenes with no source URL,
which the URL-classification route can't help with at all.

## The ladder

| Tier | Method | Confidence | Why it sits here |
|---|---|---|---|
| 0 | `scrapeSceneURL` on the scene's own URL | **high** | The scene records where it came from. Stash resolves the scraper from the URL itself — you never name one. |
| 1 | oshash/phash against configured stash-boxes | **high** *(oshash)* / medium *(phash only)* | Identity by content hash — but only an exact **oshash** proves it. See below. Four boxes are configured (stashdb, TPDB, FansDB, PMVStash). |
| 2 | Fragment scrapers whose filename regex matches | medium | An ID derived from the filename. Real, but coincidences happen. Capped at 8, most-selective first. |
| 3 | Fragment scrapers whose name/domain matches path tokens | low | A guess, capped at `--max` (default 5). |
| 4 | `sceneByName` title search on those same candidates | low | A guess, capped. |
| 5 | `Filename` / `FileMetadata` | low | Offline, never fails, near-zero value. Last resort. |

**Only a `high` result ends the search.** Everything else is reported as
`UNCONFIRMED` and must be eyeballed before it's written back — that is the
guard against the `S1` failure mode above.

**Not every stash-box hit is proof.** Stash queries the box with *every*
fingerprint it holds, phash included, and phash is perceptual: re-encodes,
compilations and scenes sharing an intro do collide. So the hit is only
upgraded to `high` when the remote scene's fingerprint list contains one of
*our* oshashes — an exact hash of this exact file. A phash-only hit prints as
`[medium] stashdb (phash)` and `--apply` refuses it, same as a filename guess.

Any cap that trims the plan (tier 2's, or `--max`) prints a `note:` line naming
what it dropped. A short plan is never silently a truncated one.

## The two gates that do the work

**Filename regex gating.** GraphQL's `listScrapers` does not expose a fragment
scraper's query shape, so `scraper-index.ts` parses it out of the scraper YAML.
A fragment scraper whose `{filename}` regex doesn't match the file is
*guaranteed* to build a garbage URL — stash's `queryURLReplace` falls through
silently on a non-match and substitutes the raw filename. This is precisely how
`10Musume-JP` came to request
`.../movie_id/gachiPPV-1045-1.wmv.json`. Gating on the regex removes it.

**Selectivity.** Matching the regex is necessary but not sufficient: many
`queryURLReplace` entries are cleanup rules, not identifiers. `DMM` uses
`\..+$` (strip the extension) and `Xhamster` uses `.*\.[^\.]+$` — both match
every file that exists. The index scores each regex against a sample of real
library filenames and keeps only those that reject ≥70% of it. This is what cut
the plan for scene 1233 from 21 filename candidates to 5.

The sample is drawn with stash's seeded `random_<seed>` sort, so two rebuilds
score the same regexes against the same files — otherwise a scraper sitting
near the threshold flips in and out of tier 2 on every refresh.

Those regexes are Go/RE2 and are re-compiled in JS to evaluate them, which is
lossy: a leading `(?i)` is translated, but named groups (`(?P<id>…)`) and
mid-pattern flags are not. `scraper-index.ts` prints how many regexes it
couldn't compile — that number matters in both directions. A dropped *specific*
regex costs a scraper its gate; a dropped *catch-all* makes a scraper look far
more selective than it is, which is how `Xvideos` and `Xhamster` were passing
as trusted filename gates before their `(?i)` catch-alls could be read.

## Failure memory

`scrape-auto.ts` records failures in `~/.cache/stash-skill/scraper-health.json`
and benches a scraper for 24h after 3 **site-level** failures.

The distinction matters. A `404` means the ID we derived was wrong — a per-scene
miss that says nothing about the scraper, so it is *not* counted. A
`403`/`429`/`5xx`/timeout means the site is refusing this host, which is the
condition that actually warrants backing off.

```bash
bun <skill-path>/scripts/scrape-auto.ts --health          # what's benched
bun <skill-path>/scripts/scrape-auto.ts --unbench JavBus  # clear one
bun <skill-path>/scripts/scrape-auto.ts --unbench         # clear all
```

## The index

```bash
bun <skill-path>/scripts/scraper-index.ts             # stats (builds if stale)
bun <skill-path>/scripts/scraper-index.ts --refresh   # force rebuild
bun <skill-path>/scripts/scraper-index.ts --show S1   # inspect one scraper
```

Cached at `~/.cache/stash-skill/scraper-index.json`, rebuilt after 7 days.

The scraper YAMLs live in a root-owned podman volume
(`/var/lib/containers/storage/volumes/stash-config/_data/scrapers/community`),
so enrichment shells out to `sudo -n cat`. Without sudo the index still builds
from GraphQL alone — it just loses regex gating and selectivity, which
degrades tier 2 rather than breaking it. A full rebuild takes ~1 minute, most
of it sudo round-trips; it only happens on `--refresh` or after 7 days.

## Tests

The pure parts — YAML fragment parsing, regex compilation, selectivity, and
the oshash gate that `--apply` depends on — are covered:

```bash
bun test <skill-path>/scripts/
```

Worth re-running after any upstream scraper-YAML reformat: `parseFragmentBlock`
is a line parser, and when it misreads a rule the symptom isn't a crash, it's a
scraper quietly gaining or losing its filename gate.

## Known-blocked sites

This host is an Oracle Cloud IP (`193.122.9.157`). The DTI network
(`10musume.com`, `1pondo.tv`) and `javlibrary.com` return `403` to it for every
request, browser headers or not. No scraper config fixes an IP-level block —
it needs an exit node or proxy (stash honours `http_proxy`), or those scrapers
should simply stay benched.
