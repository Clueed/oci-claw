#!/usr/bin/env bun

/**
 * Scene Scrape & Update — scrape metadata from a source URL and write it
 * back to a Stash scene.
 *
 * Scrapes the full field set (title, details, date, image, studio,
 * performers, tags). Scalar fields (title/details/date/cover image/url) are
 * written straight to the scene. Tags, performers and studio come back as
 * *names*, so they're printed rather than applied: tags go through the
 * fuzzy-matcher with your approval (see references/tag-matching.md), and
 * performers/studio need name->ID resolution first.
 *
 * Usage:
 *   bun scrape-scene.ts <video-url> <scene-id>
 *   bun scrape-scene.ts --title-only <video-url> <scene-id>   # PMVHaven: title only
 *
 * --title-only scrapes and writes just the title. Passing details/cover_image
 * to sceneUpdate 422s on some sources (e.g. PMVHaven), so use it there.
 *
 * Environment:
 *   STASH_URL   default: http://localhost:9999/graphql
 */

const STASH = process.env.STASH_URL || "http://localhost:9999/graphql";

interface Named { name?: string | null }
interface Scraped {
  title?: string | null;
  details?: string | null;
  date?: string | null;
  image?: string | null;
  studio?: Named | null;
  performers?: Named[] | null;
  tags?: Named[] | null;
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

function names(items?: Named[] | null): string[] {
  return (items ?? []).map(i => i.name).filter((n): n is string => !!n);
}

async function main() {
  const args = process.argv.slice(2);
  const titleOnly = args.includes("--title-only");
  const [videoUrl, sceneId] = args.filter(a => a !== "--title-only");

  if (!videoUrl || !sceneId) {
    console.error('Usage: bun scrape-scene.ts [--title-only] <video-url> <scene-id>');
    process.exit(1);
  }

  // Scrape the full field set from the source URL.
  const { scrapeSceneURL: s } = await gql<{ scrapeSceneURL: Scraped | null }>(
    `query($url: String!) {
       scrapeSceneURL(url: $url) {
         title details date image
         studio { name }
         performers { name }
         tags { name }
       }
     }`,
    { url: videoUrl },
  );

  if (!s) {
    console.error(`nothing scraped from ${videoUrl}`);
    process.exit(1);
  }

  // Build the update input. Only include fields that were actually scraped,
  // and drop everything but the title in title-only mode.
  const input: Record<string, unknown> = { id: sceneId, urls: [videoUrl] };
  if (s.title) input.title = s.title;
  if (!titleOnly) {
    if (s.details) input.details = s.details;
    if (s.date) input.date = s.date;
    if (s.image) input.cover_image = s.image;
  }

  const { sceneUpdate } = await gql<{ sceneUpdate: { id: string } }>(
    `mutation($input: SceneUpdateInput!) { sceneUpdate(input: $input) { id } }`,
    { input },
  );

  const written = Object.keys(input).filter(k => k !== "id" && k !== "urls");
  console.log(`updated scene ${sceneUpdate.id}: ${written.join(", ") || "(urls only)"}`);

  // Surface the name-based fields for the tag-matching / manual steps.
  const tags = names(s.tags);
  const performers = names(s.performers);
  const studio = s.studio?.name;

  if (tags.length) {
    console.log(`\nscraped tags (${tags.length}) — feed into match-tag.ts:`);
    console.log(tags.map(t => `"${t}"`).join(" "));
  }
  if (performers.length) console.log(`\nscraped performers: ${performers.join(", ")}`);
  if (studio) console.log(`scraped studio: ${studio}`);
}

await main();
