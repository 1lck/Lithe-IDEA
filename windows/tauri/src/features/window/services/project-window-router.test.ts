import { expect, test } from "bun:test";
import { createProjectWindowRouter, type ProjectWindowOwner } from "./project-window-router";

function harness() {
  const tabs = [
    { id: "project-a", path: "C:/projects/a" },
    { id: "project-b", path: "C:/projects/b" },
  ];
  const claims: string[] = [];
  const switches: string[] = [];
  const releases: string[] = [];
  const errors: unknown[] = [];
  let listener: ((id: string) => void) | undefined;
  let stops = 0;
  let owner: ProjectWindowOwner = { label: "main", workspaceId: "project-a" };
  const router = createProjectWindowRouter({
    label: "main",
    tabs: () => tabs,
    claim: async (tab, activate) => {
      claims.push(`${tab.id}:${activate}`);
      return activate ? owner : { label: "main", workspaceId: tab.id };
    },
    release: async (id) => {
      releases.push(id);
    },
    listen: async (activate) => {
      listener = activate;
      return () => {
        stops++;
        listener = undefined;
      };
    },
    switchTo: async (id) => {
      switches.push(id);
      return true;
    },
    reportError: (error) => {
      errors.push(error);
    },
  });
  return {
    router,
    tabs,
    claims,
    switches,
    releases,
    errors,
    activate: (id: string) => listener?.(id),
    setOwner: (value: ProjectWindowOwner) => {
      owner = value;
    },
    stops: () => stops,
  };
}

test("registers inactive restored tabs before opening and initializes only once", async () => {
  const h = harness();
  try {
    await Promise.all([h.router.initialize(), h.router.initialize()]);
    expect(await h.router.claim(h.tabs[0]!)).toBe(false);
    expect(h.claims).toEqual(["project-a:false", "project-b:false", "project-a:true"]);
  } finally {
    h.router.dispose();
  }
  expect(h.stops()).toBe(1);
});

test("reuses another window without initializing or switching the caller", async () => {
  const h = harness();
  try {
    h.setOwner({ label: "workspace-1", workspaceId: "project-a" });
    expect(await h.router.claim(h.tabs[0]!)).toBe(true);
    expect(h.switches).toEqual([]);
  } finally {
    h.router.dispose();
  }
});

test("activates the original same-window tab for a directory alias", async () => {
  const h = harness();
  try {
    expect(await h.router.claim({ id: "alias", path: "C:/links/a" })).toBe(true);
    expect(h.switches).toEqual(["project-a"]);
  } finally {
    h.router.dispose();
  }
});

test("does not send remote or WSL project identities to the local filesystem", async () => {
  const h = harness();
  try {
    expect(await h.router.claim({ id: "remote", path: "remote://server/project" })).toBe(false);
    expect(await h.router.claim({ id: "wsl", path: "wsl://Ubuntu/project" })).toBe(false);
    expect(h.claims).toEqual([]);
  } finally {
    h.router.dispose();
  }
});

test("releases ownership by workspace ID even if its directory was removed", async () => {
  const h = harness();
  try {
    await h.router.initialize();
    h.tabs.length = 0;
    await h.router.release("project-a");
    expect(h.releases).toEqual(["project-a"]);
  } finally {
    h.router.dispose();
  }
});

test("routes activation events to background tabs and ignores closed tabs", async () => {
  const h = harness();
  try {
    await h.router.initialize();
    h.activate("project-b");
    // The activation queue crosses one promise boundary before switchTo.
    await Promise.resolve();
    expect(h.switches).toEqual(["project-b"]);
    h.activate("closed-tab");
  } finally {
    h.router.dispose();
  }
  expect(h.errors).toEqual([]);
});

test("cleans up a listener whose registration completes after disposal", async () => {
  const h = harness();
  const ready = h.router.initialize();
  h.router.dispose();
  await ready;
  expect(h.stops()).toBe(1);
  expect(h.claims).toEqual([]);
});
