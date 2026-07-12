#!/usr/bin/env bun

// Download a single file from bunkr. Takes either a dl.bunkr.* download-page
// URL (the numeric file ID is extracted from it) or a bare file ID.
//
// Flow (tokens from step 3 expire in ~1hr, so all steps run back-to-back):
//   1. Resolve the numeric file ID.
//   2. POST the ID to /api/_001_v2 -> CDN host, original filename, storage path.
//   3. Sign the storage path via glb-apisign.cdn.cr/sign -> { token, ex }.
//   4. GET the signed CDN URL and stream it to disk in the cwd.

import { createWriteStream } from "fs";
import { Readable } from "stream";

const arg = process.argv[2];
if (!arg) {
  console.error("Usage: bun download-bunkr.ts <dl.bunkr-url|file-id>");
  process.exit(1);
}

const fileId = arg.match(/\/file\/(\d+)/)?.[1] ?? arg.match(/^\d+$/)?.[0];
if (!fileId) {
  console.error(`Could not extract a numeric file ID from: ${arg}`);
  process.exit(1);
}

// Step 2: download metadata
const meta = await fetch("https://dl.bunkr.cr/api/_001_v2", {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ id: fileId }),
}).then(r => r.json()) as { mediafiles: string; original: string; path: string };

if (!meta?.mediafiles || !meta?.path) {
  console.error(`Unexpected metadata response: ${JSON.stringify(meta)}`);
  process.exit(1);
}

// Step 3: sign the CDN path
const sign = await fetch(
  `https://glb-apisign.cdn.cr/sign?path=${encodeURIComponent(meta.path)}`,
).then(r => r.json()) as { ex: number; token: string };

if (!sign?.token || !sign?.ex) {
  console.error(`Unexpected sign response: ${JSON.stringify(sign)}`);
  process.exit(1);
}

// Step 4: download
const name = meta.original;
const url = `${meta.mediafiles}${meta.path}?token=${sign.token}&ex=${sign.ex}&n=${encodeURIComponent(name)}`;

console.error(`Downloading ${name} ...`);
const res = await fetch(url);
if (!res.ok || !res.body) {
  console.error(`Download failed: HTTP ${res.status}`);
  process.exit(1);
}

const out = createWriteStream(name);
await new Promise<void>((resolve, reject) => {
  Readable.fromWeb(res.body as any).pipe(out).on("finish", resolve).on("error", reject);
});

console.log(name);
