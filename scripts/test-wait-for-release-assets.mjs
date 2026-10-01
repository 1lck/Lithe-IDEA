#!/usr/bin/env node

import assert from "node:assert/strict";
import test from "node:test";

import {
  missingReleaseAssets,
  waitForReleaseAssets,
} from "./wait-for-release-assets.mjs";

const release = (assets) => ({ assets: assets.map((name) => ({ name, state: "uploaded" })) });

test("requires uploaded assets and ignores in-progress attachments", () => {
  assert.deepEqual(
    missingReleaseAssets(
      { assets: [{ name: "appcast-arm64.xml", state: "new" }, { name: "latest.json", state: "uploaded" }] },
      ["appcast-arm64.xml", "latest.json"],
    ),
    ["appcast-arm64.xml"],
  );
});

test("waits for all assets with deterministic injected time", async () => {
  let reads = 0;
  let currentTime = 0;
  await waitForReleaseAssets({
    requiredAssets: ["macos.xml", "windows.json"],
    now: () => currentTime,
    pollMs: 10,
    sleep: async (milliseconds) => { currentTime += milliseconds; },
    readRelease: async () => {
      reads += 1;
      return reads < 3 ? release(["macos.xml"]) : release(["macos.xml", "windows.json"]);
    },
    timeoutMs: 100,
  });
  assert.equal(reads, 3);
});

test("reports missing assets when the deadline expires", async () => {
  await assert.rejects(
    waitForReleaseAssets({
      requiredAssets: ["macos.xml", "windows.json"],
      readRelease: async () => release(["macos.xml"]),
      timeoutMs: 5,
      pollMs: 5,
      now: (() => { let current = 0; return () => current++; })(),
      sleep: async () => {},
    }),
    /Timed out waiting for release assets: windows\.json/,
  );
});
