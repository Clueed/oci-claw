import { readdir } from "fs/promises";
import path from "path";

const downloadsDir = process.argv[2] ?? "/var/lib/transmission/Downloads";
const port = parseInt(process.argv[3] ?? "8766");
const hostname = process.argv[4] ?? "0.0.0.0";

const IMAGE_EXTS = new Set(["jpg", "jpeg", "png", "gif", "webp", "avif", "bmp"]);

function isImage(name: string): boolean {
  return IMAGE_EXTS.has(name.split(".").pop()?.toLowerCase() ?? "");
}

async function scanDir(baseDir: string): Promise<Record<string, string[]>> {
  const groups: Record<string, string[]> = {};

  async function walk(dir: string, topFolder: string) {
    let entries;
    try {
      entries = await readdir(dir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const entry of entries) {
      const fullPath = path.join(dir, entry.name);
      if (entry.isDirectory()) {
        await walk(fullPath, topFolder);
      } else if (entry.isFile() && isImage(entry.name)) {
        const relPath = path.relative(baseDir, fullPath);
        (groups[topFolder] ??= []).push(relPath);
      }
    }
  }

  let topEntries;
  try {
    topEntries = await readdir(baseDir, { withFileTypes: true });
  } catch {
    return groups;
  }

  for (const entry of topEntries) {
    if (entry.isDirectory()) {
      await walk(path.join(baseDir, entry.name), entry.name);
    } else if (entry.isFile() && isImage(entry.name)) {
      (groups["(root)"] ??= []).push(entry.name);
    }
  }

  for (const key of Object.keys(groups)) groups[key].sort();
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
#sidebar { width: 220px; min-width: 220px; overflow-y: auto; border-right: 1px solid #2a2a2a; padding: 8px; }
#sidebar h2 { font-size: 11px; text-transform: uppercase; letter-spacing: 0.1em; color: #555; margin-bottom: 8px; padding: 2px 6px; }
.folder { padding: 5px 8px; cursor: pointer; border-radius: 4px; font-size: 13px; margin-bottom: 1px; display: flex; justify-content: space-between; align-items: center; }
.folder:hover { background: #1e1e1e; }
.folder.active { background: #1a3a6a; color: #fff; }
.folder-name { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.folder-count { color: #555; font-size: 11px; margin-left: 6px; flex-shrink: 0; }
.folder.active .folder-count { color: #aaa; }
#main { flex: 1; display: flex; flex-direction: column; overflow: hidden; }
#toolbar { padding: 6px 12px; border-bottom: 1px solid #1e1e1e; font-size: 12px; color: #666; display: flex; align-items: center; gap: 8px; min-height: 32px; }
#img-name { color: #aaa; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
#img-counter { margin-left: auto; flex-shrink: 0; }
#viewer { flex: 1; display: flex; align-items: center; justify-content: center; overflow: hidden; cursor: zoom-in; position: relative; }
#viewer.zoomed { cursor: zoom-out; }
#current-img { max-width: 100%; max-height: 100%; object-fit: contain; transform-origin: center; user-select: none; -webkit-user-drag: none; }
#empty { color: #444; font-size: 16px; }
</style>
</head>
<body>
<div id="sidebar">
  <h2>Folders</h2>
  <div id="folder-list"></div>
</div>
<div id="main">
  <div id="toolbar">
    <span id="img-name">—</span>
    <span id="img-counter"></span>
  </div>
  <div id="viewer">
    <img id="current-img" style="display:none" draggable="false">
    <div id="empty">No images found</div>
  </div>
</div>
<script>
let data = {}, folders = [], folder = null, idx = 0, zoom = 1;
const img = document.getElementById('current-img');
const empty = document.getElementById('empty');
const folderList = document.getElementById('folder-list');
const imgName = document.getElementById('img-name');
const imgCounter = document.getElementById('img-counter');
const viewer = document.getElementById('viewer');

async function load() {
  data = await fetch('/api/images').then(r => r.json());
  folders = Object.keys(data).sort();
  folderList.innerHTML = '';
  for (const f of folders) {
    const el = document.createElement('div');
    el.className = 'folder';
    el.dataset.f = f;
    el.innerHTML = '<span class="folder-name">' + f + '</span><span class="folder-count">' + data[f].length + '</span>';
    el.onclick = () => pick(f);
    folderList.appendChild(el);
  }
  const hash = location.hash.slice(1);
  if (hash) {
    const slash = hash.lastIndexOf('/');
    const f = decodeURIComponent(hash.slice(0, slash));
    const i = parseInt(hash.slice(slash + 1));
    if (data[f] && i >= 0 && i < data[f].length) {
      folder = f; idx = i;
      document.querySelectorAll('.folder').forEach(el => el.classList.toggle('active', el.dataset.f === f));
      show();
      return;
    }
  }
  if (folders.length) pick(folders[0]);
}

function pick(f) {
  folder = f; idx = 0;
  setZoom(1);
  document.querySelectorAll('.folder').forEach(el => el.classList.toggle('active', el.dataset.f === f));
  show();
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
  const imgs = data[folder] ?? [];
  if (!imgs.length) { img.style.display = 'none'; empty.style.display = ''; return; }
  img.style.display = '';
  empty.style.display = 'none';
  img.src = imgUrl(imgs[idx]);
  imgName.textContent = imgs[idx].split('/').pop();
  imgCounter.textContent = (idx + 1) + ' / ' + imgs.length;
  history.replaceState(null, '', '#' + encodeURIComponent(folder) + '/' + idx);
  preload(imgs, idx + 1, 3);
}

function setZoom(z) {
  zoom = Math.max(0.2, Math.min(5, z));
  img.style.transform = zoom === 1 ? '' : 'scale(' + zoom + ')';
  viewer.classList.toggle('zoomed', zoom > 1);
}

document.addEventListener('keydown', e => {
  if (!folder) return;
  const imgs = data[folder] ?? [], fi = folders.indexOf(folder);
  if (e.key === 'ArrowRight' || e.key === 'ArrowDown') { if (idx < imgs.length - 1) { idx++; show(); } }
  else if (e.key === 'ArrowLeft' || e.key === 'ArrowUp') { if (idx > 0) { idx--; show(); } }
  else if (e.key === ']') { if (fi < folders.length - 1) pick(folders[fi + 1]); }
  else if (e.key === '[') { if (fi > 0) pick(folders[fi - 1]); }
  else if (e.key === '+' || e.key === '=') setZoom(zoom * 1.25);
  else if (e.key === '-') setZoom(zoom / 1.25);
  else if (e.key === '0') setZoom(1);
});

viewer.addEventListener('wheel', e => { e.preventDefault(); setZoom(e.deltaY < 0 ? zoom * 1.1 : zoom / 1.1); }, { passive: false });
viewer.addEventListener('click', () => setZoom(zoom > 1 ? 1 : 2));

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
