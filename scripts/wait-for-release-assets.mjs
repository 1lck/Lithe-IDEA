#!/usr/bin/env node

import { execFileSync } from "node:child_process";

const DEFAULT_TIMEOUT_MS = 30 * 60 * 1000;
const DEFAULT_POLL_MS = 15 * 1000;

export function missingReleaseAssets(release, requiredAssets) {
  const uploaded = new Set(
    (release?.assets ?? [])
      .filter((asset) => asset.state === undefined || asset.state === "uploaded")
      .map((asset) => asset.name),
  );
  return requiredAssets.filter((asset) => !uploaded.has(asset));
}

export async function waitForReleaseAssets({
  readRelease,
  requiredAssets,
  timeoutMs = DEFAULT_TIMEOUT_MS,
  pollMs = DEFAULT_POLL_MS,
  now = () => Date.now(),
  sleep = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds)),
}) {
  if (!requiredAssets.length) throw new Error("At least one release asset is required");
  const deadline = now() + timeoutMs;
  let missing = requiredAssets;
  while (true) {
    missing = missingReleaseAssets(await readRelease(), requiredAssets);
    if (!missing.length) return;
    const remaining = deadline - now();
    if (remaining <= 0) {
      throw new Error(`Timed out waiting for release assets: ${missing.join(", ")}`);
    }
    await sleep(Math.min(pollMs, remaining));
  }
}

function argumentValues(argumentsList, name) {
  return argumentsList
    .flatMap((value, index) => (value === name ? [argumentsList[index + 1]] : []))
    .filter((value) => value !== undefined);
}

function parseArguments(argumentsList) {
  const repository = argumentValues(argumentsList, "--repository")[0];
  const tag = argumentValues(argumentsList, "--tag")[0];
  const requiredAssets = argumentValues(argumentsList, "--required-asset");
  const timeoutSeconds = Number(argumentValues(argumentsList, "--timeout-seconds")[0] ?? 1800);
  if (!/^[\w.-]+\/[\w.-]+$/.test(repository ?? "")) {
    throw new Error("Repository must use the form OWNER/REPO");
  }
  if (!/^[A-Za-z0-9._-]+$/.test(tag ?? "")) throw new Error("Invalid release tag");
  if (!requiredAssets.length) throw new Error("At least one --required-asset is required");
  if (!Number.isFinite(timeoutSeconds) || timeoutSeconds <= 0) {
    throw new Error("Timeout must be a positive number of seconds");
  }
  return { repository, tag, requiredAssets, timeoutMs: timeoutSeconds * 1000 };
}

function readReleaseWithGitHubCLI(repository, tag) {
  try {
    return JSON.parse(
      execFileSync("gh", ["api", `repos/${repository}/releases/tags/${encodeURIComponent(tag)}`], {
        encoding: "utf8",
        stdio: ["ignore", "pipe", "pipe"],
      }),
    );
  } catch (error) {
    if (error?.status === 1 && /404|not found/i.test(String(error.stderr ?? ""))) return null;
    throw new Error("Could not read the GitHub Release while waiting for assets");
  }
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const options = parseArguments(process.argv.slice(2));
  await waitForReleaseAssets({
    ...options,
    readRelease: () => readReleaseWithGitHubCLI(options.repository, options.tag),
  });
  console.log(`Release ${options.tag} contains all required assets`);
}
