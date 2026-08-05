#!/usr/bin/env bun

/**
 * Auto Scrape — pick the right scraper(s) for a scene and run them in order
 * of precision, cheapest and most reliable first.
 *
 * Stash has ~800 scene scrapers. Firing them at a scene indiscriminately is
 * how you get a site to block the host IP (see ../scrapers.md). This walks a
 * tiered ladder and stops at the first result worth keeping:
 *
 *   0 URL        scene already has a source URL -> stash resolves the scraper
 *   1 STASHBOX   oshash/phash lookup against configured stash-boxes
 *   2 FILENAME   fragment scrapers whose filename regex actually matches
 *   3 AFFINITY   fragment scrapers whose name/domain matches path tokens
 *   4 NAME       title search, restricted to affinity candidates
 *   5 LOCAL      Filename/FileMetadata — offline, always safe, low value
 *
 * Tiers 0-2 are exact: they either match or are skipped. Tiers 3-4 are
 * guesses and are capped. By default nothing is written back; `--apply` writes
 * the scalar fields, but only for a result whose identity is proven.
 *
 * Usage:
 *   bun scrape-auto.ts <scene-id>              # plan only, no network
 *   bun scrape-auto.ts --run <scene-id>        # execute, stop at first hit
 *   bun scrape-auto.ts --run --all <scene-id>  # execute every tier
 *   bun scrape-auto.ts --run --max 3 <scene-id>
 *   bun scrape-auto.ts --json --run <scene-id>
 *   bun scrape-auto.ts --apply <scene-id>    # write back, CONFIRMED results only
 *   bun scrape-auto.ts --health              # show benched/failing scrapers
 *   bun scrape-auto.ts --unbench [id]        # clear one scraper, or all
 *
 * Environment:
 *   STASH_URL           default: http://localhost:9999/graphql
 *   STASH_HEALTH_PATH   default: ~/.cache/stash-skill/scraper-health.json
 */

import { existsSync, mkdirSync, readFileSync, writeFileSync } from "fs";
import { dirname, join } from "path";
import { homedir } from "os";
import { getIndex, tokenize, type ScraperEntry } from "./scraper-index.ts";

const STASH = process.env.STASH_URL || "http://localhost:9999/graphql";
const HEALTH_PATH = process.env.STASH_HEALTH_PATH
  || join(homedir(), ".cache", "stash-skill", "scraper-health.json");

/** Consecutive failures before a scraper is benched. */
const FAIL_THRESHOLD = 3;
/** How long a benched scraper stays benched. */
const BENCH_MS = 24 * 60 * 60 * 1000;
/** Default cap on guessed (tier 3/4) scrapers to try. */
const DEFAULT_MAX_GUESSES = 5;
/**
 * A filename regex must reject at least this fraction of the library to count
 * as identifying evidence. Catch-all cleanup regexes score ~0 and are ignored.
 */
const MIN_SELECTIVITY = 0.7;

/** Tokens too generic to imply a site match. */
const STOPWORDS = new Set([
  "www", "com", "net", "org", "the", "and", "video", "videos", "scene",
  "scenes", "porn", "xxx", "hd", "mp4", "wmv", "avi", "mkv", "full", "new",
  "free", "site", "network", "studios", "studio", "tube", "movies", "movie",
]);

interface Health {
  [scraperId: string]: { fails: number; lastError: string; benchedUntil?: string };
}

interface SceneFile {
  basename: string;
  path: string;
  fingerprints: { type: string; value: string }[];
}
interface Scene {
  id: string;
  title: string | null;
  urls: string[];
  studio: { name: string } | null;
  files: SceneFile[];
}

interface Scraped {
  title?: string | null;
  date?: string | null;
  details?: string | null;
  image?: string | null;
  studio?: { name?: string | null } | null;
  performers?: { name?: string | null }[] | null;
  tags?: { name?: string | null }[] | null;
}

type Confidence = "high" | "medium" | "low";

/**
 * How much a tier's answer can be trusted without human review.
 *
 * high   — identity is proven: the scene's own URL, or a fingerprint hash.
 * medium — an ID was derived from the filename by regex. Loose patterns do
 *          produce confident-looking nonsense (a `1045` in the filename will
 *          happily match an unrelated catalogue number), so these must be
 *          confirmed before being written back.
 * low    — pure guesswork from name/token similarity, or an offline echo of
 *          the filename.
 */
const TIER_CONFIDENCE: Record<string, Confidence> = {
  "0-URL": "high",
  "1-STASHBOX": "high",
  "2-FILENAME": "medium",
  "3-AFFINITY": "low",
  "4-NAME": "low",
  "5-LOCAL": "low",
};

interface Attempt {
  tier: string;
  scraper: string;
  ok: boolean;
  score: number;
  confidence: Confidence;
  error?: string;
  result?: Scraped;
}

async function gql<T>(query: string, vars?: Record<string, unknown>): Promise<T> {
  const res = await fetch(STASH, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ query, variables: vars }),
  });
  const json: any = await res.json();
  if (json.errors) throw new Error(json.errors.map((e: any) => e.message).join("; "));
  return json.data as T;
}

function loadHealth(): Health {
  try {
    return JSON.parse(readFileSync(HEALTH_PATH, "utf8"));
  } catch {
    return {};
  }
}

function saveHealth(h: Health): void {
  mkdirSync(dirname(HEALTH_PATH), { recursive: true });
  writeFileSync(HEALTH_PATH, JSON.stringify(h, null, 2));
}

function isBenched(h: Health, id: string): boolean {
  const e = h[id];
  return !!e?.benchedUntil && new Date(e.benchedUntil).getTime() > Date.now();
}

/**
 * Distinguish "this scraper is unusable" from "this guess was wrong".
 *
 * A 404 means the ID we derived from the filename doesn't exist on the site —
 * that is a per-scene miss and says nothing about the scraper's health, so
 * benching on it would retire perfectly good scrapers. A 403/429/timeout means
 * the site is refusing this host outright, which is what actually warrants
 * backing off (10Musume-JP started 404ing on bad IDs and ended up 403ing
 * everything).
 */
function isSiteLevelFailure(error: string): boolean {
  return /\b(401|403|429|5\d\d)\b/.test(error)
    || /timeout|timed out|refused|no such host|dns|EOF|certificate/i.test(error);
}

function recordFailure(h: Health, id: string, error: string): void {
  if (!isSiteLevelFailure(error)) return; // a wrong guess is not ill health
  const e = h[id] ?? { fails: 0, lastError: "" };
  e.fails += 1;
  e.lastError = error;
  if (e.fails >= FAIL_THRESHOLD) e.benchedUntil = new Date(Date.now() + BENCH_MS).toISOString();
  h[id] = e;
}

function recordSuccess(h: Health, id: string): void {
  delete h[id];
}

/**
 * How much a scraped result is actually worth. `Filename` returns a title for
 * every scene, so a title alone must not count as success.
 */
function scoreResult(s: Scraped | null | undefined): number {
  if (!s) return 0;
  let score = 0;
  if (s.title) score += 1;
  if (s.date) score += 2;
  if (s.studio?.name) score += 2;
  if (s.details) score += 1;
  score += Math.min((s.performers ?? []).length, 3);
  score += Math.min((s.tags ?? []).length, 3) * 0.5;
  return score;
}

/** A result is worth stopping on if it carries real metadata, not just a title. */
function isUseful(s: Scraped | null | undefined): boolean {
  return scoreResult(s) >= 3;
}

const SCRAPE_FIELDS = `title date details image studio { name } performers { name } tags { name }`;

async function scrapeBy(source: string, input: string): Promise<Scraped[]> {
  const data = await gql<{ scrapeSingleScene: Scraped[] | null }>(
    `query { scrapeSingleScene(source:{${source}}, input:{${input}}) { ${SCRAPE_FIELDS} } }`,
  );
  return data.scrapeSingleScene ?? [];
}

/** Does this scraper's URL pattern cover the given scene URL? */
function urlMatches(entry: ScraperEntry, url: string): boolean {
  const bare = url.replace(/^https?:\/\//, "").toLowerCase();
  return entry.urls.some(p => bare.startsWith(p.replace(/^https?:\/\//, "").toLowerCase()));
}

/**
 * Tier 2 gate: the fragment scraper's filename regex must match the file AND
 * be selective enough to mean something. Without the selectivity check, every
 * scraper whose queryURLReplace merely strips the extension (`\..+$`) would
 * claim every scene.
 */
function filenameGateMatches(entry: ScraperEntry, basename: string): boolean {
  const f = entry.fragment;
  if (!f || f.placeholder !== "filename" || !f.regexes.length) return false;
  if ((f.selectivity ?? 0) < MIN_SELECTIVITY) return false;
  return f.regexes.some(rx => {
    try {
      return new RegExp(rx).test(basename);
    } catch {
      return false; // Go regex syntax we can't compile — don't guess
    }
  });
}

function affinityScore(entry: ScraperEntry, sceneTokens: Set<string>): number {
  let score = 0;
  for (const t of entry.tokens) {
    if (STOPWORDS.has(t) || t.length < 4) continue;
    if (sceneTokens.has(t)) score += t.length;
  }
  return score;
}

interface Candidate { tier: string; entry?: ScraperEntry; source: string; input: string; label: string }

async function buildPlan(scene: Scene, maxGuesses: number): Promise<Candidate[]> {
  const idx = await getIndex();
  const health = loadHealth();
  const file = scene.files[0];
  const basename = file?.basename ?? "";
  const plan: Candidate[] = [];
  const used = new Set<string>();

  const add = (c: Candidate) => {
    if (c.entry && (used.has(c.entry.id) || isBenched(health, c.entry.id))) return;
    if (c.entry) used.add(c.entry.id);
    plan.push(c);
  };

  // Tier 0 — the scene already tells us where it came from.
  for (const url of scene.urls) {
    const owner = idx.scrapers.find(s => urlMatches(s, url));
    if (owner && isBenched(health, owner.id)) continue;
    if (owner) used.add(owner.id);
    plan.push({
      tier: "0-URL",
      entry: owner,
      source: "", // scrapeSceneURL resolves the scraper itself
      input: url,
      label: owner ? `${owner.id} <- ${url}` : `auto <- ${url}`,
    });
  }

  // Tier 1 — fingerprints. No metadata guessing at all; either the hash is
  // known to the box or it isn't.
  const hasFingerprint = (file?.fingerprints ?? []).some(f => f.type === "phash" || f.type === "oshash");
  if (hasFingerprint) {
    const { configuration } = await gql<{ configuration: { general: { stashBoxes: { name: string }[] } } }>(
      `{ configuration { general { stashBoxes { name } } } }`,
    );
    configuration.general.stashBoxes.forEach((box, i) => {
      plan.push({
        tier: "1-STASHBOX",
        source: `stash_box_index:${i}`,
        input: `scene_id:"${scene.id}"`,
        label: box.name,
      });
    });
  }

  // Tier 2 — fragment scrapers whose filename regex genuinely matches. This
  // is the gate whose absence caused the 10Musume-JP 404 storm.
  if (basename) {
    for (const s of idx.scrapers) {
      if (filenameGateMatches(s, basename)) {
        add({
          tier: "2-FILENAME",
          entry: s,
          source: `scraper_id:"${s.id}"`,
          input: `scene_id:"${scene.id}"`,
          label: s.id,
        });
      }
    }
  }

  // Tiers 3/4 — guesses, ranked by how strongly the site name shows up in the
  // file path or studio, and capped.
  const sceneTokens = new Set([
    ...tokenize(basename),
    ...tokenize(file?.path ?? ""),
    ...tokenize(scene.studio?.name ?? ""),
    ...tokenize(scene.title ?? ""),
  ]);

  const ranked = idx.scrapers
    .filter(s => !used.has(s.id) && !isBenched(health, s.id))
    .map(s => ({ s, score: affinityScore(s, sceneTokens) }))
    .filter(x => x.score > 0)
    .sort((a, b) => b.score - a.score);

  for (const { s } of ranked.filter(x => x.s.supports.includes("FRAGMENT")).slice(0, maxGuesses)) {
    add({
      tier: "3-AFFINITY",
      entry: s,
      source: `scraper_id:"${s.id}"`,
      input: `scene_id:"${scene.id}"`,
      label: s.id,
    });
  }

  if (scene.title) {
    const q = scene.title.replace(/"/g, '\\"');
    for (const { s } of ranked.filter(x => x.s.supports.includes("NAME")).slice(0, maxGuesses)) {
      add({
        tier: "4-NAME",
        entry: s,
        source: `scraper_id:"${s.id}"`,
        input: `query:"${q}"`,
        label: `${s.id} ?"${scene.title}"`,
      });
    }
  }

  // Tier 5 — offline last resort, never fails, never hits the network.
  for (const id of ["Filename", "FileMetadata"]) {
    const s = idx.scrapers.find(x => x.id === id);
    if (s) add({ tier: "5-LOCAL", entry: s, source: `scraper_id:"${s.id}"`, input: `scene_id:"${scene.id}"`, label: id });
  }

  return plan;
}

async function runCandidate(c: Candidate): Promise<Attempt> {
  const id = c.entry?.id ?? "auto";
  try {
    let results: Scraped[];
    if (c.tier === "0-URL") {
      const data = await gql<{ scrapeSceneURL: Scraped | null }>(
        `query($url:String!){ scrapeSceneURL(url:$url){ ${SCRAPE_FIELDS} } }`,
        { url: c.input },
      );
      results = data.scrapeSceneURL ? [data.scrapeSceneURL] : [];
    } else {
      results = await scrapeBy(c.source, c.input);
    }
    const best = results.sort((a, b) => scoreResult(b) - scoreResult(a))[0];
    return {
      tier: c.tier, scraper: c.label, ok: !!best,
      score: scoreResult(best), confidence: TIER_CONFIDENCE[c.tier] ?? "low", result: best,
    };
  } catch (e: any) {
    return {
      tier: c.tier, scraper: c.label, ok: false, score: 0,
      confidence: TIER_CONFIDENCE[c.tier] ?? "low", error: String(e.message ?? e),
    };
  }
}

function summarize(s: Scraped): string {
  const bits = [
    s.title && `title=${JSON.stringify(s.title)}`,
    s.date && `date=${s.date}`,
    s.studio?.name && `studio=${s.studio.name}`,
    s.performers?.length && `performers=${s.performers.length}`,
    s.tags?.length && `tags=${s.tags.length}`,
  ].filter(Boolean);
  return bits.join("  ") || "(empty)";
}

/**
 * Write the scalar fields back, mirroring scrape-scene.ts: tags, performers
 * and studio come back as *names*, so they are printed for the matching steps
 * rather than applied blind.
 */
async function applyResult(sceneId: string, s: Scraped): Promise<void> {
  const input: Record<string, unknown> = { id: sceneId };
  if (s.title) input.title = s.title;
  if (s.details) input.details = s.details;
  // Scrapers do return unparseable dates ("Aug 02"); sceneUpdate wants ISO.
  if (s.date && /^\d{4}-\d{2}-\d{2}$/.test(s.date)) input.date = s.date;
  else if (s.date) console.log(`skipping unparseable date ${JSON.stringify(s.date)}`);
  if (s.image) input.cover_image = s.image;

  const written = Object.keys(input).filter(k => k !== "id");
  if (!written.length) {
    console.log("nothing scalar to write");
    return;
  }

  await gql(`mutation($input: SceneUpdateInput!) { sceneUpdate(input: $input) { id } }`, { input });
  console.log(`\nupdated scene ${sceneId}: ${written.join(", ")}`);

  const tags = (s.tags ?? []).map(t => t.name).filter(Boolean);
  const performers = (s.performers ?? []).map(p => p.name).filter(Boolean);
  if (tags.length) {
    console.log(`\nscraped tags (${tags.length}) — feed into match-tag.ts:`);
    console.log(tags.map(t => `"${t}"`).join(" "));
  }
  if (performers.length) console.log(`\nscraped performers: ${performers.join(", ")}`);
  if (s.studio?.name) console.log(`scraped studio: ${s.studio.name}`);
}

async function main() {
  const args = process.argv.slice(2);
  const apply = args.includes("--apply");
  const run = args.includes("--run") || apply; // --apply implies executing
  const all = args.includes("--all");
  const asJson = args.includes("--json");
  const maxAt = args.indexOf("--max");
  const maxGuesses = maxAt !== -1 ? Number(args[maxAt + 1]) : DEFAULT_MAX_GUESSES;
  const positional = args.filter(a => !a.startsWith("--") && a !== String(maxGuesses));

  if (args.includes("--health")) {
    const h = loadHealth();
    const ids = Object.keys(h);
    if (!ids.length) {
      console.log("no scraper failures recorded");
      return;
    }
    for (const id of ids) {
      const benched = isBenched(h, id) ? `BENCHED until ${h[id].benchedUntil}` : "failing";
      console.log(`${id.padEnd(26)} ${String(h[id].fails).padStart(2)} fails  ${benched}`);
      console.log(`  ${h[id].lastError}`);
    }
    return;
  }

  if (args.includes("--unbench")) {
    const h = loadHealth();
    const target = positional[0];
    if (target) delete h[target];
    else for (const k of Object.keys(h)) delete h[k];
    saveHealth(h);
    console.log(target ? `unbenched ${target}` : "cleared all scraper health records");
    return;
  }

  const sceneId = positional[0];

  if (!sceneId) {
    console.error("Usage: bun scrape-auto.ts [--run] [--all] [--json] [--max N] <scene-id>");
    console.error("       bun scrape-auto.ts --health | --unbench [scraper-id]");
    process.exit(1);
  }

  const { findScene } = await gql<{ findScene: Scene | null }>(
    `query { findScene(id:"${sceneId}") {
       id title urls studio { name }
       files { basename path fingerprints { type value } }
     } }`,
  );
  if (!findScene) {
    console.error(`no scene ${sceneId}`);
    process.exit(1);
  }

  const plan = await buildPlan(findScene, maxGuesses);

  if (!run) {
    if (asJson) {
      console.log(JSON.stringify({ scene: findScene, plan }, null, 2));
      return;
    }
    console.log(`scene ${findScene.id}  ${findScene.files[0]?.basename ?? "(no file)"}`);
    console.log(`plan: ${plan.length} candidates (dry run — pass --run to execute)\n`);
    for (const c of plan) console.log(`  ${c.tier.padEnd(12)} ${c.label}`);
    return;
  }

  const health = loadHealth();
  const attempts: Attempt[] = [];
  for (const c of plan) {
    const a = await runCandidate(c);
    attempts.push(a);

    const id = c.entry?.id;
    if (id) {
      if (a.ok) recordSuccess(health, id);
      else if (a.error) recordFailure(health, id, a.error);
    }

    if (!asJson) {
      const status = a.error ? `ERROR ${a.error}` : a.ok ? summarize(a.result!) : "no match";
      console.log(`${a.tier.padEnd(12)} ${a.scraper.padEnd(34)} ${status}`);
    }
    // Only a proven identity ends the search. A medium/low hit may be a
    // coincidence, so keep going and let the caller compare candidates.
    if (!all && a.confidence === "high" && isUseful(a.result)) break;
  }
  saveHealth(health);

  const hits = attempts.filter(a => a.ok && isUseful(a.result)).sort((a, b) => b.score - a.score);
  const confirmed = hits.find(a => a.confidence === "high");
  if (asJson) {
    console.log(JSON.stringify({ scene: findScene, attempts, confirmed, candidates: hits }, null, 2));
    return;
  }

  console.log("");
  if (confirmed) {
    console.log(`CONFIRMED  ${confirmed.scraper} (${confirmed.tier})`);
    console.log(`           ${summarize(confirmed.result!)}`);
    if (apply) await applyResult(findScene.id, confirmed.result!);
    else console.log(`Identity is proven (source URL or fingerprint) — safe to apply.`);
  } else if (hits.length) {
    console.log(`UNCONFIRMED — ${hits.length} candidate(s), none identity-proven:`);
    for (const h of hits) console.log(`  [${h.confidence}] ${h.scraper} (${h.tier})  ${summarize(h.result!)}`);
    console.log(`\nA filename-derived match can be coincidental. Verify before applying.`);
    if (apply) console.log(`--apply refused: nothing here proves identity. Apply by hand if correct.`);
  } else {
    console.log(`no scraper returned usable metadata for scene ${findScene.id}`);
  }
}

if (import.meta.main) await main();
