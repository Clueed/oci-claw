#!/usr/bin/env bun

/**
 * Tag Alias Adder — idempotently add a single alias to a Stash tag.
 *
 * Usage:
 *   bun tag-add-alias.ts "<tag-name>" "<alias>"
 *
 * Environment:
 *   STASH_URL   default: http://localhost:9999/graphql
 */

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

interface Tag {
  id: string;
  name: string;
  aliases: string[];
}

async function fetchTagByName(name: string): Promise<Tag | undefined> {
  const data = await gql<{ findTags: { tags: Tag[] } }>(
    `query($q: String!) { findTags(filter: { q: $q, per_page: 1 }) { tags { id name aliases } } }`,
    { q: name },
  );
  return data.findTags.tags.find(t => t.name.toLowerCase() === name.toLowerCase());
}

const UPDATE = `mutation($i: TagUpdateInput!) { tagUpdate(input: $i) { id name aliases } }`;

async function main() {
  const args = process.argv.slice(2);
  const tagName = args[0];
  const alias = args[1];

  if (!tagName || !alias) {
    console.error("Usage: bun tag-add-alias.ts \"<tag-name>\" \"<alias>\"");
    process.exit(1);
  }

  const normalized = alias.toLowerCase().trim();
  if (!normalized) {
    console.error("alias cannot be empty");
    process.exit(1);
  }

  const tag = await fetchTagByName(tagName);
  if (!tag) {
    console.error(`Tag not found: ${tagName}`);
    process.exit(1);
  }

  if (tag.aliases.some(a => a.toLowerCase().trim() === normalized)) {
    console.log("alias already exists");
    process.exit(0);
  }

  const merged = [...tag.aliases, normalized];
  const updated = await gql<{ tagUpdate: Tag }>(UPDATE, {
    i: { id: tag.id, aliases: merged },
  });

  console.log(JSON.stringify({ tag: updated.tagUpdate.name, added: normalized }));
}

await main();
