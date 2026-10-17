#!/usr/bin/env node
import assert from "node:assert/strict";
import test from "node:test";
import {
  mirroredAsset,
  releasePayload,
  synchronize,
  tagCommit,
  clients,
} from "./sync-atomgit-release.mjs";

const release = {
  id: 1,
  tag_name: "v1.2.3",
  name: "Lithe v1.2.3",
  body: "中文\n\nEnglish",
  draft: false,
  prerelease: false,
};
function fixture({
  exists = false,
  previousDigest = "same",
  commit = "abc",
} = {}) {
  const calls = [];
  const asset = { name: "Lithe-1.2.3-windows-x64.exe", state: "uploaded" };
  return {
    calls,
    tag: release.tag_name,
    log() {},
    wait: async (ms) => calls.push(["wait", ms]),
    source: {
      release: async () => release,
      latestTag: async () => release.tag_name,
      commit: async () => "abc",
      assets: async () => [asset],
      withAsset: async (_asset, action) => {
        calls.push("download");
        try {
          await action("fixture", "same");
        } finally {
          calls.push("cleanup");
        }
      },
    },
    target: {
      commit: async () => commit,
      pushTag: async () => calls.push("push"),
      release: async () =>
        exists ? { assets: [{ name: asset.name, id: 7 }] } : null,
      create: async (body) => calls.push(["create", body]),
      update: async (_tag, body) => calls.push(["update", body]),
      digest: async () => previousDigest,
      remove: async () => calls.push("remove"),
      upload: async () => calls.push("upload"),
    },
  };
}

test("creates a release with exact commit and bilingual notes before uploading", async () => {
  const f = fixture();
  await synchronize(f);
  assert.deepEqual(f.calls, [
    [
      "create",
      {
        name: release.name,
        body: release.body,
        release_status: "latest",
        tag_name: release.tag_name,
        target_commitish: "abc",
      },
    ],
    "download",
    "upload",
    "cleanup",
  ]);
});

test("retries update metadata and skip byte-identical assets", async () => {
  const f = fixture({ exists: true });
  await synchronize(f);
  assert.deepEqual(
    f.calls.map((entry) => (Array.isArray(entry) ? entry[0] : entry)),
    ["update", "download", "cleanup"],
  );
});

test("changed files are downloaded before replacement", async () => {
  const f = fixture({ exists: true, previousDigest: "old" });
  await synchronize(f);
  assert.deepEqual(f.calls.slice(1), [
    "download",
    "remove",
    "upload",
    "cleanup",
  ]);
});

test("a failed comparison preserves the previous attachment and cleans temporary files", async () => {
  const f = fixture({ exists: true });
  f.target.digest = async () => {
    throw new Error("offline");
  };
  await assert.rejects(synchronize(f), /offline/);
  assert.deepEqual(f.calls.slice(1), ["download", "cleanup"]);
});

test("failed upload still cleans up and a later retry can complete", async () => {
  const f = fixture();
  f.target.upload = async () => {
    throw new Error("upload failed");
  };
  await assert.rejects(synchronize(f), /upload failed/);
  assert.equal(f.calls.at(-1), "cleanup");
  await synchronize(fixture({ exists: true, previousDigest: "old" }));
});

test("tag mismatch blocks all mutations", async () => {
  const f = fixture({ commit: "different" });
  await assert.rejects(synchronize(f), /different commits/);
  assert.deepEqual(f.calls, []);
});

test("draft, preview, empty notes and invalid tags are rejected", async () => {
  for (const override of [
    { draft: true },
    { prerelease: true },
    { body: " " },
    { tag_name: "preview" },
  ]) {
    assert.throws(() =>
      releasePayload({ ...release, ...override }, release.tag_name),
    );
  }
  const f = fixture();
  f.tag = "../preview";
  await assert.rejects(synchronize(f), /Expected a stable tag/);
  assert.deepEqual(f.calls, []);
});

test("historical releases do not request latest status", () => {
  assert.deepEqual(releasePayload(release, "v1.2.4"), {
    name: release.name,
    body: release.body,
  });
});

test("empty releases are retriable without target mutations", async () => {
  const f = fixture();
  f.source.assets = async () => [];
  await assert.rejects(synchronize(f), /no installers yet/);
  assert.deepEqual(f.calls, []);
});

test("a missing target attachment ID never authorizes deletion", async () => {
  const f = fixture({ exists: true, previousDigest: "old" });
  f.target.release = async () => ({
    assets: [{ name: "Lithe-1.2.3-windows-x64.exe" }],
  });
  await assert.rejects(synchronize(f), /no deletion ID/);
  assert.deepEqual(f.calls.slice(1), ["download", "cleanup"]);
});

test("annotated and lightweight tags resolve to commit SHA", () => {
  const sha = "a".repeat(40),
    peeled = "b".repeat(40);
  assert.equal(tagCommit(`${sha}\trefs/tags/v1.2.3\n`, "v1.2.3"), sha);
  assert.equal(
    tagCommit(
      `${sha}\trefs/tags/v1.2.3\n${peeled}\trefs/tags/v1.2.3^{}\n`,
      "v1.2.3",
    ),
    peeled,
  );
  assert.throws(() => tagCommit("", "v1.2.3"), /Tag missing/);
});

test("API uses documented tag routes and distinguishes 404 from auth failure", async (t) => {
  const requests = [];
  let status = 404;
  t.mock.method(globalThis, "fetch", async (url, options) => {
    requests.push([new URL(url), options]);
    return new Response("{}", { status });
  });
  const api = clients({
    GITHUB_REPOSITORY: "example/app",
    GH_TOKEN: "fake-gh",
    ATOMGIT_TOKEN: "fake-atom",
    ATOMGIT_OWNER: "example",
    ATOMGIT_REPO: "app",
  });
  assert.equal(await api.target.release("v1.2.3"), null);
  assert.equal(
    requests[0][0].pathname,
    "/api/v5/repos/example/app/releases/tags/v1.2.3",
  );
  assert.equal(requests[0][0].searchParams.get("access_token"), "fake-atom");
  status = 401;
  await assert.rejects(api.target.release("v1.2.3"), /HTTP 401/);
  status = 200;
  await api.target.update("v1.2.3", { body: release.body, name: release.name });
  assert.equal(requests.at(-1)[1].method, "PATCH");
  assert.equal(
    requests.at(-1)[0].pathname,
    "/api/v5/repos/example/app/releases/v1.2.3",
  );
});

test("asset listing paginates beyond the first hundred entries", async (t) => {
  const pages = [];
  t.mock.method(globalThis, "fetch", async (url) => {
    const page = new URL(url).searchParams.get("page");
    pages.push(page);
    return Response.json(
      page === "1"
        ? Array.from({ length: 100 }, (_, id) => ({ id }))
        : [{ id: 100 }],
    );
  });
  const api = clients({
    GITHUB_REPOSITORY: "example/app",
    GH_TOKEN: "fake-gh",
    ATOMGIT_TOKEN: "fake-atom",
    ATOMGIT_OWNER: "example",
    ATOMGIT_REPO: "app",
  });
  assert.equal((await api.source.assets(1)).length, 101);
  assert.deepEqual(pages, ["1", "2"]);
});

test("real streaming download checks digest and cleans its temporary file after callback failure", async (t) => {
  const { createHash } = await import("node:crypto");
  const { readFile, access } = await import("node:fs/promises");
  const bytes = Buffer.from("fixture installer bytes");
  const digest = createHash("sha256").update(bytes).digest("hex");
  t.mock.method(globalThis, "fetch", async () => new Response(bytes));
  const api = clients({
    GITHUB_REPOSITORY: "example/app",
    GH_TOKEN: "fake-gh",
    ATOMGIT_TOKEN: "fake-atom",
    ATOMGIT_OWNER: "example",
    ATOMGIT_REPO: "app",
  });
  let downloaded;
  await assert.rejects(
    api.source.withAsset(
      { id: 3, size: bytes.length, digest: `sha256:${digest}` },
      async (file, actual) => {
        downloaded = file;
        assert.deepEqual(await readFile(file), bytes);
        assert.equal(actual, digest);
        throw new Error("callback failed");
      },
    ),
    /callback failed/,
  );
  await assert.rejects(access(downloaded), { code: "ENOENT" });
  let called = false;
  await assert.rejects(
    api.source.withAsset({ id: 3, size: bytes.length + 1 }, async () => {
      called = true;
    }),
    /size or digest mismatch/,
  );
  assert.equal(called, false);
});

test("upload uses signed PUT headers without API credentials and verifies returned attachment bytes", async (t) => {
  const { mkdtemp, writeFile, rm } = await import("node:fs/promises");
  const { tmpdir } = await import("node:os");
  const { join } = await import("node:path");
  const dir = await mkdtemp(join(tmpdir(), "atomgit-upload-test-"));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const file = join(dir, "fixture");
  await writeFile(file, "installer bytes");
  const calls = [];
  t.mock.method(globalThis, "fetch", async (url, options) => {
    const parsed = new URL(url);
    calls.push(parsed);
    if (parsed.pathname.endsWith("upload_url")) {
      assert.equal(parsed.searchParams.get("file_name"), "Lithe installer.exe");
      return Response.json({
        url: "https://storage.example/upload",
        headers: {
          "Content-Type": "application/octet-stream",
          "x-obs-callback": "fake-callback",
        },
      });
    }
    if (parsed.hostname === "storage.example") {
      assert.equal(options.method, "PUT");
      assert.equal(options.headers.Authorization, undefined);
      assert.equal(options.headers["x-obs-callback"], "fake-callback");
      assert.equal(await options.body.text(), "installer bytes");
      return new Response(null, { status: 200 });
    }
    if (parsed.hostname === "downloads.example")
      return new Response("installer bytes");
    return Response.json({
      assets: [
        {
          name: "Lithe installer.exe",
          browser_download_url: "https://downloads.example/installer",
          id: 5,
        },
      ],
    });
  });
  const api = clients({
    GITHUB_REPOSITORY: "example/app",
    GH_TOKEN: "fake-gh",
    ATOMGIT_TOKEN: "fake-atom",
    ATOMGIT_OWNER: "example",
    ATOMGIT_REPO: "app",
  });
  await api.target.upload("v1.2.3", "Lithe installer.exe", file);
  assert.equal(calls.length, 4);
  assert.equal(calls[1].search, "");
});

test("a tag the AtomGit mirror has not pulled yet is pushed before any release mutation", async () => {
  const f = fixture();
  const commits = [null, "abc"];
  f.target.commit = async () => commits.shift();
  await synchronize(f);
  assert.deepEqual(
    f.calls.map((entry) => (Array.isArray(entry) ? entry[0] : entry)),
    ["push", "create", "download", "upload", "cleanup"],
  );
});

test("a failed tag push is tolerated only when the mirror created the same tag concurrently", async () => {
  const raced = fixture();
  const commits = [null, "abc"];
  raced.target.commit = async () => commits.shift();
  raced.target.pushTag = async () => {
    throw new Error(
      "Could not push tag to AtomGit; check ATOMGIT_USER and token access",
    );
  };
  await synchronize(raced);
  assert.equal(raced.calls[0][0], "create");

  const missing = fixture();
  missing.target.commit = async () => null;
  missing.target.pushTag = async () => {
    throw new Error(
      "Could not push tag to AtomGit; check ATOMGIT_USER and token access",
    );
  };
  await assert.rejects(synchronize(missing), /Could not push tag/);
  assert.deepEqual(missing.calls, []);

  const diverged = fixture();
  const divergedCommits = [null, "different"];
  diverged.target.commit = async () => divergedCommits.shift();
  diverged.target.pushTag = async () => {
    throw new Error(
      "Could not push tag to AtomGit; check ATOMGIT_USER and token access",
    );
  };
  await assert.rejects(synchronize(diverged), /different commits/);
  assert.deepEqual(diverged.calls, []);
});

test("only user-facing installers and their checksums are mirrored", async () => {
  const names = [
    "appcast-arm64.xml",
    "latest.json",
    "Lithe-1.2.3-arm64.dmg",
    "Lithe-1.2.3-arm64.dmg.sha256",
    "Lithe-1.2.3-arm64.dmg.edsig",
    "Lithe-1.2.3-arm64.zip",
    "Lithe-1.2.3-x86_64.dmg",
    "Lithe-1.2.3-windows-x64.exe",
    "Lithe-1.2.3-windows-x64.exe.sha256",
    "Lithe-1.2.3-windows-x64-updater.exe",
    "Lithe-1.2.3-windows-x64-updater.exe.sig",
    "Lithe-1.2.2-x86_64.dmg",
    "Lithe54-51-arm64.delta",
    "Lithe-PHP-Support-1.2.3-arm64.zip",
  ];
  const f = fixture();
  const uploaded = [];
  f.source.assets = async () =>
    names.map((name) => ({ name, state: "uploaded" }));
  f.target.upload = async (_tag, name) => uploaded.push(name);
  await synchronize(f);
  assert.deepEqual(uploaded, [
    "Lithe-1.2.3-arm64.dmg",
    "Lithe-1.2.3-arm64.dmg.sha256",
    "Lithe-1.2.3-x86_64.dmg",
    "Lithe-1.2.3-windows-x64.exe",
    "Lithe-1.2.3-windows-x64.exe.sha256",
  ]);
  assert.equal(mirroredAsset("Lithe-1.2.3-arm64.dmg", "v1.2.3"), true);
  assert.equal(mirroredAsset("Lithe-1.2.3-arm64.dmg", "v1.2.4"), false);
});

test("a transient upload failure is retried with growing delays and re-reads the target first", async () => {
  const f = fixture();
  const name = "Lithe-1.2.3-windows-x64.exe";
  let visible = false;
  let uploads = 0;
  f.target.release = async () => {
    f.calls.push("read");
    return visible ? { assets: [{ name, id: 9 }] } : null;
  };
  f.target.upload = async () => {
    f.calls.push("upload");
    uploads += 1;
    if (uploads === 1) throw new Error("Release sync HTTP 502");
    // The second PUT lands but its read-back stalls; the next attempt must not upload again.
    visible = true;
    throw new Error("Release sync request failed or timed out");
  };
  await synchronize(f);
  assert.deepEqual(
    f.calls.map((entry) =>
      !Array.isArray(entry)
        ? entry
        : entry[0] === "wait"
          ? `wait:${entry[1]}`
          : entry[0],
    ),
    [
      "read",
      "create",
      "download",
      "read",
      "upload",
      "wait:30000",
      "read",
      "upload",
      "wait:60000",
      "read",
      "cleanup",
    ],
  );
});

test("retries stop after the attempt limit and permanent failures are not retried", async () => {
  const f = fixture();
  let uploads = 0;
  f.target.upload = async () => {
    uploads += 1;
    throw new Error("Release sync HTTP 502");
  };
  await assert.rejects(synchronize(f), /HTTP 502/);
  assert.equal(uploads, 4);
  assert.deepEqual(
    f.calls.filter((entry) => Array.isArray(entry) && entry[0] === "wait"),
    [
      ["wait", 30_000],
      ["wait", 60_000],
      ["wait", 120_000],
    ],
  );
  assert.equal(f.calls.at(-1), "cleanup");

  const denied = fixture();
  let deniedUploads = 0;
  denied.target.upload = async () => {
    deniedUploads += 1;
    throw new Error("Release sync HTTP 403");
  };
  await assert.rejects(synchronize(denied), /HTTP 403/);
  assert.equal(deniedUploads, 1);
});

test("tag push resolves the token login, sends the exact local tag and never overwrites a diverged AtomGit tag", async (t) => {
  const { execFileSync } = await import("node:child_process");
  const { mkdtemp, rm } = await import("node:fs/promises");
  const { tmpdir } = await import("node:os");
  const { join } = await import("node:path");
  const dir = await mkdtemp(join(tmpdir(), "atomgit-push-test-"));
  const previousDirectory = process.cwd();
  const previousEnv = { ...process.env };
  t.after(async () => {
    process.chdir(previousDirectory);
    for (const key of Object.keys(process.env))
      if (!(key in previousEnv)) delete process.env[key];
    Object.assign(process.env, previousEnv);
    await rm(dir, { recursive: true, force: true });
  });
  const run = (cwd, ...args) =>
    execFileSync("git", args, {
      cwd,
      encoding: "utf8",
      timeout: 10_000,
    }).trim();
  const work = join(dir, "work");
  const remote = join(dir, "remote.git");
  run(dir, "init", "--quiet", "--bare", remote);
  run(dir, "init", "--quiet", work);
  run(
    work,
    "-c",
    "user.name=Fixture",
    "-c",
    "user.email=fixture@example.invalid",
    "-c",
    "commit.gpgsign=false",
    "commit",
    "--quiet",
    "--allow-empty",
    "-m",
    "release",
  );
  run(work, "tag", "v1.2.3");
  const sha = run(work, "rev-parse", "HEAD");
  // Route the AtomGit URL to the local bare repository so the real git push path runs offline.
  Object.assign(process.env, {
    GIT_CONFIG_COUNT: "2",
    GIT_CONFIG_KEY_0: `url.${remote}.insteadOf`,
    GIT_CONFIG_VALUE_0: "https://atomgit.com/example/app.git",
    GIT_CONFIG_KEY_1: "protocol.file.allow",
    GIT_CONFIG_VALUE_1: "always",
  });
  process.chdir(work);
  const env = {
    GITHUB_REPOSITORY: "example/app",
    GH_TOKEN: "fake-gh",
    ATOMGIT_TOKEN: "fake-atom",
    ATOMGIT_OWNER: "example",
    ATOMGIT_REPO: "app",
  };
  // Without ATOMGIT_USER the push login comes from the token's own profile.
  const lookups = [];
  let profile = {};
  t.mock.method(globalThis, "fetch", async (url) => {
    lookups.push(new URL(url));
    return Response.json(profile);
  });
  const api = clients(env);
  await assert.rejects(
    api.target.pushTag("v1.2.3", "f".repeat(40)),
    /fetch tags before pushing/,
  );
  assert.equal(lookups.length, 0);
  await assert.rejects(api.target.pushTag("v1.2.3", sha), /no user login/);
  assert.equal(api.target.commit("v1.2.3"), null);
  profile = { login: "token-owner" };
  await api.target.pushTag("v1.2.3", sha);
  assert.equal(lookups.at(-1).pathname, "/api/v5/user");
  assert.equal(lookups.at(-1).searchParams.get("access_token"), "fake-atom");
  assert.equal(run(remote, "rev-parse", "refs/tags/v1.2.3"), sha);
  assert.equal(api.target.commit("v1.2.3"), sha);
  assert.equal(api.target.commit("v9.9.9"), null);

  // A diverged tag on AtomGit must be rejected rather than overwritten.
  run(
    work,
    "-c",
    "user.name=Fixture",
    "-c",
    "user.email=fixture@example.invalid",
    "-c",
    "commit.gpgsign=false",
    "commit",
    "--quiet",
    "--allow-empty",
    "-m",
    "other",
  );
  run(work, "tag", "-f", "v1.2.3");
  const configured = clients({ ...env, ATOMGIT_USER: "fixture-user" });
  const lookupCount = lookups.length;
  await assert.rejects(
    configured.target.pushTag("v1.2.3", run(work, "rev-parse", "HEAD")),
    /Could not push tag/,
  );
  assert.equal(lookups.length, lookupCount);
  assert.equal(run(remote, "rev-parse", "refs/tags/v1.2.3"), sha);
});
