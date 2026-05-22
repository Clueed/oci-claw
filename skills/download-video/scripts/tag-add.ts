#!/usr/bin/env bun

/**
 * Scene Tag Adder — add tags to a Stash scene by name.
 *
 * Usage:
 *   bun tag-add.ts <scene-id> "blowjob" "anal" "kissing"
 *
 * Environment:
 *   STASH_URL   default: http://localhost:9999/graphql
 */

const STASH = process.env.STASH_URL || "http://localhost:9999/graphql";

interface Tag { id: string; name: string; aliases: string[] }

function levenshtein(a: string, b: string): number {
  const m = a.length, n = b.length;
  const dp: number[][] = Array.from({ length: m + 1 }, () => Array(n + 1).fill(0));
  for (let i = 0; i <= m; i++) dp[i][0] = i;
  for (let j = 0; j <= n; j++) dp[0][j] = j;
  for (let i = 1; i <= m; i++)
    for (let j = 1; j <= n; j++)
      dp[i][j] = a[i - 1] === b[j - 1]
        ? dp[i - 1][j - 1]
        : 1 + Math.min(dp[i - 1][j], dp[i][j - 1], dp[i - 1][j - 1]);
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

async function fetchAllTags(): Promise<Tag[]> {
  const all: Tag[] = [];
  let page = 1;
  while (true) {
    const data = await gql<{ findTags: { tags: Tag[]; count: number } }>(
      `query($p: Int!) { findTags(filter: { page: $p, per_page: 200, sort: "name" }) { tags { id name aliases } count } }`,
      { p: page },
    );
    all.push(...data.findTags.tags);
    if (all.length >= data.findTags.count) break;
    page++;
  }
  return all;
}

function bestMatch(name: string, tags: Tag[]): Tag | undefined {
  const lower = tags.map(t => ({
    tag: t,
    score: Math.max(
      similarity(name, t.name),
      ...t.aliases.map(a => similarity(name, a)),
    ),
  }));
  lower.sort((a, b) => b.score - a.score);
  return lower[0]?.score >= 0.7 ? lower[0].tag : undefined;
}

async function main() {
  const args = process.argv.slice(2);
  const sceneId = args[0];
  const names = args.slice(1);

  if (!sceneId || names.length === 0) {
    console.error("Usage: bun tag-add.ts <scene-id> \"tag name\" ...");
    process.exit(1);
  }

  const { findScene } = await gql<{ findScene: { id: string; tags: Tag[] } }>(
    `query($id: ID!) { findScene(id: $id) { id tags { id name } } }`,
    { id: sceneId },
  );

  if (!findScene) {
    console.error(`Scene not found: ${sceneId}`);
    process.exit(1);
  }

  const allTags = await fetchAllTags();
  const tagIds: string[] = [];
  for (const name of names) {
    const match = bestMatch(name, allTags);
    if (match) {
      tagIds.push(match.id);
    } else {
      console.error(`no match for "${name}"`);
    }
  }

  if (tagIds.length === 0) {
    console.error("no valid tags to add");
    process.exit(1);
  }

  const existing = new Set(findScene.tags.map(t => t.id));
  const added = tagIds.filter(id => !existing.has(id));

  if (added.length === 0) {
    console.log("all tags already present");
    process.exit(0);
  }

  const merged = [...findScene.tags.map(t => t.id), ...added];

  await gql(
    `mutation($input: SceneUpdateInput!) { sceneUpdate(input: $input) { id } }`,
    { input: { id: sceneId, tag_ids: merged } },
  );

  console.log(`added ${added.length} tag(s) to scene ${sceneId}`);
}

await main();
