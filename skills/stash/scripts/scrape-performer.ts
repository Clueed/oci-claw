#!/usr/bin/env bun

/**
 * Performer Scrape — stash-box scrape & apply for local performers.
 *
 * Mode 1 — Scrape (preview):
 *   bun scrape-performer.ts          (prompts for local performer ID)
 *   bun scrape-performer.ts 123      (looks up name, scrapes all stash-box endpoints)
 *
 * Mode 2 — Apply (write):
 *   bun scrape-performer.ts 123 --apply stashdb.org/d897c5e9-...
 *
 * Environment:
 *   STASH_URL   default: http://localhost:9999/graphql
 */

const STASH = process.env.STASH_URL || "http://localhost:9999/graphql";

interface ScrapedPerformer {
  name?: string | null;
  aliases?: string | null;
  gender?: string | null;
  birthdate?: string | null;
  ethnicity?: string | null;
  country?: string | null;
  eye_color?: string | null;
  hair_color?: string | null;
  height?: string | null;
  measurements?: string | null;
  fake_tits?: string | null;
  penis_length?: string | null;
  circumcised?: string | null;
  career_start?: string | null;
  career_end?: string | null;
  tattoos?: string | null;
  piercings?: string | null;
  details?: string | null;
  death_date?: string | null;
  weight?: string | null;
  url?: string | null;
  urls?: string[] | null;
  images?: string[] | null;
  tags?: { name?: string | null }[] | null;
  remote_site_id?: string | null;
  stored_id?: string | null;
}

interface LocalPerformer {
  id: string;
  name: string;
  alias_list?: string[] | null;
  gender?: string | null;
  birthdate?: string | null;
  ethnicity?: string | null;
  country?: string | null;
  eye_color?: string | null;
  hair_color?: string | null;
  height_cm?: number | null;
  measurements?: string | null;
  fake_tits?: string | null;
  penis_length?: string | null;
  circumcised?: string | null;
  career_start?: string | null;
  career_end?: string | null;
  tattoos?: string | null;
  piercings?: string | null;
  details?: string | null;
  death_date?: string | null;
  weight?: number | null;
  urls?: string[] | null;
  image_path?: string | null;
  stash_ids?: { endpoint: string; stash_id: string }[] | null;
}

async function gql<T>(query: string, vars?: Record<string, unknown>): Promise<T> {
  const res = await fetch(STASH, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ query, variables: vars }),
  });
  const json: any = await res.json();
  if (json.errors) {
    throw new Error(json.errors.map((e: any) => e.message).join("; "));
  }
  return json.data as T;
}

function printPerformer(label: string, p: ScrapedPerformer): void {
  console.log(`\n${label}:`);
  console.log(`  name:        ${p.name}`);
  if (p.aliases)      console.log(`  aliases:     ${p.aliases}`);
  if (p.gender)       console.log(`  gender:      ${p.gender}`);
  if (p.birthdate)    console.log(`  birthdate:   ${p.birthdate}`);
  if (p.ethnicity)    console.log(`  ethnicity:   ${p.ethnicity}`);
  if (p.country)      console.log(`  country:     ${p.country}`);
  if (p.eye_color)    console.log(`  eye_color:   ${p.eye_color}`);
  if (p.hair_color)   console.log(`  hair_color:  ${p.hair_color}`);
  if (p.height)       console.log(`  height:      ${p.height}`);
  if (p.measurements) console.log(`  measurements:${p.measurements}`);
  if (p.fake_tits)    console.log(`  fake_tits:   ${p.fake_tits}`);
  if (p.penis_length) console.log(`  penis_length:${p.penis_length}`);
  if (p.circumcised)  console.log(`  circumcised: ${p.circumcised}`);
  if (p.career_start) console.log(`  career_start:${p.career_start}`);
  if (p.career_end)   console.log(`  career_end:  ${p.career_end}`);
  if (p.tattoos)      console.log(`  tattoos:     ${p.tattoos}`);
  if (p.piercings)    console.log(`  piercings:   ${p.piercings}`);
  if (p.details)      console.log(`  details:     ${p.details}`);
  if (p.death_date)   console.log(`  death_date:  ${p.death_date}`);
  if (p.weight)       console.log(`  weight:      ${p.weight}`);
  if (p.url)          console.log(`  url:         ${p.url}`);
  if (p.urls?.length) console.log(`  urls:        ${p.urls.join(", ")}`);
  if (p.remote_site_id) console.log(`  remote_id:   ${p.remote_site_id}`);
  if (p.stored_id)    console.log(`  stored_id:   ${p.stored_id}`);
  if (p.tags?.length) console.log(`  tags:        ${p.tags.map(t => t.name).join(", ")}`);
  console.log();
}

function mapScrapedToInput(
  r: ScrapedPerformer,
  local: LocalPerformer,
): Record<string, unknown> {
  const input: Record<string, unknown> = { id: local.id };

  if (r.name)                input.name = r.name;
  if (r.aliases) {
    const scraped = r.aliases.split(/,\s*/).map(a => a.trim()).filter(Boolean);
    input.alias_list = [...new Set([...(local.alias_list ?? []), ...scraped])];
  }
  if (r.gender)              input.gender = r.gender;
  if (r.birthdate)           input.birthdate = r.birthdate;
  if (r.ethnicity)           input.ethnicity = r.ethnicity;
  if (r.country)             input.country = r.country;
  if (r.eye_color)           input.eye_color = r.eye_color;
  if (r.hair_color)          input.hair_color = r.hair_color;
  if (r.height != null)      input.height_cm = parseInt(r.height, 10) || undefined;
  if (r.measurements)        input.measurements = r.measurements;
  if (r.fake_tits)           input.fake_tits = r.fake_tits;
  if (r.penis_length)        input.penis_length = r.penis_length;
  if (r.circumcised)         input.circumcised = r.circumcised;
  if (r.career_start)        input.career_start = r.career_start;
  if (r.career_end)          input.career_end = r.career_end;
  if (r.tattoos)             input.tattoos = r.tattoos;
  if (r.piercings)           input.piercings = r.piercings;
  if (r.details)             input.details = r.details;
  if (r.death_date)          input.death_date = r.death_date;
  if (r.weight != null)      input.weight = parseInt(r.weight, 10) || undefined;
  if (r.urls?.length)        input.urls = [...new Set([...(local.urls ?? []), ...r.urls])];
  if (r.images?.[0])         input.image = r.images[0];

  return input;
}

function printDiff(input: Record<string, unknown>, local: LocalPerformer): void {
  console.log("\nChanges to apply:\n");

  const fieldMap: Record<string, string> = {
    alias_list: "alias_list",
    gender: "gender",
    birthdate: "birthdate",
    ethnicity: "ethnicity",
    country: "country",
    eye_color: "eye_color",
    hair_color: "hair_color",
    height_cm: "height_cm",
    measurements: "measurements",
    fake_tits: "fake_tits",
    penis_length: "penis_length",
    circumcised: "circumcised",
    career_start: "career_start",
    career_end: "career_end",
    tattoos: "tattoos",
    piercings: "piercings",
    details: "details",
    death_date: "death_date",
    weight: "weight",
    image: "image_path",
  };

  for (const [key, val] of Object.entries(input)) {
    if (key === "id") continue;
    if (key === "image") {
      console.log(`  image:       (reapplied)`);
      continue;
    }
    if (key === "stash_ids") {
      console.log(`  stash_id:    ${(val as any[]).map((s: any) => `${s.endpoint} = ${s.stash_id}`).join("\n               ")}`);
      continue;
    }

    const localKey = fieldMap[key] ?? key;
    const oldVal = (local as any)[localKey];

    if (Array.isArray(val) && Array.isArray(oldVal)) {
      const o = oldVal.join(", ");
      const n = val.join(", ");
      if (o !== n) {
        console.log(`  ${key === "alias_list" ? "aliases" : key}:`);
        console.log(`    was: ${o}`);
        console.log(`    now: ${n}`);
      }
    } else if (Array.isArray(val)) {
      const n = val.join(", ");
      const o = oldVal != null ? String(oldVal) : "(unset)";
      if (o !== n) {
        console.log(`  ${key}:`);
        console.log(`    was: ${o}`);
        console.log(`    now: ${n}`);
      }
    } else {
      const newStr = String(val ?? "(unset)");
      const oldStr = oldVal != null ? String(oldVal) : "(unset)";
      if (oldStr !== newStr) {
        console.log(`  ${key}:`);
        console.log(`    was: ${oldStr}`);
        console.log(`    now: ${newStr}`);
      }
    }
  }
}


// ---- Mode 2: apply ----
async function cmdApply(
  localId: string,
  endpoint: string,
  remoteId: string,
  endpoints: { endpoint: string }[],
): Promise<void> {
  // Find matching stash-box endpoint.
  const ep = endpoints.find(e => new URL(e.endpoint).hostname === endpoint);
  if (!ep) {
    console.error(`no configured stash-box endpoint matches "${endpoint}"`);
    console.error(`configured: ${endpoints.map(e => new URL(e.endpoint).hostname).join(", ")}`);
    process.exit(1);
  }

  // Fetch local performer.
  const { findPerformer: local } = await gql<{ findPerformer: LocalPerformer | null }>(
    `query($id: ID!) {
       findPerformer(id: $id) {
         id name alias_list gender birthdate ethnicity country eye_color hair_color
         height_cm measurements fake_tits penis_length circumcised
         career_start career_end tattoos piercings details death_date weight
         urls image_path
         stash_ids { endpoint stash_id }
       }
     }`,
    { id: localId },
  );

  if (!local) {
    console.error(`performer ${localId} not found`);
    process.exit(1);
  }

  process.stderr.write(`querying ${endpoint} for "${local.name}" ... `);

  // Search stash-box by name, then find the result matching the remote_id.
  const { scrapeSinglePerformer: results } = await gql<{
    scrapeSinglePerformer: ScrapedPerformer[];
  }>(
    `query($source: ScraperSourceInput!, $input: ScrapeSinglePerformerInput!) {
       scrapeSinglePerformer(source: $source, input: $input) {
         name aliases gender birthdate ethnicity country eye_color hair_color
         height measurements fake_tits penis_length circumcised
         career_start career_end tattoos piercings details death_date weight
         url urls images
         tags { name }
         remote_site_id stored_id
       }
     }`,
    { source: { stash_box_endpoint: ep.endpoint }, input: { query: local.name } },
  );

  const r = (results ?? []).find(r => r.remote_site_id === remoteId);
  if (!r) {
    process.stderr.write(`no result with remote_id ${remoteId}\n`);
    process.exit(1);
  }
  process.stderr.write(`${r.name}\n`);

  const input = mapScrapedToInput(r, local);

  // Add stash_id.
  const stashIds = (local.stash_ids ?? []).filter(s => s.endpoint !== ep.endpoint);
  stashIds.push({ endpoint: ep.endpoint, stash_id: remoteId });
  input.stash_ids = stashIds.map(s => ({ endpoint: s.endpoint, stash_id: s.stash_id }));

  printDiff(input, local);

  const { performerUpdate } = await gql<{ performerUpdate: { id: string } }>(
    `mutation($input: PerformerUpdateInput!) { performerUpdate(input: $input) { id } }`,
    { input },
  );

  console.log(`updated performer ${performerUpdate.id}`);
}

// ---- Mode 1: scrape (preview) ----
async function cmdScrape(localId: string): Promise<void> {
  // Fetch local performer to get name.
  const { findPerformer: local } = await gql<{ findPerformer: { id: string; name: string } | null }>(
    `query($id: ID!) { findPerformer(id: $id) { id name } }`,
    { id: localId },
  );

  if (!local) {
    console.error(`performer ${localId} not found`);
    process.exit(1);
  }

  const name = local.name;
  console.log(`scraping "${name}" (performer ${localId})\n`);

  // Fetch configured stash-box endpoints.
  const { configuration } = await gql<{
    configuration: { general: { stashBoxes: { endpoint: string }[] } };
  }>(`{ configuration { general { stashBoxes { endpoint } } } }`);

  const endpoints = configuration.general.stashBoxes;
  if (!endpoints.length) {
    console.error("no stash-box endpoints configured");
    process.exit(1);
  }

  interface ResultSet { endpoint: string; results: ScrapedPerformer[] }
  const out: ResultSet[] = [];

  for (const { endpoint } of endpoints) {
    const host = new URL(endpoint).hostname;
    process.stderr.write(`querying ${host} ... `);

    try {
      const { scrapeSinglePerformer } = await gql<{
        scrapeSinglePerformer: ScrapedPerformer[];
      }>(
        `query($source: ScraperSourceInput!, $input: ScrapeSinglePerformerInput!) {
           scrapeSinglePerformer(source: $source, input: $input) {
             name aliases gender birthdate ethnicity country eye_color hair_color
             height measurements fake_tits penis_length circumcised
             career_start career_end tattoos piercings details death_date weight
             url urls
             tags { name }
             remote_site_id stored_id
           }
         }`,
        { source: { stash_box_endpoint: endpoint }, input: { query: name } },
      );

      const results = (scrapeSinglePerformer ?? []).filter(r => r.name);
      process.stderr.write(`${results.length} result(s)\n`);
      out.push({ endpoint, results });
    } catch (e) {
      process.stderr.write(`error: ${e}\n`);
      out.push({ endpoint, results: [] });
    }
  }

  // Print stash-box results.
  for (const { endpoint, results } of out) {
    const host = new URL(endpoint).hostname;

    if (!results.length) {
      console.log(`${host}:  (no results)`);
      continue;
    }

    for (const r of results) {
      const ref = `${host}/${r.remote_site_id ?? "?"}`;
      printPerformer(ref, r);
    }
  }

  // Web-scrape performer URLs for any stash-box result that has one.
  const seen = new Set<string>();
  for (const { results } of out) {
    for (const r of results) {
      if (!r.url || seen.has(r.url)) continue;
      seen.add(r.url);

      process.stderr.write(`web-scraping ${r.url} ... `);
      try {
        const { scrapePerformerURL: w } = await gql<{ scrapePerformerURL: ScrapedPerformer | null }>(
          `query($url: String!) {
             scrapePerformerURL(url: $url) {
               name aliases gender birthdate ethnicity country eye_color hair_color
               height measurements fake_tits penis_length circumcised
               career_start career_end tattoos piercings details death_date weight
               url urls
               tags { name }
               stored_id
             }
           }`,
          { url: r.url },
        );

        if (!w || !w.name) {
          process.stderr.write("no result\n");
          continue;
        }
        process.stderr.write(`${w.name}\n`);
        printPerformer(`web scraper (${new URL(r.url).hostname})`, w);
      } catch (e) {
        process.stderr.write(`error: ${e}\n`);
      }
    }
  }
}

// ---- Entry ----
async function main() {
  const args = process.argv.slice(2);
  const applyIdx = args.indexOf("--apply");

  if (applyIdx !== -1) {
    // Mode 2: apply
    const localId = args[0];
    const ref = args[applyIdx + 1];

    if (!localId || !ref) {
      console.error("Usage: bun scrape-performer.ts <local-id> --apply <hostname/remote_id>");
      process.exit(1);
    }

    const slashIdx = ref.indexOf("/");
    if (slashIdx === -1) {
      console.error(`invalid ref "${ref}" — expected <hostname>/<remote_id>`);
      process.exit(1);
    }

    const endpoint = ref.slice(0, slashIdx);
    const remoteId = ref.slice(slashIdx + 1);

    // Fetch endpoints.
    const { configuration } = await gql<{
      configuration: { general: { stashBoxes: { endpoint: string }[] } };
    }>(`{ configuration { general { stashBoxes { endpoint } } } }`);

    await cmdApply(localId, endpoint, remoteId, configuration.general.stashBoxes);
  } else {
    // Mode 1: scrape
    let localId = args[0];

    if (!localId) {
      if (!process.stdin.isTTY) {
        console.error("Usage: bun scrape-performer.ts <local-id>");
        console.error("       bun scrape-performer.ts <local-id> --apply <hostname/remote_id>");
        process.exit(1);
      }
      process.stdout.write("Enter local performer ID: ");
      localId = (await new Promise<string>(resolve => {
        process.stdin.resume();
        process.stdin.setEncoding("utf8");
        process.stdin.once("data", d => {
          process.stdin.pause();
          resolve(String(d));
        });
      })).trim();
      if (!localId) process.exit(0);
    }

    await cmdScrape(localId);
  }
}

main().catch(e => {
  console.error(e instanceof Error ? e.message : e);
  process.exit(1);
});
