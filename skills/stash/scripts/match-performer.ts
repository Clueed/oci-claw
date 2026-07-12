#!/usr/bin/env bun

/**
 * Performer Fuzzy Finder — match a query against the Stash performer database.
 * Prints matches, one per line: "<score>  <name>".
 *
 * Usage:
 *   bun match-performer.ts "kaitlyn katsaros"
 *   bun match-performer.ts adeline
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
  return 1 - dist / maxLen;
}

const STASH = process.env.STASH_URL || "http://localhost:9999/graphql";

const query = process.argv.slice(2).join(" ").trim();
if (!query) {
  console.error("Usage: bun match-performer.ts <name>");
  process.exit(1);
}

const all: { name: string; alias_list: string[] }[] = [];
let page = 1;
while (true) {
  const res = await fetch(STASH, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      query: `query($p: Int!) { findPerformers(filter: { page: $p, per_page: 200, sort: "name" }) { performers { name alias_list } count } }`,
      variables: { p: page },
    }),
  });
  const json: any = await res.json();
  if (json.errors) {
    for (const e of json.errors) console.error("GraphQL error:", e.message);
    process.exit(1);
  }
  all.push(...json.data.findPerformers.performers);
  if (all.length >= json.data.findPerformers.count) break;
  page++;
}

const matches = all
  .map(p => ({
    name: p.name,
    score: Math.max(
      similarity(query, p.name),
      ...p.alias_list.filter(a => a.trim()).map(a => similarity(query, a)),
    ),
  }))
  .filter(m => m.score >= 0.7)
  .sort((a, b) => b.score - a.score);

for (const m of matches) console.log(`${m.score.toFixed(2)}  ${m.name}`);
