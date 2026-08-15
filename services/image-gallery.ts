import { readdir, readFile, writeFile } from "fs/promises";
import path from "path";

const downloadsDir = process.argv[2] ?? "/var/lib/transmission/Downloads";
const port = parseInt(process.argv[3] ?? "8766");
const hostname = process.argv[4] ?? "0.0.0.0";

const IMAGE_EXTS = new Set(["jpg", "jpeg", "png", "gif", "webp", "avif", "bmp"]);

function isImage(name: string): boolean {
  return IMAGE_EXTS.has(name.split(".").pop()?.toLowerCase() ?? "");
}

// Same extension list the transmission done-script uploads to stash, so a video
// the gallery offers to fetch is one that will actually reach the library.
const VIDEO_EXTS = new Set([
  "mp4", "mkv", "avi", "mov", "wmv", "m4v", "ts",
  "webm", "flv", "mpg", "mpeg", "divx", "vob",
]);

function isVideo(name: string): boolean {
  return VIDEO_EXTS.has(name.split(".").pop()?.toLowerCase() ?? "");
}

const IMAGE_EXT_RE = new RegExp("\\.(" + [...IMAGE_EXTS].join("|") + ")$", "i");

const baseName = (p: string): string => p.split("/").pop() ?? p;
const stripExt = (s: string): string => s.replace(/\.[^.]+$/, "");
// Torrent packs are inconsistent about spacing and case, nothing else.
const norm = (s: string): string => s.toLowerCase().replace(/\s+/g, " ").trim();

// Loopback, no auth -- transmission is configured with
// rpc-authentication-required = false and binds 127.0.0.1 only.
const rpcUrl = process.env.TRANSMISSION_RPC ?? "http://127.0.0.1:9091/transmission/rpc";
let sessionId = "";

async function rpc(body: unknown): Promise<any> {
  const send = () =>
    fetch(rpcUrl, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-Transmission-Session-Id": sessionId,
      },
      body: JSON.stringify(body),
    });

  let res = await send();
  // 409 is transmission handing us a fresh CSRF token; retry once with it.
  if (res.status === 409) {
    sessionId = res.headers.get("X-Transmission-Session-Id") ?? "";
    res = await send();
  }
  if (!res.ok) throw new Error("transmission rpc " + res.status);
  return await res.json();
}

interface Link {
  torrentId: number;
  fileIndex: number;
  video: string;
  size: number;
  wanted: boolean;
  done: boolean;
  rule: "exact" | "stem";
}

// The full file list of every torrent is ~2MB, so don't refetch it per
// keystroke. Selecting invalidates it explicitly, so the UI still updates
// immediately after an action.
const TORRENT_TTL_MS = 30_000;
let torrentCache: any[] | null = null;
let linkCache: Record<string, Link> | null = null;
let cachedAt = 0;

function invalidateTorrents(): void {
  torrentCache = null;
  linkCache = null;
}

async function getTorrents(): Promise<any[]> {
  if (torrentCache && Date.now() - cachedAt < TORRENT_TTL_MS) return torrentCache;
  const r = await rpc({
    method: "torrent-get",
    arguments: { fields: ["id", "name", "downloadDir", "files", "fileStats"] },
  });
  torrentCache = r.arguments?.torrents ?? [];
  linkCache = null;
  cachedAt = Date.now();
  return torrentCache;
}

// Map each preview image (keyed by its path relative to the gallery root, which
// is exactly how /api/images names it) to the video it depicts.
//
// Packs name previews one of two ways, and across every torrent seen so far the
// pair of rules resolves every video with zero ambiguous basenames:
//   exact -- "clip.mp4"  -> "Screens/clip.mp4.jpg"   (extension kept)
//   stem  -- "clip.mp4"  -> "Screens/clip.jpg"       (extension replaced)
// Matching is on basename within a single torrent, because the preview sits in
// a Screens/ subfolder while the video sits at the torrent root -- the
// directory parts deliberately do not line up.
//
// Images with no match are photo sets (Images/, Pictures/, Photo/), not failed
// lookups: they get no entry, and the UI shows them as having no linked video
// rather than guessing.
async function buildLinks(): Promise<Record<string, Link>> {
  if (linkCache) return linkCache;

  const galleryRoot = path.resolve(downloadsDir);
  const links: Record<string, Link> = {};

  for (const t of await getTorrents()) {
    const dir = path.resolve(t.downloadDir ?? downloadsDir);
    const files: any[] = t.files ?? [];
    const stats: any[] = t.fileStats ?? [];

    const byBase = new Map<string, number>();
    const byStem = new Map<string, number>();
    files.forEach((f, i) => {
      if (!isVideo(f.name)) return;
      const b = baseName(f.name);
      if (!byBase.has(norm(b))) byBase.set(norm(b), i);
      const s = norm(stripExt(b));
      if (!byStem.has(s)) byStem.set(s, i);
    });

    files.forEach((f) => {
      const b = baseName(f.name);
      if (!isImage(b)) return;

      // A torrent may download outside the gallery root; skip what we can't serve.
      const abs = path.resolve(dir, f.name);
      if (abs !== galleryRoot && !abs.startsWith(galleryRoot + path.sep)) return;

      const stem = b.replace(IMAGE_EXT_RE, "");
      let idx = byBase.get(norm(stem));
      let rule: Link["rule"] = "exact";
      if (idx === undefined) {
        idx = byStem.get(norm(stripExt(stem))) ?? byStem.get(norm(stem));
        rule = "stem";
      }
      if (idx === undefined) return;

      const vf = files[idx];
      links[path.relative(galleryRoot, abs)] = {
        torrentId: t.id,
        fileIndex: idx,
        video: baseName(vf.name),
        size: vf.length,
        wanted: stats[idx]?.wanted !== false,
        done: vf.length > 0 && vf.bytesCompleted >= vf.length,
        rule,
      };
    });
  }

  linkCache = links;
  return links;
}

// Flip the wanted flag on the videos behind the given preview images, then
// start their torrents -- the added-hook leaves a screens-only torrent idle
// once the images finish, so a newly wanted video needs an explicit start.
async function setWanted(paths: string[], wanted: boolean): Promise<number> {
  const links = await buildLinks();
  const byTorrent = new Map<number, Set<number>>();

  for (const p of paths) {
    const link = links[p];
    if (!link) continue;
    if (!byTorrent.has(link.torrentId)) byTorrent.set(link.torrentId, new Set());
    byTorrent.get(link.torrentId)!.add(link.fileIndex);
  }

  let n = 0;
  for (const [id, indices] of byTorrent) {
    const key = wanted ? "files-wanted" : "files-unwanted";
    await rpc({
      method: "torrent-set",
      arguments: { ids: [id], [key]: [...indices] },
    });
    if (wanted) await rpc({ method: "torrent-start", arguments: { ids: [id] } });
    n += indices.size;
  }

  if (n) invalidateTorrents();
  return n;
}

const favoritesFile = process.argv[5] ?? path.join(downloadsDir, ".gallery-favorites.json");

async function readFavorites(): Promise<string[]> {
  try {
    return JSON.parse(await readFile(favoritesFile, "utf-8"));
  } catch {
    return [];
  }
}

async function writeFavorites(favs: string[]): Promise<void> {
  await writeFile(favoritesFile, JSON.stringify(favs, null, 2));
}

async function scanDir(baseDir: string): Promise<Record<string, string[]>> {
  const groups: Record<string, string[]> = {};

  async function walk(dir: string) {
    let entries;
    try {
      entries = await readdir(dir, { withFileTypes: true });
    } catch {
      return;
    }
    const imagesHere: string[] = [];
    for (const entry of entries) {
      const fullPath = path.join(dir, entry.name);
      if (entry.isDirectory()) {
        await walk(fullPath);
      } else if (entry.isFile() && isImage(entry.name)) {
        imagesHere.push(path.relative(baseDir, fullPath));
      }
    }
    if (imagesHere.length) {
      const rel = path.relative(baseDir, dir);
      groups[rel === "" ? "(root)" : rel] = imagesHere.sort();
    }
  }

  await walk(baseDir);
  return groups;
}

const GALLERY_HTML = /* html */ `<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>Gallery</title>
<style>
* { box-sizing: border-box; margin: 0; padding: 0; }
body { background: #111; color: #ddd; font-family: sans-serif; display: flex; height: 100vh; overflow: hidden; }
#sidebar { width: 240px; min-width: 240px; border-right: 1px solid #2a2a2a; display: flex; flex-direction: column; overflow: hidden; }
#search { background: #161616; border: none; border-bottom: 1px solid #2a2a2a; color: #ccc; font-size: 12px; padding: 7px 10px; outline: none; width: 100%; flex-shrink: 0; }
#search:focus { background: #1a1a1a; }
#search::placeholder { color: #3a3a3a; }
#folder-section { overflow-y: auto; flex: 1 1 0; min-height: 80px; padding: 8px; border-bottom: 1px solid #1e1e1e; }
#file-section { overflow-y: auto; flex: 2 1 0; min-height: 80px; padding: 8px; }
#sidebar h2 { font-size: 11px; text-transform: uppercase; letter-spacing: 0.1em; color: #555; margin-bottom: 8px; padding: 2px 6px; }
.folder { padding: 5px 8px; cursor: pointer; border-radius: 4px; font-size: 13px; margin-bottom: 1px; display: flex; justify-content: space-between; align-items: center; }
.folder:hover { background: #1e1e1e; }
.folder.active { background: #1a3a6a; color: #fff; }
.folder-name { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.folder-count { color: #555; font-size: 11px; margin-left: 6px; flex-shrink: 0; }
.folder.active .folder-count { color: #aaa; }
.file-entry { padding: 4px 8px; cursor: pointer; border-radius: 3px; font-size: 12px; margin-bottom: 1px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; color: #888; }
.file-entry:hover { background: #1e1e1e; color: #ddd; }
.file-entry.active { background: #1a3a6a; color: #fff; }
.file-entry.search-match { color: #6af; }
.file-entry.active.search-match { color: #9cf; }
#main { flex: 1; display: flex; flex-direction: column; overflow: hidden; }
#toolbar { padding: 6px 12px; border-bottom: 1px solid #1e1e1e; font-size: 12px; color: #666; display: flex; align-items: center; gap: 8px; min-height: 32px; }
#img-name { color: #aaa; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
#img-counter { margin-left: auto; flex-shrink: 0; }
#viewer { flex: 1; display: flex; align-items: center; justify-content: center; overflow: hidden; cursor: zoom-in; position: relative; }
#viewer.zoomed { cursor: zoom-out; }
#viewer.scroll-mode { overflow-y: auto; align-items: flex-start; cursor: default; }
#viewer.scroll-mode #current-img { max-width: none; max-height: none; width: 100%; object-fit: contain; }
#current-img { max-width: 100%; max-height: 100%; object-fit: contain; transform-origin: center; user-select: none; -webkit-user-drag: none; }
#empty { color: #444; font-size: 16px; }
#fav-btn { background: none; border: none; font-size: 18px; cursor: pointer; padding: 2px 6px; color: #555; line-height: 1; }
#fav-btn:hover { color: #aaa; }
#fav-btn.active { color: #f0c040; }
#mode-btn { background: none; border: none; font-size: 16px; cursor: pointer; padding: 2px 6px; color: #555; line-height: 1; }
#mode-btn:hover { color: #aaa; }
#dl-btn { background: none; border: none; font-size: 16px; cursor: pointer; padding: 2px 6px; color: #555; line-height: 1; }
#dl-btn:hover:not(:disabled) { color: #aaa; }
#dl-btn:disabled { opacity: 0.25; cursor: default; }
#dl-btn.wanted, #dl-btn.done { color: #3a9a6a; }
#dl-favs-btn { background: none; border: 1px solid #2a2a2a; border-radius: 4px; color: #666; font-size: 11px; cursor: pointer; padding: 3px 8px; line-height: 1.4; }
#dl-favs-btn:hover { color: #ddd; border-color: #444; }
#dl-info { font-size: 11px; color: #666; flex-shrink: 0; }
#dl-info.wanted { color: #3a9a6a; }
#dl-info.none { color: #3a3a3a; }
#dl-info.warn { color: #b8862c; }
.file-entry .dl-dot { font-size: 9px; margin-left: 4px; color: #3a9a6a; }
.file-entry.is-queued .dl-dot { color: #b8862c; }
/* Downloaded previews stay listed but recede, so what is left to review stands out. */
.file-entry.is-done { color: #4a5a52; }
.file-entry.is-done:hover { color: #8aa; }
.file-entry.filtered-out { display: none; }
.folder .folder-dl { color: #3a9a6a; font-size: 9px; margin-left: 4px; }
#filter-btn { background: none; border: 1px solid #2a2a2a; border-radius: 4px; color: #666; font-size: 11px; cursor: pointer; padding: 3px 8px; line-height: 1.4; }
#filter-btn:hover { color: #ddd; border-color: #444; }
#filter-btn.on { color: #3a9a6a; border-color: #2f5a48; }
.folder.favorites-entry { color: #f0c040; }
.folder.favorites-entry .folder-count { color: #886622; }
.folder.favorites-entry.active { background: #3a3010; }
.folder .has-fav { color: #f0c040; font-size: 9px; margin-left: 4px; }
</style>
</head>
<body>
<div id="sidebar">
  <input id="search" type="text" placeholder="Search files… (/)" autocomplete="off" spellcheck="false">
  <div id="folder-section">
    <h2>Folders</h2>
    <div id="folder-list"></div>
  </div>
  <div id="file-section">
    <h2>Files</h2>
    <div id="file-list"></div>
  </div>
</div>
<div id="main">
  <div id="toolbar">
    <button id="fav-btn" title="Toggle favorite (f)">☆</button>
    <button id="mode-btn" title="Toggle view mode (m)">⊞</button>
    <button id="dl-btn" title="Download the linked video (d)">⬇</button>
    <button id="dl-favs-btn" title="Download every favorited video (D)">⬇ favs</button>
    <button id="filter-btn" title="Filter by download state (t)">all</button>
    <span id="img-name">—</span>
    <span id="dl-info"></span>
    <span id="img-counter"></span>
  </div>
  <div id="viewer">
    <img id="current-img" style="display:none" draggable="false">
    <div id="empty">No images found</div>
  </div>
</div>
<script>
let data = {}, folders = [], folder = null, idx = 0, zoom = 1, favorites = new Set(), viewingFavs = false, scrollMode = false, links = {}, filterMode = 'all';
const img = document.getElementById('current-img');
const empty = document.getElementById('empty');
const folderList = document.getElementById('folder-list');
const fileList = document.getElementById('file-list');
const searchInput = document.getElementById('search');
const imgName = document.getElementById('img-name');
const imgCounter = document.getElementById('img-counter');
const viewer = document.getElementById('viewer');
const favBtn = document.getElementById('fav-btn');
const modeBtn = document.getElementById('mode-btn');
const dlBtn = document.getElementById('dl-btn');
const dlInfo = document.getElementById('dl-info');
const dlFavsBtn = document.getElementById('dl-favs-btn');
const filterBtn = document.getElementById('filter-btn');

// Transmission being unreachable must not break browsing, so the link map
// degrades to empty and the download controls simply stay disabled.
async function loadLinks() {
  try {
    const r = await fetch('/api/links');
    const j = await r.json();
    links = r.ok && !j.error ? j : {};
  } catch { links = {}; }
}

async function load() {
  [data, favArr] = await Promise.all([
    fetch('/api/images').then(r => r.json()),
    fetch('/api/favorites').then(r => r.json()),
    loadLinks(),
  ]);
  favorites = new Set(favArr);
  folders = Object.keys(data).sort();
  folderList.innerHTML = '';

  const favEl = document.createElement('div');
  favEl.className = 'folder favorites-entry';
  favEl.dataset.f = '★ Favorites';
  const favCount = favArr.filter(p => Object.values(data).flat().includes(p)).length;
  favEl.innerHTML = '<span class="folder-name">★ Favorites</span><span class="folder-count">' + favCount + '</span>';
  favEl.onclick = () => pickFavs();
  folderList.appendChild(favEl);

  for (const f of folders) {
    const el = document.createElement('div');
    el.className = 'folder';
    el.dataset.f = f;
    const hasFav = data[f].some(p => favorites.has(p));
    el.innerHTML = '<span class="folder-name">' + f + '</span><span class="folder-count">' + data[f].length + '</span>' + '<span class="folder-dl"></span>' + (hasFav ? '<span class="has-fav">★</span>' : '');
    el.onclick = () => pick(f);
    folderList.appendChild(el);
  }
  renderSidebarDownloads();
  const hash = location.hash.slice(1);
  if (hash) {
    const slash = hash.lastIndexOf('/');
    const f = decodeURIComponent(hash.slice(0, slash));
    const i = parseInt(hash.slice(slash + 1));
    if (f === '★ Favorites' && favCount > 0) {
      pickFavs(i);
      return;
    }
    if (data[f] && i >= 0 && i < data[f].length) {
      folder = f; idx = i;
      document.querySelectorAll('.folder').forEach(el => el.classList.toggle('active', el.dataset.f === f));
      renderFileList();
      show();
      return;
    }
  }
  if (folders.length) pick(folders[0]);
}

function pick(f) {
  folder = f; idx = 0; viewingFavs = false;
  setZoom(1);
  searchInput.value = '';
  document.querySelectorAll('.folder').forEach(el => el.classList.toggle('active', el.dataset.f === f));
  renderFileList();
  ensureVisible();
  show();
}

function pickFavs(startIdx) {
  viewingFavs = true; folder = '★ Favorites'; idx = startIdx ?? 0;
  setZoom(1);
  searchInput.value = '';
  document.querySelectorAll('.folder').forEach(el => el.classList.toggle('active', el.dataset.f === '★ Favorites'));
  renderFileList();
  ensureVisible();
  show();
}

function getFavImgs() {
  return Object.values(data).flat().filter(p => favorites.has(p)).sort();
}

// How many of a folder's previews point at a video that is already on disk.
function folderStats(imgs) {
  let done = 0, queued = 0, linked = 0;
  for (const p of imgs) {
    const l = links[p];
    if (!l) continue;
    linked++;
    if (l.done) done++;
    else if (l.wanted) queued++;
  }
  return { done, queued, linked, total: imgs.length };
}

function renderFileList() {
  fileList.innerHTML = '';
  const imgs = viewingFavs ? getFavImgs() : (data[folder] ?? []);
  for (let i = 0; i < imgs.length; i++) {
    const name = imgs[i].split('/').pop();
    const el = document.createElement('div');
    el.className = 'file-entry';
    el.dataset.i = String(i);
    el.textContent = name;
    const l = links[imgs[i]];
    el.title = l ? imgs[i] + '\\n→ ' + l.video + (l.done ? ' (downloaded)' : l.wanted ? ' (queued)' : '') : imgs[i];
    if (l && (l.wanted || l.done)) {
      el.classList.add(l.done ? 'is-done' : 'is-queued');
      const dot = document.createElement('span');
      dot.className = 'dl-dot';
      dot.textContent = l.done ? '✓' : '⬇';
      el.appendChild(dot);
    }
    // Hidden rather than removed, so entry positions keep matching image indices.
    if (filterMode === 'new' && l && (l.done || l.wanted)) el.classList.add('filtered-out');
    if (filterMode === 'done' && !(l && l.done)) el.classList.add('filtered-out');
    el.onclick = () => { idx = parseInt(el.dataset.i); setZoom(1); show(); };
    fileList.appendChild(el);
  }
}

function updateFileActive() {
  const entries = fileList.querySelectorAll('.file-entry');
  entries.forEach((el, i) => el.classList.toggle('active', i === idx));
  const activeEl = fileList.querySelector('.file-entry.active');
  if (activeEl) activeEl.scrollIntoView({ block: 'nearest' });
}

async function toggleFavorite() {
  const imgs = viewingFavs ? getFavImgs() : (data[folder] ?? []);
  if (!imgs.length) return;
  const path = imgs[idx];
  const res = await fetch('/api/favorites', {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ path }),
  });
  favorites = new Set(await res.json());
  if (viewingFavs) {
    if (idx >= getFavImgs().length) idx = Math.max(0, idx - 1);
    renderFileList();
  }
  show();
  renderSidebarFavs();
}

function renderSidebarFavs() {
  const favCount = Object.values(data).flat().filter(p => favorites.has(p)).length;
  const favEl = folderList.querySelector('.favorites-entry .folder-count');
  if (favEl) favEl.textContent = favCount;
  document.querySelectorAll('.folder:not(.favorites-entry)').forEach(el => {
    const f = el.dataset.f;
    const hasFav = data[f] && data[f].some(p => favorites.has(p));
    let dot = el.querySelector('.has-fav');
    if (hasFav && !dot) { dot = document.createElement('span'); dot.className = 'has-fav'; dot.textContent = '★'; el.appendChild(dot); }
    else if (!hasFav && dot) dot.remove();
  });
}

// Per-folder download tally in the sidebar, so a pack you have already worked
// through is obvious without opening it.
function renderSidebarDownloads() {
  document.querySelectorAll('.folder:not(.favorites-entry)').forEach(el => {
    const f = el.dataset.f;
    const span = el.querySelector('.folder-dl');
    if (!span || !data[f]) return;
    const s = folderStats(data[f]);
    const parts = [];
    if (s.done) parts.push(s.done + '✓');
    if (s.queued) parts.push(s.queued + '⬇');
    span.textContent = parts.join(' ');
    el.title = f + ' — ' + s.total + ' images, ' + s.linked + ' linked to videos, ' +
      s.done + ' downloaded' + (s.queued ? ', ' + s.queued + ' queued' : '');
  });
}

function cycleFilter() {
  filterMode = filterMode === 'all' ? 'new' : filterMode === 'new' ? 'done' : 'all';
  filterBtn.textContent = filterMode === 'all' ? 'all' : filterMode === 'new' ? 'not downloaded' : 'downloaded';
  filterBtn.classList.toggle('on', filterMode !== 'all');
  renderFileList();
  ensureVisible();
  show();
}

// Keep the viewer on an entry the current filter actually shows.
function ensureVisible() {
  const nav = navIndices();
  if (nav.length && !nav.includes(idx)) idx = nav[0];
}

function currentImgs() {
  return viewingFavs ? getFavImgs() : (data[folder] ?? []);
}

function fmtSize(b) {
  if (b >= 1e9) return (b / 1e9).toFixed(2) + ' GB';
  if (b >= 1e6) return (b / 1e6).toFixed(0) + ' MB';
  return (b / 1e3).toFixed(0) + ' kB';
}

// Reflect the linked video's state in the toolbar. Four cases: no linked video
// (photo-set image), already downloaded, wanted but not yet complete, and
// available to request.
function renderDownload() {
  const imgs = currentImgs();
  const p = imgs[idx];
  const l = p ? links[p] : null;

  if (!l) {
    dlBtn.disabled = true;
    dlBtn.textContent = '⬇';
    dlBtn.className = '';
    dlBtn.title = 'No video linked to this image';
    dlInfo.className = 'none';
    dlInfo.textContent = p ? 'no linked video' : '';
    return;
  }

  dlBtn.disabled = false;
  dlBtn.title = l.video;
  let info;
  if (l.done) {
    dlBtn.textContent = '✓'; dlBtn.className = 'done';
    dlInfo.className = 'wanted'; info = 'downloaded · ' + fmtSize(l.size);
  } else if (l.wanted) {
    dlBtn.textContent = '⏳'; dlBtn.className = 'wanted';
    dlInfo.className = 'wanted'; info = 'queued · ' + fmtSize(l.size);
  } else {
    dlBtn.textContent = '⬇'; dlBtn.className = '';
    dlInfo.className = ''; info = fmtSize(l.size);
  }
  // Surface the weaker match rule rather than trusting it silently, so a pack
  // with an unusual naming scheme is visible instead of downloading the wrong file.
  if (l.rule === 'stem') { info += ' · matched by stem'; dlInfo.className = 'warn'; }
  dlInfo.textContent = info;
}

async function postSelect(paths, wanted) {
  const res = await fetch('/api/select', {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ paths, wanted }),
  });
  const j = await res.json();
  if (j.links) links = j.links;
  return j;
}

async function toggleDownload() {
  const imgs = currentImgs();
  const p = imgs[idx];
  const l = p ? links[p] : null;
  if (!l || l.done) return;
  dlInfo.className = ''; dlInfo.textContent = 'working…';
  try {
    await postSelect([p], !l.wanted);
  } catch {
    dlInfo.className = 'warn'; dlInfo.textContent = 'request failed';
    return;
  }
  renderDownload();
  renderFileList();
  updateFileActive();
  renderSidebarDownloads();
}

async function downloadFavorites() {
  const paths = getFavImgs().filter(p => links[p] && !links[p].wanted && !links[p].done);
  if (!paths.length) {
    dlInfo.className = 'none'; dlInfo.textContent = 'no new favorited videos';
    return;
  }
  const total = paths.reduce((s, p) => s + links[p].size, 0);
  if (!confirm('Download ' + paths.length + ' video(s), ' + fmtSize(total) + '?')) return;
  dlInfo.className = ''; dlInfo.textContent = 'working…';
  try {
    await postSelect(paths, true);
  } catch {
    dlInfo.className = 'warn'; dlInfo.textContent = 'request failed';
    return;
  }
  renderDownload();
  renderFileList();
  updateFileActive();
  renderSidebarDownloads();
}

function imgUrl(path) {
  return '/files/' + path.split('/').map(encodeURIComponent).join('/');
}

function preload(imgs, from, count) {
  for (let i = from; i < Math.min(from + count, imgs.length); i++) {
    new Image().src = imgUrl(imgs[i]);
  }
}

function show() {
  const imgs = viewingFavs ? getFavImgs() : (data[folder] ?? []);
  if (!imgs.length) { img.style.display = 'none'; empty.style.display = ''; favBtn.textContent = '☆'; renderDownload(); return; }
  img.style.display = '';
  empty.style.display = 'none';
  img.src = imgUrl(imgs[idx]);
  imgName.textContent = imgs[idx].split('/').pop();
  const st = folderStats(imgs);
  imgCounter.textContent = (idx + 1) + ' / ' + imgs.length +
    (st.linked ? ' · ' + st.done + '✓' + (st.queued ? ' ' + st.queued + '⬇' : '') : '');
  favBtn.textContent = favorites.has(imgs[idx]) ? '★' : '☆';
  favBtn.classList.toggle('active', favorites.has(imgs[idx]));
  history.replaceState(null, '', '#' + encodeURIComponent(folder) + '/' + idx);
  preload(imgs, idx + 1, 3);
  updateFileActive();
  renderDownload();
}

function setZoom(z) {
  if (scrollMode) return;
  zoom = Math.max(0.2, Math.min(5, z));
  img.style.transform = zoom === 1 ? '' : 'scale(' + zoom + ')';
  viewer.classList.toggle('zoomed', zoom > 1);
}

function toggleMode() {
  scrollMode = !scrollMode;
  viewer.classList.toggle('scroll-mode', scrollMode);
  modeBtn.textContent = scrollMode ? '⊟' : '⊞';
  if (scrollMode) {
    setZoom(1);
    viewer.scrollTop = 0;
  }
}

searchInput.addEventListener('input', () => {
  const q = searchInput.value.toLowerCase();
  const entries = Array.from(fileList.querySelectorAll('.file-entry'));
  if (!q) {
    entries.forEach(el => el.classList.remove('search-match'));
    return;
  }
  const imgs = viewingFavs ? getFavImgs() : (data[folder] ?? []);
  let firstMatch = -1;
  entries.forEach((el, i) => {
    const name = imgs[i].split('/').pop().toLowerCase();
    const matches = name.includes(q);
    el.classList.toggle('search-match', matches);
    if (matches && firstMatch === -1) firstMatch = i;
  });
  if (firstMatch !== -1) {
    idx = firstMatch;
    show();
  }
});

// Which entries the arrow keys step through: whatever the filter leaves visible,
// narrowed to search hits when a search is active.
function navIndices() {
  const visible = Array.from(fileList.querySelectorAll('.file-entry'))
    .filter(el => !el.classList.contains('filtered-out'));
  const matched = visible.filter(el => el.classList.contains('search-match'));
  return (matched.length ? matched : visible).map(el => parseInt(el.dataset.i));
}

document.addEventListener('keydown', e => {
  if (e.target === searchInput) {
    if (e.key === 'Escape') {
      searchInput.value = '';
      searchInput.blur();
      fileList.querySelectorAll('.file-entry').forEach(el => el.classList.remove('search-match'));
    }
    return;
  }
  if (e.key === '/') { e.preventDefault(); searchInput.focus(); return; }
  if (!folder) return;
  const fi = folders.indexOf(folder);
  if (e.key === 'ArrowRight' || e.key === 'ArrowDown') {
    const nav = navIndices();
    const pos = nav.indexOf(idx);
    // Landing outside the nav set (filter just changed under us) jumps forward
    // to the nearest entry that is still reachable.
    const next = pos === -1 ? nav.find(i => i > idx) : nav[pos + 1];
    if (next !== undefined) { idx = next; show(); }
  } else if (e.key === 'ArrowLeft' || e.key === 'ArrowUp') {
    const nav = navIndices();
    const pos = nav.indexOf(idx);
    const prev = pos === -1 ? [...nav].reverse().find(i => i < idx) : nav[pos - 1];
    if (prev !== undefined) { idx = prev; show(); }
  }
  else if (e.key === ']') { if (fi < folders.length - 1) pick(folders[fi + 1]); }
  else if (e.key === '[') { if (fi > 0) pick(folders[fi - 1]); }
  else if (e.key === '+' || e.key === '=') setZoom(zoom * 1.25);
  else if (e.key === '-') setZoom(zoom / 1.25);
  else if (e.key === '0') setZoom(1);
  else if (e.key === 'f') toggleFavorite();
  else if (e.key === 'm') toggleMode();
  else if (e.key === 'd') toggleDownload();
  else if (e.key === 'D') downloadFavorites();
  else if (e.key === 't') cycleFilter();
});

viewer.addEventListener('wheel', e => { if (scrollMode) return; e.preventDefault(); setZoom(e.deltaY < 0 ? zoom * 1.1 : zoom / 1.1); }, { passive: false });
viewer.addEventListener('click', () => { if (!scrollMode) setZoom(zoom > 1 ? 1 : 2); });
favBtn.addEventListener('click', e => { e.stopPropagation(); toggleFavorite(); });
modeBtn.addEventListener('click', e => { e.stopPropagation(); toggleMode(); });
dlBtn.addEventListener('click', e => { e.stopPropagation(); toggleDownload(); });
dlFavsBtn.addEventListener('click', e => { e.stopPropagation(); downloadFavorites(); });
filterBtn.addEventListener('click', e => { e.stopPropagation(); cycleFilter(); });

// Queued videos finish while you keep browsing, so refresh the link states
// periodically -- the server caches for the same interval, so this is cheap.
setInterval(async () => {
  await loadLinks();
  renderDownload();
  const active = idx;
  renderFileList();
  idx = active;
  updateFileActive();
  renderSidebarDownloads();
}, 30000);

load();
</script>
</body>
</html>`;

const server = Bun.serve({
  port,
  hostname,
  async fetch(req) {
    const url = new URL(req.url);

    if (url.pathname === "/") {
      return new Response(GALLERY_HTML, {
        headers: { "content-type": "text/html; charset=utf-8" },
      });
    }

    if (url.pathname === "/api/images") {
      return Response.json(await scanDir(downloadsDir));
    }

    if (url.pathname === "/api/links") {
      try {
        return Response.json(await buildLinks());
      } catch (e) {
        // Transmission down: the gallery still browses, just without selection.
        return Response.json({ error: String(e) }, { status: 503 });
      }
    }

    if (url.pathname === "/api/select" && req.method === "POST") {
      try {
        const body = await req.json();
        const paths: string[] = body.paths ?? (body.path ? [body.path] : []);
        const updated = await setWanted(paths, body.wanted !== false);
        return Response.json({ updated, links: await buildLinks() });
      } catch (e) {
        return Response.json({ error: String(e) }, { status: 502 });
      }
    }

    if (url.pathname === "/api/favorites") {
      if (req.method === "POST") {
        const body = await req.json();
        const favs = await readFavorites();
        const idx = favs.indexOf(body.path);
        if (idx >= 0) favs.splice(idx, 1); else favs.push(body.path);
        await writeFavorites(favs);
        return Response.json(favs);
      }
      return Response.json(await readFavorites());
    }

    if (url.pathname.startsWith("/files/")) {
      const relPath = url.pathname
        .slice(7)
        .split("/")
        .map(decodeURIComponent)
        .join("/");
      const absPath = path.resolve(downloadsDir, relPath);
      if (!absPath.startsWith(path.resolve(downloadsDir) + path.sep) &&
          absPath !== path.resolve(downloadsDir)) {
        return new Response("Forbidden", { status: 403 });
      }
      const file = Bun.file(absPath);
      if (!(await file.exists())) return new Response("Not Found", { status: 404 });
      return new Response(file);
    }

    return new Response("Not Found", { status: 404 });
  },
});

console.log(`Gallery listening on http://${server.hostname}:${server.port}`);
console.log(`Serving images from: ${downloadsDir}`);
