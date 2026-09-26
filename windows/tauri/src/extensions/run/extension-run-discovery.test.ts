import { expect, test } from "bun:test";
import manifestJson from "../../../../../Plugins/win/Official/PhpSupport/plugin.json";
import { discoverRunActions } from "../../../../../Plugins/win/Official/PhpSupport/plugin";
import type { ExtensionManifest } from "../types/extension-manifest";
import { discoverExtensionActions, validateRunPlans } from "./extension-run-discovery";
const manifest = manifestJson as ExtensionManifest;

test("uninstalled or disabled plugin never reads files or calls a provider", async () => {
  let calls = 0;
  const actions = await discoverExtensionActions(
    manifest,
    "/work/project",
    async () => {
      calls++;
      return "";
    },
    async () => {
      calls++;
      return [];
    },
    () => false,
  );
  expect(calls).toBe(0);
  expect(actions).toEqual([]);
});

test("installed PHP contributes Composer array scripts and portable PHPUnit plans", async () => {
  const files = {
    "composer.json": JSON.stringify({
      scripts: {
        test: ["@php vendor/bin/phpunit", "@lint"],
        dev: "php -S localhost:8000",
        invalid: 42,
      },
    }),
    "phpunit.xml": "<phpunit/>",
  };
  const actions = await discoverExtensionActions(
    manifest,
    "/work/project",
    async (path) => {
      const value = files[path.split("/").pop() as keyof typeof files];
      if (value === undefined) throw new Error("absent");
      return value;
    },
    async (contents) => discoverRunActions(contents),
    () => true,
  );
  expect(actions.map((action) => action.name)).toEqual(["dev", "test", "PHPUnit"]);
  expect(actions[1]?.pluginCommand).toEqual({
    executable: "composer",
    arguments: ["run", "--", "test"],
  });
  expect(actions[2]?.pluginCommand).toEqual({
    executable: "php",
    arguments: ["vendor/bin/phpunit"],
  });
  expect(actions.every((action) => action.extensionId === manifest.id)).toBe(true);
});

test("disabling during discovery discards the late response", async () => {
  let active = true;
  const result = await discoverExtensionActions(
    manifest,
    "/work/project",
    async () => "",
    async () => {
      active = false;
      return discoverRunActions({ "phpunit.xml": "" });
    },
    () => active,
  );
  expect(result).toEqual([]);
});

test("worker plans must use declared executables and structured bounded arguments", () => {
  expect(() =>
    validateRunPlans(
      [
        {
          id: "escape",
          name: "escape",
          sourceLabel: "test",
          executable: "powershell",
          arguments: [],
        },
      ],
      manifest,
    ),
  ).toThrow();
  expect(() =>
    validateRunPlans(
      [{ id: "bad", name: "bad", sourceLabel: "test", executable: "php", arguments: ["x\0y"] }],
      manifest,
    ),
  ).toThrow();
  expect(discoverRunActions({ "composer.json": "broken" })).toEqual([]);
  expect(discoverRunActions({ "composer.json": '{"scripts": ["wrong"]}' })).toEqual([]);
});
