#!/usr/bin/env node
import assert from "node:assert/strict";
import test from "node:test";
import {
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
  const asset = { name: "Lithe.exe", state: "uploaded" };
  return {
    calls,
    tag: release.tag_name,
    log() {},
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
  await assert.rejects(synchronize(f), /no assets yet/);
  assert.deepEqual(f.calls, []);
});

test("a missing target attachment ID never authorizes deletion", async () => {
  const f = fixture({ exists: true, previousDigest: "old" });
  f.target.release = async () => ({ assets: [{ name: "Lithe.exe" }] });
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
