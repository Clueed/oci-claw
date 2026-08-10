#!/usr/bin/env bun

/**
 * Tests for the gate that decides whether a stash-box hit may be written back
 * unattended. Everything else in scrape-auto.ts talks to stash; this is the
 * one piece of pure logic, and getting it wrong means --apply overwrites a
 * scene with a *perceptually similar* stranger's metadata.
 *
 *   bun test <skill-path>/scripts/scrape-auto.test.ts
 */

import { expect, test, describe } from "bun:test";
import { stashBoxConfidence } from "./scrape-auto.ts";

const OURS = "8b5f86f8767ed117";
const mine = new Set([OURS]);

describe("stashBoxConfidence", () => {
  test("an exact oshash in the remote fingerprint list is proof", () => {
    const r = { fingerprints: [{ algorithm: "PHASH", hash: "d2ea…" }, { algorithm: "OSHASH", hash: OURS }] };
    expect(stashBoxConfidence(r, mine)).toBe("high");
  });

  test("matching the algorithm case-insensitively", () => {
    expect(stashBoxConfidence({ fingerprints: [{ algorithm: "oshash", hash: OURS.toUpperCase() }] }, mine))
      .toBe("high");
  });

  // The box returns every fingerprint it holds for the matched scene, so a
  // long OSHASH list proves nothing on its own — none of them are ours.
  test("other people's oshashes are not our oshash", () => {
    const r = {
      fingerprints: [
        { algorithm: "OSHASH", hash: "6d660c27c2a636e4" },
        { algorithm: "OSHASH", hash: "9be8bde7a38eebee" },
        { algorithm: "PHASH", hash: "ba3272a2c6e64cd5" },
      ],
    };
    expect(stashBoxConfidence(r, mine)).toBe("medium");
  });

  test("a phash-only match is a similarity, not an identity", () => {
    expect(stashBoxConfidence({ fingerprints: [{ algorithm: "PHASH", hash: "d2ea8f891c9a6c3a" }] }, mine))
      .toBe("medium");
  });

  test("no fingerprints returned means unproven, never proven", () => {
    expect(stashBoxConfidence({ title: "x" }, mine)).toBe("medium");
    expect(stashBoxConfidence({ fingerprints: [] }, mine)).toBe("medium");
    expect(stashBoxConfidence(undefined, mine)).toBe("medium");
  });

  test("a scene with no local oshash can never be proven this way", () => {
    expect(stashBoxConfidence({ fingerprints: [{ algorithm: "OSHASH", hash: OURS }] }, new Set()))
      .toBe("medium");
  });
});
