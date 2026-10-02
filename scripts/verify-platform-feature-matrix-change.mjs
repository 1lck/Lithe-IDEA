#!/usr/bin/env node

import { execFileSync } from "node:child_process";
import { isDeepStrictEqual } from "node:util";

const git = (...args) => execFileSync("git", args, { encoding: "utf8", timeout: 10_000 });
const base = process.argv[2] || process.env.MATRIX_BASE_SHA;
const head = process.argv[3] || process.env.MATRIX_HEAD_SHA || "HEAD";
if (!base) throw new Error("provide <base> <head> or MATRIX_BASE_SHA");
const platformPaths = ["macos/Sources", "windows/tauri/src", "windows/tauri/src-tauri", "Plugins/mac", "Plugins/win", "frontend/editor", "rust/lithe-core", "shared/contracts"];
const changed = (paths) => git("diff", "--name-only", "--no-renames", "-z", base, head, "--", ...paths).split("\0").filter(Boolean);
if (changed(platformPaths).length === 0) {
  console.log("matrix change gate passed: no platform implementation paths changed");
} else if (process.env.MATRIX_UPDATE_EXEMPT === "true") {
  console.log("matrix change gate passed: explicit matrix-exempt label is present");
} else {
  const directory = "shared/platform-feature-matrix/features/";
  const filesAt = (revision) => new Set(git("ls-tree", "-r", "--name-only", "-z", revision, "--", directory).split("\0").filter(Boolean));
  const baseFiles = filesAt(base);
  const headFiles = filesAt(head);
  const read = (revision, file, files) => {
    if (!files.has(file)) return null;
    const value = JSON.parse(git("show", `${revision}:${file}`));
    // Review dates are useful context, but do not describe changed capability behavior.
    delete value.lastReviewed;
    return value;
  };
  const hasCapabilityChange = changed([directory]).some((file) =>
    /^shared\/platform-feature-matrix\/features\/[a-z0-9]+(?:-[a-z0-9]+)*\.json$/.test(file)
    && !isDeepStrictEqual(read(base, file, baseFiles), read(head, file, headFiles)));
  if (!hasCapabilityChange) throw new Error("Platform implementation changed without a substantive capability update in shared/platform-feature-matrix/features/. Update the relevant capability, or request matrix-exempt for a reviewed non-user-visible refactor.");
  console.log("matrix change gate passed: capability records changed (relevance requires review)");
}
