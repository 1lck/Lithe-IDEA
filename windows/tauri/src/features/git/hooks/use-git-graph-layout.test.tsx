import { afterEach, beforeEach, expect, spyOn, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import * as native from "@/platform/tauri-core";
import {
  graphFixtureCase,
  graphFixtureCommits,
} from "@/test-utils/git-graph-projection-stub";
import { installHappyDom } from "@/test-utils/happy-dom";
import type { GitGraphLayout, GitGraphProjection } from "../api/git-graph-projection-api";
import { useGitGraphLayout } from "./use-git-graph-layout";

const environment = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
let restoreDom: () => void;
let previousActEnvironment: boolean | undefined;
let root: Root;
let container: HTMLElement;
let latest: GitGraphLayout;
let pending: Array<{ request: any; resolve: (value: GitGraphProjection) => void; reject: (e: unknown) => void }>;
let invoke: ReturnType<typeof spyOn>;
let errors: ReturnType<typeof spyOn>;

type Input = Parameters<typeof useGitGraphLayout>[0];
function Harness({ input }: { input: Input }) {
  latest = useGitGraphLayout(input);
  return null;
}
const render = (input: Input) => act(async () => root.render(<Harness input={input} />));

beforeEach(() => {
  restoreDom = installHappyDom();
  previousActEnvironment = environment.IS_REACT_ACT_ENVIRONMENT;
  environment.IS_REACT_ACT_ENVIRONMENT = true;
  pending = [];
  invoke = spyOn(native, "invoke").mockImplementation(((command: string, request: unknown) => {
    expect(command).toBe("git.graphProjection");
    return new Promise((resolve, reject) => pending.push({ request, resolve, reject }));
  }) as unknown as typeof native.invoke);
  errors = spyOn(console, "error").mockImplementation(() => {});
  container = document.createElement("div");
  document.body.append(container);
  root = createRoot(container);
});
afterEach(async () => {
  await act(async () => root.unmount());
  invoke.mockRestore();
  errors.mockRestore();
  environment.IS_REACT_ACT_ENVIRONMENT = previousActEnvironment;
  restoreDom();
});

const answer = (index: number, name: string) =>
  act(async () => pending[index].resolve(graphFixtureCase(name).response));

test("projects the loaded window in one call and keeps the previous layout while the next loads", async () => {
  const pageOne = graphFixtureCommits("pageOne");
  await render({ commits: pageOne, displayMode: "compact" });
  expect(latest.rows).toHaveLength(0);
  expect(pending).toHaveLength(1);
  await answer(0, "pageOne");
  expect(latest.rows.map((row) => row.commit.hash)).toEqual(["m3", "m2", "m1"]);
  expect(latest.hasMissingParents).toBe(true);

  // Appending a page reprojects the whole window; the old rows stay until it arrives.
  await render({ commits: graphFixtureCommits("pageTwo"), displayMode: "compact" });
  expect(pending).toHaveLength(2);
  expect(latest.rows).toHaveLength(3);
  await answer(1, "pageTwo");
  expect(latest.rows).toHaveLength(5);
  expect(latest.hasMissingParents).toBe(false);
});

test("a re-render with the same window and filter does not call Core again", async () => {
  const commits = graphFixtureCommits("filteredDottedAncestor");
  await render({ commits, visibleHashes: ["a", "d"], displayMode: "compact" });
  await answer(0, "filteredDottedAncestor");
  await render({ commits, visibleHashes: ["a", "d"], displayMode: "compact" });
  expect(pending).toHaveLength(1);
  expect(latest.rows.map((row) => row.commit.hash)).toEqual(["a", "d"]);
});

test("a superseded response is discarded", async () => {
  await render({ commits: graphFixtureCommits("pageOne"), displayMode: "compact" });
  await render({ commits: graphFixtureCommits("pageTwo"), displayMode: "compact" });
  expect(pending).toHaveLength(2);
  // The newer request answers first; the stale answer must not replace it.
  await answer(1, "pageTwo");
  await answer(0, "pageOne");
  expect(latest.rows).toHaveLength(5);
});

test("a failed projection clears the graph and reports the error", async () => {
  await render({ commits: graphFixtureCommits("pageOne"), displayMode: "compact" });
  await answer(0, "pageOne");
  await render({ commits: graphFixtureCommits("pageTwo"), displayMode: "compact" });
  await act(async () => pending[1].reject(new Error("core rejected")));
  expect(latest.rows).toHaveLength(0);
  expect(errors).toHaveBeenCalled();
});
