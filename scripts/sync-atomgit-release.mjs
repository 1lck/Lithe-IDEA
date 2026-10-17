#!/usr/bin/env node
// Decision: .agents/notes/implemented/process/2026-09-22-atomgit-release-sync.md
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { openAsBlob, createWriteStream } from "node:fs";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pipeline } from "node:stream/promises";
import { pathToFileURL } from "node:url";

const API_TIMEOUT = 60_000;
const TRANSFER_TIMEOUT = 15 * 60_000;
// Stalled AtomGit transfers rarely recover, so give up early and retry instead.
const ATOMGIT_TRANSFER_TIMEOUT = 5 * 60_000;
const PUSH_TIMEOUT = 10 * 60_000;
const ASSET_ATTEMPTS = 4;
const RETRY_DELAY = 30_000;
const TRANSIENT_FAILURE =
  /^(Release sync HTTP 5\d\d|Release sync request failed or timed out|Uploaded attachment is not visible|AtomGit attachment digest mismatch)/;
const encode = encodeURIComponent;
const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// In-app updates keep using GitHub, so only installers users download by hand are mirrored.
export function mirroredAsset(name, tag) {
  const version = tag.slice(1);
  return [
    `Lithe-${version}-arm64.dmg`,
    `Lithe-${version}-x86_64.dmg`,
    `Lithe-${version}-windows-x64.exe`,
  ].some((installer) => name === installer || name === `${installer}.sha256`);
}

export function tagCommit(output, tag) {
  const refs = new Map(
    output
      .trim()
      .split("\n")
      .map((line) => {
        const [sha, ref] = line.split(/\s+/);
        return [ref, sha];
      }),
  );
  const commit =
    refs.get(`refs/tags/${tag}^{}`) ?? refs.get(`refs/tags/${tag}`);
  if (!/^[a-f0-9]{40}$/.test(commit ?? ""))
    throw new Error("Tag missing; synchronize repository tags first");
  return commit;
}

export function releasePayload(release, latestTag) {
  if (
    release.draft ||
    release.prerelease ||
    !/^v\d+\.\d+\.\d+$/.test(release.tag_name)
  ) {
    throw new Error("Only published stable version tags can be synchronized");
  }
  if (!release.body?.trim()) throw new Error("Release notes must not be empty");
  return {
    name: release.name || release.tag_name,
    body: release.body,
    ...(release.tag_name === latestTag ? { release_status: "latest" } : {}),
  };
}

// AtomGit mirrors tags on its own schedule, which usually lags behind a fresh release.
// Pushing the exact GitHub tag (never forced) keeps a stale or diverged tag a hard failure.
async function targetTagCommit(target, tag, sourceCommit) {
  const existing = await target.commit(tag);
  if (existing) return existing;
  try {
    await target.pushTag(tag, sourceCommit);
  } catch (error) {
    // The mirror may have created the tag concurrently; the re-read below decides.
    const pushed = await target.commit(tag);
    if (pushed) return pushed;
    throw error;
  }
  return target.commit(tag);
}

// Each attempt re-reads the target so a partial earlier attempt is compared, not duplicated.
async function mirrorAsset({ target, tag, name, file, digest, log }) {
  const matches = ((await target.release(tag))?.assets ?? []).filter(
    (entry) => entry.name === name,
  );
  if (matches.length > 1)
    throw new Error("Duplicate target asset names; resolve before retrying");
  const previous = matches[0];
  if (previous && (await target.digest(previous)) === digest) {
    log(`Unchanged: ${name}`);
    return;
  }
  if (previous && !Number.isInteger(previous.id))
    throw new Error("Target attachment has no deletion ID");
  if (previous) await target.remove(tag, previous.id);
  await target.upload(tag, name, file);
  log(`Uploaded: ${name}`);
}

// The injected boundary keeps orchestration tests offline and deterministic.
export async function synchronize({
  source,
  target,
  tag,
  log = console.log,
  wait = delay,
}) {
  if (!/^v\d+\.\d+\.\d+$/.test(tag))
    throw new Error("Expected a stable tag such as v1.2.3");
  const release = await source.release(tag);
  const payload = releasePayload(release, await source.latestTag());
  const sourceCommit = await source.commit(tag);
  if (sourceCommit !== (await targetTagCommit(target, tag, sourceCommit)))
    throw new Error("GitHub and AtomGit tags point to different commits");
  const assets = (await source.assets(release.id)).filter((asset) =>
    mirroredAsset(asset.name, tag),
  );
  if (!assets.length)
    throw new Error(
      "GitHub Release has no installers yet; retry after publication",
    );
  if (new Set(assets.map((asset) => asset.name)).size !== assets.length)
    throw new Error("Duplicate source asset names");
  if (await target.release(tag)) {
    await target.update(tag, payload);
  } else {
    await target.create({
      ...payload,
      tag_name: tag,
      target_commitish: sourceCommit,
    });
  }
  for (const asset of assets) {
    if (asset.state !== "uploaded")
      throw new Error("A GitHub asset is still uploading; retry later");
    // Download and validate the replacement before removing any existing file.
    await source.withAsset(asset, async (file, digest) => {
      for (let attempt = 1; ; attempt++) {
        try {
          await mirrorAsset({
            target,
            tag,
            name: asset.name,
            file,
            digest,
            log,
          });
          return;
        } catch (error) {
          if (
            attempt >= ASSET_ATTEMPTS ||
            !TRANSIENT_FAILURE.test(error.message)
          )
            throw error;
          log(`Retrying ${asset.name} after: ${error.message}`);
          await wait(RETRY_DELAY * 2 ** (attempt - 1));
        }
      }
    });
  }
  log(`Synchronized ${tag}`);
}

async function response(
  url,
  options = {},
  timeout = API_TIMEOUT,
  allow404 = false,
) {
  let result;
  try {
    result = await fetch(url, {
      ...options,
      signal: AbortSignal.timeout(timeout),
    });
  } catch {
    // Do not expose request URLs, tokens, signed upload URLs, or provider bodies.
    throw new Error("Release sync request failed or timed out");
  }
  if (allow404 && result.status === 404) return null;
  if (!result.ok) throw new Error(`Release sync HTTP ${result.status}`);
  return result;
}

async function hashResponse(result) {
  const hash = createHash("sha256");
  try {
    for await (const chunk of result.body) hash.update(chunk);
  } catch {
    // A body that stalls past its deadline is as transient as a failed request.
    throw new Error("Release sync request failed or timed out");
  }
  return hash.digest("hex");
}

function httpsURL(value) {
  const url = new URL(value);
  if (url.protocol !== "https:" || url.username || url.password)
    throw new Error("Expected an HTTPS transfer URL");
  return url;
}

export function clients(env) {
  const repository = env.GITHUB_REPOSITORY;
  const owner = env.ATOMGIT_OWNER;
  const repo = env.ATOMGIT_REPO;
  for (const value of [
    repository,
    owner,
    repo,
    env.GH_TOKEN,
    env.ATOMGIT_TOKEN,
  ]) {
    if (!value) throw new Error("Missing release sync configuration");
  }
  if (
    !/^[\w.-]+\/[\w.-]+$/.test(repository) ||
    !/^[\w.-]+$/.test(owner) ||
    !/^[\w.-]+$/.test(repo)
  ) {
    throw new Error("Invalid repository path");
  }
  const githubBase = `https://api.github.com/repos/${repository}`;
  const atomBase = `https://api.atomgit.com/api/v5/repos/${encode(owner)}/${encode(repo)}`;
  const ghHeaders = {
    Authorization: `Bearer ${env.GH_TOKEN}`,
    Accept: "application/vnd.github+json",
  };
  async function gh(path) {
    return (
      await response(`${githubBase}${path}`, { headers: ghHeaders })
    ).json();
  }
  async function atom(
    path,
    { method = "GET", body, query = {}, allow404 = false } = {},
  ) {
    const url = new URL(`${atomBase}${path}`);
    url.search = new URLSearchParams({
      ...query,
      access_token: env.ATOMGIT_TOKEN,
    }).toString();
    const result = await response(
      url,
      {
        method,
        headers: { "Content-Type": "application/json" },
        ...(body ? { body: JSON.stringify(body) } : {}),
        redirect: "error",
      },
      API_TIMEOUT,
      allow404,
    );
    return !result || result.status === 204 ? null : result.json();
  }
  function git(args, timeout = API_TIMEOUT, extraEnv = {}) {
    return execFileSync("git", args, {
      timeout,
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
      env: { ...process.env, ...extraEnv, GIT_TERMINAL_PROMPT: "0" },
    });
  }
  function commit(url, tag, { optional = false } = {}) {
    let output;
    try {
      output = git([
        "ls-remote",
        url,
        `refs/tags/${tag}`,
        `refs/tags/${tag}^{}`,
      ]);
    } catch {
      throw new Error("Could not read remote tags within deadline");
    }
    if (optional && !output.trim()) return null;
    return tagCommit(output, tag);
  }
  const atomRemote = `https://atomgit.com/${owner}/${repo}.git`;
  // Release API calls only need the token, but HTTPS git push also needs the token owner's login.
  async function pushUser() {
    if (env.ATOMGIT_USER) return env.ATOMGIT_USER;
    const url = new URL("https://api.atomgit.com/api/v5/user");
    url.search = new URLSearchParams({
      access_token: env.ATOMGIT_TOKEN,
    }).toString();
    const user = await (
      await response(url, { redirect: "error" }, API_TIMEOUT)
    ).json();
    if (!user?.login)
      throw new Error("AtomGit token has no user login; set ATOMGIT_USER");
    return user.login;
  }
  return {
    source: {
      release: (tag) => gh(`/releases/tags/${encode(tag)}`),
      latestTag: async () => (await gh("/releases/latest")).tag_name,
      commit: (tag) => commit(`https://github.com/${repository}.git`, tag),
      async assets(id) {
        const assets = [];
        for (let page = 1; page <= 100; page++) {
          const batch = await gh(
            `/releases/${id}/assets?per_page=100&page=${page}`,
          );
          assets.push(...batch);
          if (batch.length < 100) return assets;
        }
        throw new Error("Release asset pagination exceeded limit");
      },
      async withAsset(asset, action) {
        const dir = await mkdtemp(join(tmpdir(), "lithe-atomgit-"));
        try {
          const file = join(dir, "asset");
          const result = await response(
            `${githubBase}/releases/assets/${asset.id}`,
            {
              headers: { ...ghHeaders, Accept: "application/octet-stream" },
            },
            TRANSFER_TIMEOUT,
          );
          const hash = createHash("sha256");
          let size = 0;
          await pipeline(
            result.body,
            async function* (chunks) {
              for await (const chunk of chunks) {
                hash.update(chunk);
                size += chunk.length;
                yield chunk;
              }
            },
            createWriteStream(file),
          );
          const digest = hash.digest("hex");
          if (
            size !== asset.size ||
            (asset.digest && asset.digest !== `sha256:${digest}`)
          ) {
            throw new Error("GitHub asset size or digest mismatch");
          }
          await action(file, digest);
        } finally {
          await rm(dir, { recursive: true, force: true });
        }
      },
    },
    target: {
      commit: (tag) => commit(atomRemote, tag, { optional: true }),
      async pushTag(tag, sourceCommit) {
        let local = "";
        try {
          local = git([
            "rev-parse",
            "--verify",
            "--quiet",
            `refs/tags/${tag}^{commit}`,
          ]).trim();
        } catch {
          // Reported below together with a stale local tag.
        }
        if (local !== sourceCommit)
          throw new Error(
            "Tag missing from checkout; fetch tags before pushing",
          );
        const user = await pushUser();
        try {
          // The helper reads credentials from the child environment so they never appear in argv.
          git(
            [
              "-c",
              "credential.helper=",
              "-c",
              'credential.helper=!f() { echo "username=$ATOMGIT_USER"; echo "password=$ATOMGIT_TOKEN"; }; f',
              "push",
              atomRemote,
              `refs/tags/${tag}:refs/tags/${tag}`,
            ],
            PUSH_TIMEOUT,
            {
              ATOMGIT_USER: user,
              ATOMGIT_TOKEN: env.ATOMGIT_TOKEN,
            },
          );
        } catch {
          throw new Error(
            "Could not push tag to AtomGit; check ATOMGIT_USER and token access",
          );
        }
      },
      release: (tag) =>
        atom(`/releases/tags/${encode(tag)}`, { allow404: true }),
      create: (body) => atom("/releases", { method: "POST", body }),
      update: (tag, body) =>
        atom(`/releases/${encode(tag)}`, { method: "PATCH", body }),
      digest: async (asset) =>
        hashResponse(
          await response(
            httpsURL(asset.browser_download_url),
            {},
            ATOMGIT_TRANSFER_TIMEOUT,
          ),
        ),
      remove: (tag, id) =>
        atom(`/releases/${encode(tag)}/attach_files/${id}`, {
          method: "DELETE",
        }),
      async upload(tag, name, file) {
        const upload = await atom(`/releases/${encode(tag)}/upload_url`, {
          query: { file_name: name },
        });
        const result = await response(
          httpsURL(upload.url),
          {
            method: "PUT",
            headers: upload.headers,
            body: await openAsBlob(file),
            redirect: "error",
          },
          ATOMGIT_TRANSFER_TIMEOUT,
        );
        await result.arrayBuffer();
        const updated = await atom(`/releases/tags/${encode(tag)}`);
        const uploaded = updated.assets?.find((asset) => asset.name === name);
        if (!uploaded)
          throw new Error("Uploaded attachment is not visible; retry sync");
        const expected = createHash("sha256");
        for await (const chunk of (await openAsBlob(file)).stream())
          expected.update(chunk);
        if (
          (await hashResponse(
            await response(
              httpsURL(uploaded.browser_download_url),
              {},
              ATOMGIT_TRANSFER_TIMEOUT,
            ),
          )) !== expected.digest("hex")
        ) {
          throw new Error("AtomGit attachment digest mismatch");
        }
      },
    },
  };
}

if (
  process.argv[1] &&
  import.meta.url === pathToFileURL(process.argv[1]).href
) {
  try {
    await synchronize({
      ...clients(process.env),
      tag: process.env.RELEASE_TAG,
    });
  } catch (error) {
    // Unexpected network/stream errors may contain signed URLs; only expose our own messages.
    const safe =
      /^(Release sync|Missing release|Invalid repository|Expected|Only published|Release notes|Tag missing|GitHub|AtomGit|Duplicate|A GitHub|Target attachment|Could not read|Could not push|Release asset|Uploaded attachment)/;
    console.error(
      safe.test(error.message)
        ? error.message
        : "Release sync failed; retry after checking repository and network access",
    );
    process.exitCode = 1;
  }
}
