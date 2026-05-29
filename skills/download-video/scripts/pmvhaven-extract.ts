#!/usr/bin/env bun

const url = process.argv[2];
if (!url) {
  console.error("Usage: bun pmvhaven-extract.ts <video-page-url>");
  process.exit(1);
}

const html = await fetch(url).then(r => r.text());
const match = html.match(/https:\/\/video\.pmvhaven\.com\/videos\/[^"'\s]+\.mp4/);

if (!match) {
  console.error("No MP4 URL found on page");
  process.exit(1);
}

console.log(match[0]);
