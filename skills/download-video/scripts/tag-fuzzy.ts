#!/usr/bin/env bun

/**
 * Tag Fuzzy Finder — match scraped tags against Stash tag database
 * Outputs JSON for agent consumption.
 *
 * Usage:
 *   bun tag-fuzzy.ts "dirty atm" "shitty ass"
 *   printf "dirty atm\nshitty ass" | bun tag-fuzzy.ts
 *   bun tag-fuzzy.ts --threshold 0.4 < tags.txt
 *   bun tag-fuzzy.ts --threshold 0.4 --top 3 "dirty atm"
 *   bun tag-fuzzy.ts --pretty "dirty atm"
 *   bun tag-fuzzy.ts --apply <scene-id> "dirty atm" "blowjob"
 *
 * Environment:
 *   STASH_URL   default: http://localhost:9999/graphql
 */

function levenshtein(a: string, b: string): number {
  const m = a.length, n = b.length;
  const dp: number[][] = Array.from({ length: m + 1 }, () => Array(n + 1).fill(0));
  for (let i = 0; i <= m; i++) dp[i][0] = i;
  for (let j = 0; j <= n; j++) dp[0][j] = j;
  for (let i = 1; i <= m; i++) {
    for (let j = 1; j <= n; j++) {
      dp[i][j] = a[i - 1] === b[j - 1]
        ? dp[i - 1][j - 1]
        : 1 + Math.min(dp[i - 1][j], dp[i][j - 1], dp[i - 1][j - 1]);
    }
  }
  return dp[m][n];
}

function similarity(a: string, b: string): number {
  const al = a.toLowerCase().trim(), bl = b.toLowerCase().trim();
  if (al === bl) return 1;
  if (al.includes(bl) || bl.includes(al)) return 0.9;
  const dist = levenshtein(al, bl);
  const maxLen = Math.max(al.length, bl.length);
  if (maxLen === 0) return 1;
  const base = 1 - dist / maxLen;
  const bonus = al.split(/\s+/).some(w => bl.includes(w)) ? 0.1 : 0;
  return Math.min(1, base + bonus);
}

interface StashTag {
  id: string;
  name: string;
  aliases: string[];
}

interface Match {
  name: string;
  aliases: string[];
  score: number;
}

interface Result {
  scraped: string;
  matches: Match[];
}

const STASH = process.env.STASH_URL || "http://localhost:9999/graphql";

async function gql<T>(query: string, vars?: Record<string, unknown>): Promise<T> {
  const res = await fetch(STASH, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ query, variables: vars }),
  });
  const json: any = await res.json();
  if (json.errors) {
    for (const e of json.errors) console.error("GraphQL error:", e.message);
    process.exit(1);
  }
  return json.data as T;
}

async function fetchAllTags(): Promise<StashTag[]> {
  const all: StashTag[] = [];
  let page = 1;
  while (true) {
    const data = await gql<{ findTags: { tags: StashTag[]; count: number } }>(
      `query($p: Int!) { findTags(filter: { page: $p, per_page: 200, sort: "name" }) { tags { id name aliases } count } }`,
      { p: page },
    );
    all.push(...data.findTags.tags);
    if (all.length >= data.findTags.count) break;
    page++;
  }
  return all;
}

function parseArgs() {
  const args = process.argv.slice(2);
  let threshold = 0.7;
  let top = 3;
  let pretty = false;
  let apply: string | undefined;
  const names: string[] = [];

  for (let i = 0; i < args.length; i++) {
    if (args[i] === "--threshold" && i + 1 < args.length) threshold = parseFloat(args[++i]);
    else if (args[i] === "--top" && i + 1 < args.length) top = parseInt(args[++i]);
    else if (args[i] === "--pretty") pretty = true;
    else if (args[i] === "--apply" && i + 1 < args.length) apply = args[++i];
    else if (args[i].startsWith("--")) { console.error(`Unknown: ${args[i]}`); process.exit(1); }
    else names.push(args[i]);
  }

  return { threshold, top, pretty, apply, names };
}

async function main() {
  const { threshold, top, pretty, apply: applyScene, names: argNames } = parseArgs();

  let names = argNames;
  if (names.length === 0) {
    if (!process.stdin.isTTY) {
      const input = await Bun.stdin.text();
      names = input.trim().split("\n").map(s => s.trim()).filter(Boolean);
    }
  }

  if (names.length === 0) {
    console.error("Usage: bun tag-fuzzy.ts [--threshold 0.7] [--top 3] <tag names...>");
    console.error("       printf 'dirty atm\\nshitty ass' | bun tag-fuzzy.ts");
    console.error("       bun tag-fuzzy.ts --apply <scene-id> <tag names...>");
    process.exit(1);
  }

  const tags = await fetchAllTags();
  if (tags.length === 0) {
    console.error("No tags found in Stash.");
    process.exit(1);
  }

  const results: Result[] = [];
  const autoApplied: { id: string; name: string; scraped: string }[] = [];

  for (const name of names) {
    const lowerTags = tags.map(t => ({ ...t, name: t.name.toLowerCase(), aliases: t.aliases.map(a => a.toLowerCase()) }));
    let scored: Match[] = lowerTags
      .map(t => ({
        name: t.name,
        aliases: t.aliases,
        score: Math.max(similarity(name, t.name), ...t.aliases.map(a => similarity(name, a))),
      }))
      .filter(m => m.score >= threshold)
      .sort((a, b) => b.score - a.score);

    if (top > 0) scored = scored.slice(0, top);

    if (applyScene && scored.length > 0 && scored[0].score === 1) {
      const match = tags.find(t => t.name.toLowerCase() === scored[0].name);
      if (match) {
        autoApplied.push({ id: match.id, name: match.name, scraped: name });
        continue;
      }
    }

    results.push({ scraped: name, matches: scored });
  }

  if (applyScene && autoApplied.length > 0) {
    const { findScene } = await gql<{ findScene: { id: string; tags: { id: string }[] } }>(
      `query($id: ID!) { findScene(id: $id) { id tags { id } } }`,
      { id: applyScene },
    );
    if (!findScene) {
      console.error(`Scene not found: ${applyScene}`);
      process.exit(1);
    }
    const existing = new Set(findScene.tags.map(t => t.id));
    const newIds = autoApplied.map(a => a.id).filter(id => !existing.has(id));
    if (newIds.length > 0) {
      const merged = [...findScene.tags.map(t => t.id), ...newIds];
      await gql(
        `mutation($input: SceneUpdateInput!) { sceneUpdate(input: $input) { id } }`,
        { input: { id: applyScene, tag_ids: merged } },
      );
    }
  }

  if (applyScene) {
    const output: Record<string, unknown> = {};
    if (autoApplied.length > 0) {
      output.auto_applied = autoApplied.map(a => ({ name: a.name, scraped: a.scraped }));
    }
    if (results.length > 0) {
      output.pending = results;
    }
    console.log(JSON.stringify(output, null, pretty ? 2 : undefined));
  } else {
    console.log(JSON.stringify(results, null, pretty ? 2 : undefined));
  }
}

await main();
