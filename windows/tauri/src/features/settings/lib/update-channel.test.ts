import { expect, test } from "bun:test";
import fixture from "../../../../../../shared/fixtures/updates/channel-selection-v1.json";
import buildTimeFixture from "../../../../../../shared/fixtures/updates/build-time-v1.json";
import { createTranslator } from "@/i18n/locale";
import type { UpdateChannel } from "./update-channel";
import { getServiceUrls } from "@/config/services";
import {
  UPDATE_CHANNEL_STORAGE_KEY,
  formatBuildTimestamp,
  getInstalledVersionLabel,
  persistUpdateChannel,
  readUpdateChannel,
  resolveUpdateChannel,
} from "./update-channel";

test("shared channel contract matches Windows installation routes", () => {
  expect<string>(readUpdateChannel(null)).toBe(fixture.defaultChannel);
  for (const route of fixture.cases) {
    const actual = resolveUpdateChannel(route.selected as UpdateChannel, route.installed as UpdateChannel);
    expect<string>(actual.method).toBe(route.windowsMethod);
    if (route.selected === "autobuild") expect(actual.releaseURL).toBe(fixture.rollingReleaseURL);
  }
  for (const invalid of fixture.invalidPreferences) {
    const storage = { getItem: () => invalid, setItem: () => {} };
    expect<string>(readUpdateChannel(storage)).toBe(fixture.defaultChannel);
  }
});

test("shared build-time fixture formats installed AutoBuild identity in both languages", () => {
  for (const entry of buildTimeFixture.cases) {
    expect(formatBuildTimestamp(entry.timestamp)).toBe(entry.display);
    expect(getInstalledVersionLabel("123.4", createTranslator("en-US"), "autobuild", entry.timestamp))
      .toBe(`AutoBuild — Built at ${entry.display}`);
    expect(getInstalledVersionLabel("123.4", createTranslator("zh-CN"), "autobuild", entry.timestamp))
      .toBe(`AutoBuild — 构建自 ${entry.display}`);
  }
});

test("invalid or missing installed timestamps never invent a time or expose a workflow counter", () => {
  for (const timestamp of [
    undefined,
    ...buildTimeFixture.invalidTimestamps,
    "2026-04-31T12:00:00Z",
    "2026-10-15T12:60:00Z",
    "2026-10-15T12:43:60Z",
    "2026-10-15T12:43:54+00:00",
    "2026-10-15T12:43:54.000Z",
    "2026-10-15T12:43:54",
    " 2026-10-15T12:43:54Z",
  ]) {
    expect(formatBuildTimestamp(timestamp)).toBeNull();
    for (const language of ["en-US", "zh-CN"] as const) {
      expect(getInstalledVersionLabel("123.4", createTranslator(language), "autobuild", timestamp))
        .toBe("AutoBuild");
    }
  }
});

test("stable installed version stays unchanged regardless of available build time", () => {
  for (const timestamp of [undefined, "invalid", ...buildTimeFixture.cases.map((entry) => entry.timestamp)]) {
    expect(getInstalledVersionLabel("0.11.0", createTranslator("en-US"), "stable", timestamp))
      .toBe("0.11.0");
  }
});

function memoryStorage() {
  const values = new Map<string, string>();
  return {
    getItem: (key: string) => values.get(key) ?? null,
    setItem: (key: string, value: string) => { values.set(key, value); },
  };
}

test("isolated development defaults to its installed channel and preserves explicit choices", () => {
  const storage = memoryStorage();
  expect<string>(readUpdateChannel(storage, "autobuild")).toBe(fixture.developmentDefaultChannel);
  storage.setItem(UPDATE_CHANNEL_STORAGE_KEY, "stable");
  expect(readUpdateChannel(storage, "autobuild")).toBe("stable");
  storage.setItem(UPDATE_CHANNEL_STORAGE_KEY, "invalid");
  expect(readUpdateChannel(storage, "autobuild")).toBe("stable");
});

test("channel preference defaults to stable and rejects malformed stored choices", () => {
  const storage = memoryStorage();
  expect<string>(readUpdateChannel(storage)).toBe("stable");
  for (const invalid of ["preview", "AutoBuild", "null", "{}", "", "https://untrusted.test"]) {
    storage.setItem(UPDATE_CHANNEL_STORAGE_KEY, invalid);
    expect<string>(readUpdateChannel(storage)).toBe("stable");
  }
  expect<string>(readUpdateChannel(null)).toBe("stable");
});

test("explicit rolling choice persists across readers and cannot be overwritten by invalid input", () => {
  const storage = memoryStorage();
  expect(persistUpdateChannel("autobuild", storage)).toBe(true);
  expect<string>(readUpdateChannel(storage)).toBe("autobuild");
  expect(persistUpdateChannel("preview", storage)).toBe(false);
  expect<string>(readUpdateChannel(storage)).toBe("autobuild");
  expect(persistUpdateChannel("stable", storage)).toBe(true);
  expect<string>(readUpdateChannel(storage)).toBe("stable");
});

test("storage failures fail safely without claiming the preference was saved", () => {
  const storage = {
    getItem: () => { throw new Error("storage denied"); },
    setItem: () => { throw new Error("storage full"); },
  };
  expect<string>(readUpdateChannel(storage)).toBe("stable");
  expect(persistUpdateChannel("autobuild", storage)).toBe(false);
});

test("channel routing preserves stable canonical source and uses actual rolling publisher", () => {
  expect(resolveUpdateChannel("stable", "stable")).toEqual({
    method: "tauri",
    releaseURL: `${getServiceUrls().githubReleasesBaseUrl}/latest`,
  });
  for (const installed of ["stable", "autobuild"] as const) {
    expect(resolveUpdateChannel("autobuild", installed)).toEqual({
      method: "release-page",
      releaseURL: "https://github.com/1lck/Lithe-IDEA/releases/tag/AutoBuild",
    });
  }
  expect(resolveUpdateChannel("stable", "autobuild")).toEqual({
    method: "release-page",
    releaseURL: `${getServiceUrls().githubReleasesBaseUrl}/latest`,
  });
});
