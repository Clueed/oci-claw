# Tag Matching

> **NEVER create/edit tag aliases manually in the Stash UI. Always use the `tag-add-alias.ts` script.**
> See instructions at the end of this file.

## Step 1: Fuzzy match & auto-apply (default)

Always run with `--apply <scene-id>` to auto-add exact-matching tags. Non-direct matches are returned as `pending` for manual review.

```bash
bun run <skill-path>/scripts/tag-fuzzy.ts --apply <scene-id> "blowjob" "anal" "ass fucking"
```

For human-readable output, add `--pretty`:

```bash
bun run <skill-path>/scripts/tag-fuzzy.ts --apply <scene-id> --pretty "blowjob" "anal" "ass fucking"
```

Output: `{auto_applied: [{name, scraped}], pending: [{scraped, matches}]}`

Tags in `auto_applied` are exact matches (score 1.0) already added to the scene — no further action needed.

## Step 2: Build a tag suggestion list from `pending`

Present the user with a proposed mapping of each `pending` scraped tag → Stash tag, applying these rules in order. Use the format:

```
<scraped> -> <target> (<reason>)
```

**Do not proceed to apply tags without user approval.**

### Rule 1: Direct match (case-insensitive)
If the scraped tag matches a Stash tag name exactly (case-insensitive), use `(direct)`.

| Scraped | Suggestion |
|---|---|
| anal fucking | anal fucking -> anal fucking (direct) |
| blowjob | blowjob -> blowjob (direct) |
| kissing | kissing -> kissing (direct) |

### Rule 2: Known synonym → create alias
Map synonymous terms to a canonical Stash tag and add the synonym as an alias.

| Synonym(s) | Suggestion |
|---|---|
| ass fucking | ass fucking -> anal fucking (create alias) |
| deep throat, deepthroat | deep throat -> blowjob (create alias) |
| cunnilingus | cunnilingus -> pussy licking (create alias) |
| pussy eating | pussy eating -> pussy licking (create alias) |

### Rule 3: Spelling/spacing variant → create alias
When the scraped tag is a minor spelling or spacing variation of an existing tag, add it as an alias.

| Scraped | Suggestion | Alias to add |
|---|---|---|
| dick sucking | dick sucking -> blowjob (create alias) | "dick sucking" |
| dirty talking | dirty talking -> dirty talk (create alias) | "dirty talking" |
| face sitting | face sitting -> facesitting (create alias) | "face sitting" |

### Rule 4: Unmatched → skip
Show as `<scraped> -> (skip)`. No tag created, no alias added.

## Step 3: Apply approved tags to scene

Once the user approves pending mappings, add them to the scene by name:

```bash
bun run <skill-path>/scripts/tag-add.ts <scene-id> "ass fucking" "dirty talk"
```

The script fuzzy-matches each name against your Stash tag DB and adds them idempotently.

---

## Adding Aliases (via script)

When a scraped tag needs a new alias on an existing Stash tag (Rules 2-3), **always** use:

```bash
bun run <skill-path>/scripts/tag-add-alias.ts "<tag-name>" "<alias>"
```

The script looks up the tag by name, fetches current aliases, and adds the new one (idempotent — no-op if already exists). One alias per invocation.

Environment variable `STASH_URL` (default `http://localhost:9999/graphql`) can override the endpoint.
