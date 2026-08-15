---
name: torrent-gallery
description: How the torrent image gallery is wired — what a gallery path is, how preview images map to the video files inside a torrent, and where favorites live. Use when reasoning about gallery paths, previews, favorites, or how any of them relate to torrent files. For adding, selecting or removing torrents, use torrent-server.
---

# Torrent gallery

Bun server (`services/image-gallery.{nix,ts}`) serving `/var/lib/transmission/Downloads`
on `127.0.0.1:8766` as user `transmission`, published as Tailscale `svc:torrent-gallery`.
Torrents ship videos alongside one preview image each; the gallery browses the previews.

## The join key

A **gallery path** — the path below the downloads root — identifies everything. It is
byte-identical to Transmission's `file.name`, so no fuzzy matching is involved.

| System | Identifier | Example |
| --- | --- | --- |
| Gallery, favorites, `/files/` | gallery path | `[Scatbook] Bunny Hustler/Screens/Alika Pooping.mov.jpg` |
| Transmission `torrent-get` | `file.name` | identical string |
| Transmission RPC operations | `{torrentId, fileIndex}` | `{35, 22}` |

General form, for torrents whose `downloadDir` differs from the gallery root:
`relative(galleryRoot, resolve(torrent.downloadDir, file.name))`. Files resolving outside
the root are unreachable and ignored.

## Preview → video

Match **basenames within one torrent**. Directory parts do not line up: previews sit in a
`Screens/`-style subfolder, videos at the torrent root.

| Rule | Video | Preview |
| --- | --- | --- |
| `exact` — extension kept | `clip.mp4` | `Screens/clip.mp4.jpg` |
| `stem` — extension replaced | `clip.mp4` | `Screens/clip.jpg` |

Compare case-insensitively with whitespace collapsed; packs vary in nothing else. Try
`exact` first — it is unambiguous where both could apply.

Empirically (23 torrents, 4942 videos loaded 2026-08-15): every video resolved, no
colliding basenames. That is an observation about these packs, not a guarantee — a new
pack may use a third scheme, which surfaces as an unmatched image.

## Images that are not previews

Photo sets (`Images/`, `Pictures/`, `Photo/`) match no video. No link is the correct
answer, not a lookup failure — 3030 of the 7326 images on disk are these (2026-08-15).

## Favorites

`/var/lib/transmission/Downloads/.gallery-favorites.json`, owned by `transmission`,
rewritten whole on each toggle.

- JSON array of gallery paths. Semantically a **set** — array order is insertion order;
  the UI sorts.
- Keyed by the same path as everything else, so a favorite is a durable pointer to a
  video: strip the image extension, match the basename, get the file index.
- **Stale entries are normal.** Paths are strings; removing a torrent or renaming a file
  orphans its favorites silently. As of 2026-08-15, 93 stored, 80 resolvable. Filter
  against the current `/api/images` before trusting a count.

## API

| Endpoint | Purpose |
| --- | --- |
| `GET /api/images` | `{folder: [gallery paths]}`, recursive scan, folders with images only |
| `GET /api/favorites` | array of gallery paths |
| `POST /api/favorites` `{path}` | toggles one, returns the new array |
| `GET /api/links` | `{gallery path: {torrentId, fileIndex, video, size, wanted, done, rule}}` — the mapping above, resolved |
| `POST /api/select` `{paths, wanted}` | flips `files-wanted` on the linked videos |
| `GET /files/<gallery path>` | the image, confined to the root |

`/api/images` lists what is on disk; `/api/links` is built from torrent metadata and so
also covers previews not downloaded yet. Counts differ legitimately (4296 vs 5024).

## Recipes

`jq` is not installed; prefix with `nix shell nixpkgs#jq -c`.

```bash
# Resolve one preview to its video
curl -s localhost:8766/api/links | jq '.["<gallery path>"]'

# Favorites pointing at images no longer on disk
curl -s localhost:8766/api/favorites > f.json
curl -s localhost:8766/api/images > i.json
jq -n --slurpfile f f.json --slurpfile i i.json '$f[0] - [$i[0][][]]'

# Confirm a mapping against transmission itself
transmission-remote -t <id> -f | grep -i '<video basename>'
```
