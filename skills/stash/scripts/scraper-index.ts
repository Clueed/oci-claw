#!/usr/bin/env bun

/**
 * Scraper Index — build a searchable index of every installed Stash scraper.
 *
 * Stash ships ~800 community scrapers. Trying them blindly is slow and gets
 * the host IP blocked (see ../scrapers.md). This index makes it possible to
 * pick the handful of scrapers that can actually match a given scene.
 *
 * Two sources are merged:
 *   1. GraphQL `listScrapers` — id, name, URL patterns, supported scrape types.
 *      Always available.
 *   2. The scraper YAML files — the `sceneByFragment` query shape: which
 *      placeholder it keys on ({filename}, {title}, {url}, ...) and the
 *      filename regex it uses to build an ID. GraphQL does NOT expose this,
 *      and it is the single most useful gate we have: a fragment scraper whose
 *      filename regex does not match is guaranteed to build a garbage URL.
 *
 * The YAML dir lives in a root-owned podman volume, so enrichment needs sudo.
 * If sudo is unavailable the index still builds — it just loses regex gating.
 *
 * Usage:
 *   bun scraper-index.ts                 # build if stale, print stats
 *   bun scraper-index.ts --refresh       # force rebuild
 *   bun scraper-index.ts --json          # dump the whole index
 *   bun scraper-index.ts --show <id>     # inspect one scraper
 *
 * Environment:
 *   STASH_URL           default: http://localhost:9999/graphql
 *   STASH_SCRAPERS_DIR  default: the podman stash-config volume
 *   STASH_INDEX_PATH    default: ~/.cache/stash-skill/scraper-index.json
 */

import { existsSync, mkdirSync, readFileSync, writeFileSync, readdirSync } from "fs";
import { dirname, join } from "path";
import { homedir } from "os";
import { execFileSync } from "child_process";

const STASH = process.env.STASH_URL || "http://localhost:9999/graphql";
const SCRAPERS_DIR = process.env.STASH_SCRAPERS_DIR
  || "/var/lib/containers/storage/volumes/stash-config/_data/scrapers/community";
const INDEX_PATH = process.env.STASH_INDEX_PATH
  || join(homedir(), ".cache", "stash-skill", "scraper-index.json");

/** Rebuild automatically when the cached index is older than this. */
const MAX_AGE_MS = 7 * 24 * 60 * 60 * 1000;

export type ScrapeType = "NAME" | "FRAGMENT" | "URL";

export interface FragmentQuery {
  /** Which placeholder the queryURL keys on, e.g. "filename" or "title". */
  placeholder?: string;
  /** Regexes applied to the placeholder before building the URL. */
  regexes: string[];
  /** scrapeJson | scrapeXPath | script */
  action?: string;
  /**
   * Fraction of a real-library filename sample these regexes do NOT match.
   *
   * Many scrapers' queryURLReplace entries are cleanup rules (DMM strips the
   * extension with `\..+$`) rather than identifiers, so they match every file
   * and carry no signal. Selectivity separates a genuine ID pattern (~1.0)
   * from a catch-all (~0.0), so only real gates are trusted.
   */
  selectivity?: number;
}

export interface ScraperEntry {
  id: string;
  name: string;
  /** URL prefixes this scraper claims, e.g. "www.10musume.com/movies/". */
  urls: string[];
  /** Bare hostnames derived from `urls`. */
  hosts: string[];
  supports: ScrapeType[];
  fragment?: FragmentQuery;
  /** Lowercased tokens from id/name/hosts, used for affinity matching. */
  tokens: string[];
}

export interface ScraperIndex {
  builtAt: string;
  enriched: boolean;
  scrapers: ScraperEntry[];
}

async function gql<T>(query: string): Promise<T> {
  const res = await fetch(STASH, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ query }),
  });
  const json: any = await res.json();
  if (json.errors) {
    for (const e of json.errors) console.error("GraphQL error:", e.message);
    process.exit(1);
  }
  return json.data as T;
}

/** Read a root-owned file, falling back to non-interactive sudo. */
function readMaybeRoot(path: string): string | null {
  try {
    return readFileSync(path, "utf8");
  } catch (e: any) {
    if (e.code !== "EACCES" && e.code !== "EPERM") return null;
    try {
      return execFileSync("sudo", ["-n", "cat", path], { encoding: "utf8" });
    } catch {
      return null;
    }
  }
}

function listMaybeRoot(dir: string): string[] | null {
  try {
    return readdirSync(dir);
  } catch (e: any) {
    if (e.code !== "EACCES" && e.code !== "EPERM") return null;
    try {
      return execFileSync("sudo", ["-n", "ls", dir], { encoding: "utf8" })
        .split("\n").filter(Boolean);
    } catch {
      return null;
    }
  }
}

/**
 * Pull the `sceneByFragment:` block out of a scraper YAML.
 *
 * Deliberately line-based rather than a real YAML parse: we only need the
 * queryURL placeholder and the regex strings, and the block always ends at
 * the next column-0 key.
 */
export function parseFragmentBlock(yaml: string): FragmentQuery | undefined {
  const lines = yaml.split("\n");
  const start = lines.findIndex(l => /^sceneByFragment:/.test(l));
  if (start === -1) return undefined;

  const block: string[] = [];
  for (let i = start + 1; i < lines.length; i++) {
    const l = lines[i];
    if (/^[A-Za-z#]/.test(l)) break; // next top-level key
    block.push(l);
  }
  const text = block.join("\n");

  const action = text.match(/action:\s*([A-Za-z]+)/)?.[1];
  const placeholder = text.match(/\{(filename|title|url|oshash|phash|checksum|filepath)\}/)?.[1];

  // Only regexes under the placeholder's own queryURLReplace key gate the
  // filename; regexes under other keys transform unrelated fields.
  const regexes: string[] = [];
  const replaceIdx = block.findIndex(l => /queryURLReplace:/.test(l));
  if (replaceIdx !== -1 && placeholder) {
    let inKey = false;
    for (let i = replaceIdx + 1; i < block.length; i++) {
      const l = block[i];
      const keyMatch = l.match(/^\s{2,}([A-Za-z_]+):\s*$/);
      if (keyMatch) {
        inKey = keyMatch[1] === placeholder;
        continue;
      }
      if (!inKey) continue;
      const rx = l.match(/-?\s*regex:\s*(.+)$/);
      if (rx) regexes.push(unquote(rx[1].trim()));
    }
  }

  return { placeholder, regexes, action };
}

function unquote(s: string): string {
  const m = s.match(/^'(.*)'$/) || s.match(/^"(.*)"$/);
  return m ? m[1] : s;
}

function hostOf(urlPattern: string): string {
  return urlPattern.replace(/^https?:\/\//, "").split("/")[0].toLowerCase();
}

/** Split ids/names/hosts into comparable lowercase word tokens. */
export function tokenize(s: string): string[] {
  return s
    .toLowerCase()
    .replace(/\.(com|net|org|tv|xxx|cc|co|io)\b/g, " ")
    .split(/[^a-z0-9]+/)
    // camelCase / digit boundaries: "BangBros" -> bang, bros
    .flatMap(w => w.replace(/([a-z])([0-9])/g, "$1 $2").split(" "))
    .filter(w => w.length >= 3);
}

/**
 * Filenames used to measure regex selectivity when the library sample is
 * unavailable. Deliberately varied: studio-coded, JAV-coded, and plain titles.
 */
const CONTROL_FILENAMES = [
  "Some Scene Title.mp4", "brazzers_bigwet_1080p.mp4", "abp-123.mp4",
  "010124_01.mp4", "gachiPPV-1045-1.wmv", "Aika.wmv", "scene 4.mkv",
  "OnlyFans - model - 2023-04-01.mp4", "xh1A2B3C-clip.mp4", "MyMovie[abcd].mp4",
  "Evil.Angel.2022.DAP.1080p.mp4", "clip_002.avi", "Noa.wmv",
  "TPDB-Example-Scene-Name.mp4", "021523-001-carib.mp4", "video.mp4",
];

/** Sample real filenames from the library so selectivity reflects this library. */
async function sampleBasenames(limit = 300): Promise<string[]> {
  try {
    const data = await gql<{ findScenes: { scenes: { files: { basename: string }[] }[] } }>(
      `{ findScenes(filter:{per_page:${limit}, sort:"random"}) { scenes { files { basename } } } }`,
    );
    const names = data.findScenes.scenes.flatMap(s => s.files.map(f => f.basename)).filter(Boolean);
    return names.length >= 20 ? names : CONTROL_FILENAMES;
  } catch {
    return CONTROL_FILENAMES;
  }
}

/** Fraction of the sample the regexes do NOT match; 1.0 = maximally specific. */
function computeSelectivity(regexes: string[], sample: string[]): number {
  const compiled = regexes.map(r => { try { return new RegExp(r); } catch { return null; } })
    .filter((r): r is RegExp => r !== null);
  if (!compiled.length) return 0;
  const hits = sample.filter(n => compiled.some(r => r.test(n))).length;
  return 1 - hits / sample.length;
}

export async function buildIndex(): Promise<ScraperIndex> {
  const { listScrapers } = await gql<{
    listScrapers: { id: string; name: string; scene: { urls: string[] | null; supported_scrapes: ScrapeType[] } | null }[];
  }>(`{ listScrapers(types:[SCENE]) { id name scene { urls supported_scrapes } } }`);

  // Map scraper id -> YAML path. Dir layout is community/<Name>/<Name>.yml,
  // but the scraper id is the YAML basename, which may differ from the dir.
  const ymlByStem = new Map<string, string>();
  const dirs = listMaybeRoot(SCRAPERS_DIR);
  if (dirs) {
    for (const d of dirs) {
      const sub = listMaybeRoot(join(SCRAPERS_DIR, d));
      if (!sub) continue;
      for (const f of sub) {
        if (f.endsWith(".yml")) ymlByStem.set(f.replace(/\.yml$/, ""), join(SCRAPERS_DIR, d, f));
      }
    }
  }
  const enriched = ymlByStem.size > 0;
  const sample = enriched ? await sampleBasenames() : [];

  const scrapers: ScraperEntry[] = listScrapers.map(s => {
    const urls = s.scene?.urls ?? [];
    const hosts = [...new Set(urls.map(hostOf))];
    const entry: ScraperEntry = {
      id: s.id,
      name: s.name,
      urls,
      hosts,
      supports: s.scene?.supported_scrapes ?? [],
      tokens: [...new Set([...tokenize(s.id), ...tokenize(s.name), ...hosts.flatMap(tokenize)])],
    };
    if (entry.supports.includes("FRAGMENT")) {
      const path = ymlByStem.get(s.id);
      const yaml = path ? readMaybeRoot(path) : null;
      if (yaml) {
        entry.fragment = parseFragmentBlock(yaml);
        if (entry.fragment?.placeholder === "filename" && entry.fragment.regexes.length) {
          entry.fragment.selectivity = computeSelectivity(entry.fragment.regexes, sample);
        }
      }
    }
    return entry;
  });

  return { builtAt: new Date().toISOString(), enriched, scrapers };
}

export function loadIndex(): ScraperIndex | null {
  if (!existsSync(INDEX_PATH)) return null;
  try {
    const idx = JSON.parse(readFileSync(INDEX_PATH, "utf8")) as ScraperIndex;
    if (Date.now() - new Date(idx.builtAt).getTime() > MAX_AGE_MS) return null;
    return idx;
  } catch {
    return null;
  }
}

export function saveIndex(idx: ScraperIndex): void {
  mkdirSync(dirname(INDEX_PATH), { recursive: true });
  writeFileSync(INDEX_PATH, JSON.stringify(idx, null, 2));
}

/** Load the cached index, rebuilding when missing or stale. */
export async function getIndex(force = false): Promise<ScraperIndex> {
  if (!force) {
    const cached = loadIndex();
    if (cached) return cached;
  }
  const idx = await buildIndex();
  saveIndex(idx);
  return idx;
}

async function main() {
  const args = process.argv.slice(2);
  const idx = await getIndex(args.includes("--refresh"));

  if (args.includes("--json")) {
    console.log(JSON.stringify(idx, null, 2));
    return;
  }

  const showAt = args.indexOf("--show");
  if (showAt !== -1) {
    const id = args[showAt + 1];
    const hit = idx.scrapers.find(s => s.id.toLowerCase() === id?.toLowerCase());
    if (!hit) {
      console.error(`no scraper with id ${id}`);
      process.exit(1);
    }
    console.log(JSON.stringify(hit, null, 2));
    return;
  }

  const withFrag = idx.scrapers.filter(s => s.fragment);
  const gateable = withFrag.filter(s => s.fragment!.placeholder === "filename" && s.fragment!.regexes.length);
  console.log(`index built  ${idx.builtAt}`);
  console.log(`cache        ${INDEX_PATH}`);
  console.log(`scrapers     ${idx.scrapers.length}`);
  console.log(`  URL        ${idx.scrapers.filter(s => s.supports.includes("URL")).length}`);
  console.log(`  FRAGMENT   ${idx.scrapers.filter(s => s.supports.includes("FRAGMENT")).length}`);
  console.log(`  NAME       ${idx.scrapers.filter(s => s.supports.includes("NAME")).length}`);
  console.log(`hosts        ${new Set(idx.scrapers.flatMap(s => s.hosts)).size}`);
  if (idx.enriched) {
    console.log(`filename-gateable fragment scrapers: ${gateable.length}`);
  } else {
    console.log(`NOT enriched — scraper YAMLs unreadable (need sudo); regex gating disabled`);
  }
}

if (import.meta.main) await main();
