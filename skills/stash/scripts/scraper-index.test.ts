#!/usr/bin/env bun

/**
 * Tests for the pure parts of scraper-index.ts — the pieces that decide which
 * scrapers a scene is allowed to touch.
 *
 * `parseFragmentBlock` is deliberately a line-based parser rather than a real
 * YAML parse, so it is the thing most likely to break silently when upstream
 * reformats a scraper. A wrong answer here is not a crash: it either drops a
 * good scraper from tier 2 or admits a catch-all that matches every file.
 *
 *   bun test <skill-path>/scripts/scraper-index.test.ts
 */

import { expect, test, describe } from "bun:test";
import { compileGoRegex, computeSelectivity, parseFragmentBlock, tokenize } from "./scraper-index.ts";

/** Shape of the scraper that started all this: a real ID regex on {filename}. */
const TENMUSUME_YML = `name: "10Musume-JP"
sceneByFragment:
  action: scrapeJson
  queryURL: https://www.10musume.com/dyn/phpauto/movie_details/movie_id/{filename}.json
  queryURLReplace:
    filename:
      - regex: ^(\\d{6}_\\d{2}).*$
        with: $1
  scraper: sceneScraper
sceneByURL:
  - action: scrapeJson
`;

/** A cleanup-only rule: strips the extension, matches literally every file. */
const DMM_YML = `sceneByFragment:
  action: scrapeXPath
  queryURL: https://dmm.co.jp/search/?q={filename}
  queryURLReplace:
    filename:
      - regex: \\..+$
        with: ""
  scraper: sceneScraper
`;

describe("parseFragmentBlock", () => {
  test("extracts placeholder, action and the filename regexes", () => {
    const f = parseFragmentBlock(TENMUSUME_YML);
    expect(f?.placeholder).toBe("filename");
    expect(f?.action).toBe("scrapeJson");
    expect(f?.regexes).toEqual(["^(\\d{6}_\\d{2}).*$"]);
  });

  test("stops at the next top-level key", () => {
    // sceneByURL's own action must not leak into the fragment block.
    const f = parseFragmentBlock(TENMUSUME_YML);
    expect(f?.regexes).toHaveLength(1);
  });

  test("returns undefined when the scraper has no fragment support", () => {
    expect(parseFragmentBlock(`name: X\nsceneByURL:\n  - action: scrapeXPath\n`)).toBeUndefined();
  });

  test("keeps catch-all cleanup regexes (selectivity is what rejects them)", () => {
    expect(parseFragmentBlock(DMM_YML)?.regexes).toEqual(["\\..+$"]);
  });

  test("ignores regexes under a different placeholder's key", () => {
    const yml = `sceneByFragment:
  queryURL: https://x/{filename}
  queryURLReplace:
    url:
      - regex: ^https
        with: http
    filename:
      - regex: ^abp-(\\d+)$
        with: $1
`;
    expect(parseFragmentBlock(yml)?.regexes).toEqual(["^abp-(\\d+)$"]);
  });

  test("strips trailing YAML comments without eating a literal #", () => {
    const yml = `sceneByFragment:
  queryURL: https://x/{filename}
  queryURLReplace:
    filename:
      - regex: '^(?:Goddess)(?:#)?(\\d+)' # site - performers - #code
        with: $1
      - regex: ^abp-(\\d+)$   # unquoted, comment still goes
        with: $1
`;
    expect(parseFragmentBlock(yml)?.regexes).toEqual(["^(?:Goddess)(?:#)?(\\d+)", "^abp-(\\d+)$"]);
  });

  test("unquotes single- and double-quoted regexes", () => {
    const yml = `sceneByFragment:
  queryURL: https://x/{filename}
  queryURLReplace:
    filename:
      - regex: '^a-(\\d+)$'
        with: $1
      - regex: "^b-(\\d+)$"
        with: $1
`;
    expect(parseFragmentBlock(yml)?.regexes).toEqual(["^a-(\\d+)$", "^b-(\\d+)$"]);
  });
});

describe("compileGoRegex", () => {
  test("translates a leading inline flag group JS would reject", () => {
    expect(() => new RegExp("(?i)abp-\\d+")).toThrow(); // the whole reason this exists
    const rx = compileGoRegex("(?i)abp-(\\d+)");
    expect(rx).not.toBeNull();
    expect(rx!.flags).toBe("i");
    expect(rx!.test("ABP-123.mp4")).toBe(true);
  });

  test("handles combined flags", () => {
    expect(compileGoRegex("(?is)a.b")!.flags).toBe("is");
  });

  test("compiles a plain regex unchanged", () => {
    const rx = compileGoRegex("^(\\d{6}_\\d{2}).*$");
    expect(rx!.test("010124_01.mp4")).toBe(true);
    expect(rx!.test("gachiPPV-1045-1.wmv")).toBe(false);
  });

  test("returns null for syntax JS cannot parse", () => {
    expect(compileGoRegex("(?P<id>\\d+)")).toBeNull();
    expect(compileGoRegex("a(")).toBeNull();
  });
});

describe("computeSelectivity", () => {
  const sample = ["010124_01.mp4", "gachiPPV-1045-1.wmv", "Aika.wmv", "video.mp4"];

  test("a real ID pattern rejects most of the library", () => {
    const rx = [compileGoRegex("^(\\d{6}_\\d{2}).*$")!];
    expect(computeSelectivity(rx, sample)).toBe(0.75);
  });

  test("a catch-all cleanup rule scores ~0", () => {
    const rx = [compileGoRegex("\\..+$")!];
    expect(computeSelectivity(rx, sample)).toBe(0);
  });

  test("no compilable regexes means no evidence, not perfect evidence", () => {
    expect(computeSelectivity([], sample)).toBe(0);
  });

  test("an empty sample cannot prove selectivity", () => {
    expect(computeSelectivity([compileGoRegex("^x$")!], [])).toBe(0);
  });
});

describe("tokenize", () => {
  test("drops the TLD and lowercases", () => {
    expect(tokenize("www.BangBros.com")).toEqual(["www", "bangbros"]);
  });

  test("splits on punctuation and drops fragments under 3 chars", () => {
    // "jp" is dropped; the leading digits stay attached (see note below).
    expect(tokenize("10Musume-JP")).toEqual(["10musume"]);
  });

  test("splits letter->digit boundaries", () => {
    expect(tokenize("Brazzers2")).toEqual(["brazzers", "2"].filter(w => w.length >= 3));
  });

  // NOTE: tokenize lowercases before splitting, so camelCase boundaries are
  // gone by the time the split runs — "BangBros" stays one token, and the
  // digit split only fires letter->digit, never digit->letter ("10Musume").
  // Affinity matching compares tokens on both sides, so identical inputs still
  // agree; it just can't match "bangbros" against a path that says "bang bros".
  test("does not recover camelCase boundaries (documents current behaviour)", () => {
    expect(tokenize("BangBros")).toEqual(["bangbros"]);
  });
});
