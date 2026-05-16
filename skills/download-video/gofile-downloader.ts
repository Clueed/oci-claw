#!/usr/bin/env bun

import { createHash } from "crypto";
import { mkdir, rename, stat, readdir, rmdir } from "fs/promises";
import { existsSync, createWriteStream } from "fs";
import { join, dirname, basename, extname } from "path";
import { cwd } from "process";

function generateWebsiteToken(userAgent: string, accountToken: string): string {
  const timeSlot = Math.floor(Date.now() / 1000 / 14400);
  const raw = `${userAgent}::en-US::${accountToken}::${timeSlot}::5d4f7g8sd45fsd`;
  return createHash("sha256").update(raw).digest("hex");
}

interface FileInfo {
  path: string;
  filename: string;
  link: string;
}

interface ChildItem {
  id: string;
  type: "folder" | "file";
  name: string;
  link?: string;
}

class Downloader {
  private filesInfo: Record<string, FileInfo> = {};
  private stopEvent = false;

  constructor(
    private rootDir: string,
    private maxWorkers: number,
    private numberRetries: number,
    private timeout: number,
    private session: { headers: Record<string, string> },
    private url: string,
    private password: string | null = null,
  ) {}

  async run(): Promise<void> {
    const parts = this.url.split("/");
    if (parts.length < 2 || parts[parts.length - 2] !== "d") {
      return;
    }
    const contentId = parts[parts.length - 1];
    const _password = this.password ? createHash("sha256").update(this.password).digest("hex") : null;
    const contentDir = join(this.rootDir, contentId);
    await this.buildContentTreeStructure(contentDir, contentId, _password);

    if (existsSync(contentDir)) {
      const entries = await readdir(contentDir);
      if (entries.length === 0 && Object.keys(this.filesInfo).length === 0) {
        await this.removeDir(contentDir);
        return;
      }
    }

    await this.threadedDownloads();
  }

  private async fetchJson(url: string, headers?: Record<string, string>): Promise<any> {
    for (let i = 0; i < this.numberRetries; i++) {
      try {
        const res = await fetch(url, {
          headers: { ...this.session.headers, ...headers },
          signal: AbortSignal.timeout(this.timeout * 1000),
        });
        return await res.json();
      } catch {
        continue;
      }
    }
    return null;
  }

  private async buildContentTreeStructure(
    parentDir: string,
    contentId: string,
    password: string | null = null,
    pathingCount: Record<string, number> = {},
    fileIndex = { value: 0 },
  ): Promise<void> {
    let url = `https://api.gofile.io/contents/${contentId}?cache=true&sortField=createTime&sortDirection=1`;
    if (password) url = `${url}&password=${password}`;

    const userAgent = this.session.headers["User-Agent"] || "Mozilla/5.0";
    const authHeader = this.session.headers["Authorization"] || "";
    const accountToken = authHeader.replace("Bearer ", "");
    const wt = generateWebsiteToken(userAgent, accountToken);

    const jsonResponse = await this.fetchJson(url, {
      "X-Website-Token": wt,
      "X-BL": "en-US",
    });

    if (!jsonResponse || jsonResponse.status !== "ok") {
      console.error(`API error for ${contentId}`);
      return;
    }

    const data = jsonResponse.data;
    if (data.password && data.passwordStatus && data.passwordStatus !== "passwordOk") {
      console.error(`Password required for ${contentId}`);
      return;
    }

    if (data.type !== "folder") {
      const filepath = this.resolveNamingCollision(pathingCount, parentDir, data.name);
      this.registerFile(fileIndex, filepath, data.link);
      return;
    }

    const folderName = data.name;
    let absolutePath = this.resolveNamingCollision(pathingCount, parentDir, folderName);

    if (basename(parentDir) === contentId) {
      absolutePath = parentDir;
    }

    await mkdir(absolutePath, { recursive: true });

    const children: Record<string, ChildItem> = data.children || {};
    for (const child of Object.values(children)) {
      if (child.type === "folder") {
        await this.buildContentTreeStructure(absolutePath, child.id, password, pathingCount, fileIndex);
      } else {
        const filepath = this.resolveNamingCollision(pathingCount, absolutePath, child.name);
        this.registerFile(fileIndex, filepath, child.link!);
      }
    }
  }

  private resolveNamingCollision(
    pathingCount: Record<string, number>,
    absoluteParentDir: string,
    childName: string,
    isDir = false,
  ): string {
    const filepath = join(absoluteParentDir, childName);
    if (filepath in pathingCount) {
      pathingCount[filepath] += 1;
    } else {
      pathingCount[filepath] = 0;
    }
    if (pathingCount[filepath] > 0 && isDir) {
      return `${filepath}(${pathingCount[filepath]})`;
    }
    if (pathingCount[filepath] > 0) {
      const ext = extname(filepath);
      const root = filepath.slice(0, -ext.length);
      return `${root}(${pathingCount[filepath]})${ext}`;
    }
    return filepath;
  }

  private registerFile(fileIndex: { value: number }, filepath: string, fileUrl: string): void {
    this.filesInfo[String(fileIndex.value++)] = {
      path: dirname(filepath),
      filename: basename(filepath),
      link: fileUrl,
    };
  }

  private async threadedDownloads(): Promise<void> {
    const items = Object.values(this.filesInfo);
    for (let i = 0; i < items.length; i += this.maxWorkers) {
      const batch = items.slice(i, i + this.maxWorkers);
      await Promise.all(batch.map((item) => this.downloadContent(item)));
    }
  }

  private async downloadContent(fileInfo: FileInfo): Promise<void> {
    const filepath = join(fileInfo.path, fileInfo.filename);

    if (existsSync(filepath)) {
      const st = await stat(filepath);
      if (st.size > 0) return;
    }

    const tmpFile = `${filepath}.part`;
    const url = fileInfo.link;

    for (let retry = 0; retry < this.numberRetries; retry++) {
      if (this.stopEvent) return;

      let partSize = 0;
      const headers: Record<string, string> = {};

      if (existsSync(tmpFile)) {
        partSize = (await stat(tmpFile)).size;
        if (partSize > 0) {
          headers["Range"] = `bytes=${partSize}-`;
        }
      }

      try {
        const response = await fetch(url, {
          headers: { ...this.session.headers, ...headers },
          signal: AbortSignal.timeout(this.timeout * 1000),
        });

        if (response.status === 416 && existsSync(tmpFile)) {
          const finalSize = (await stat(tmpFile)).size;
          process.stdout.write(`${fileInfo.filename}: ${finalSize} of ${finalSize} Done!\n`);
          await rename(tmpFile, filepath);
          return;
        }

        if (!response.ok && response.status !== 206) {
          return;
        }

        const contentLength = response.headers.get("Content-Length");
        const contentRange = response.headers.get("Content-Range");
        const hasSize = partSize === 0
          ? contentLength
          : contentRange?.split("/").pop();

        if (!hasSize) return;

        const totalSize = parseFloat(hasSize);

        if (partSize >= totalSize) {
          process.stdout.write(`${fileInfo.filename}: ${partSize} of ${Math.floor(totalSize)} Done!\n`);
          await rename(tmpFile, filepath);
          return;
        }

        const startTime = performance.now();
        const writer = createWriteStream(tmpFile, { flags: "a" });
        const reader = response.body?.getReader();
        if (!reader) return;

        let downloaded = partSize;

        while (true) {
          const { done, value } = await reader.read();
          if (done) break;
          writer.write(Buffer.from(value));
          downloaded += value.length;
          const elapsed = (performance.now() - startTime) / 1000;
          const rate = elapsed > 0 ? (downloaded - partSize) / elapsed : 0;
          const rateStr = rate >= 1024 ** 2
            ? `${(rate / 1024 ** 2).toFixed(1)}MB/s`
            : rate >= 1024
            ? `${(rate / 1024).toFixed(1)}KB/s`
            : `${rate.toFixed(1)}B/s`;
          process.stdout.write(`\r${fileInfo.filename}: ${(downloaded / 1024 ** 2).toFixed(1)}/${(totalSize / 1024 ** 2).toFixed(1)}MB ${((downloaded / totalSize) * 100).toFixed(0)}% ${rateStr}`);
        }

        writer.end();
        await new Promise((resolve) => writer.on("finish", resolve));

        const finalSize = (await stat(tmpFile)).size;
        if (finalSize === Math.floor(totalSize)) {
          process.stdout.write(`\r${fileInfo.filename}: ${(finalSize / 1024 ** 2).toFixed(1)}MB Done!\n`);
          await rename(tmpFile, filepath);
        }
        return;
      } catch {
        continue;
      }
    }
  }

  private async removeDir(dirname: string): Promise<void> {
    try {
      if (existsSync(dirname)) {
        await rmdir(dirname);
      }
    } catch {}
  }
}

class Manager {
  private session: { headers: Record<string, string> } = { headers: {} };
  private maxWorkers = 5;
  private numberRetries = 5;
  private timeout = 30;

  constructor(
    private urlOrFile: string,
    private password: string | null = null,
  ) {}

  async run(): Promise<void> {
    this.session.headers = {
      "User-Agent": "Mozilla/5.0",
      "Accept": "*/*",
      "Origin": "https://gofile.io",
      "Referer": "https://gofile.io/",
      "Accept-Encoding": "gzip",
    };
    await this.setAccountAccessToken();
    await this.parseUrlOrFile();
  }

  private async setAccountAccessToken(token?: string): Promise<void> {
    if (token) return;

    const userAgent = this.session.headers["User-Agent"] || "Mozilla/5.0";
    const wt = generateWebsiteToken(userAgent, "");

    for (let i = 0; i < this.numberRetries; i++) {
      try {
        const res = await fetch("https://api.gofile.io/accounts", {
          method: "POST",
          headers: {
            "X-Website-Token": wt,
            "X-BL": "en-US",
          },
          signal: AbortSignal.timeout(this.timeout * 1000),
        });
        const json = await res.json();
        if (json.status === "ok") {
          const token = json.data.token;
          this.session.headers["Authorization"] = `Bearer ${token}`;
          this.session.headers["Cookie"] = `accountToken=${token}`;
        }
        return;
      } catch {
        continue;
      }
    }
  }

  private async parseUrlOrFile(): Promise<void> {
    const downloader = new Downloader(
      cwd(),
      this.maxWorkers,
      this.numberRetries,
      this.timeout,
      this.session,
      this.urlOrFile,
      this.password,
    );
    await downloader.run();
  }
}

const args = process.argv.slice(2);
if (args.length < 1) {
  console.error("Usage: bun gofile-downloader.ts <url> [password]");
  process.exit(1);
}

const manager = new Manager(args[0], args[1] || null);
await manager.run();
