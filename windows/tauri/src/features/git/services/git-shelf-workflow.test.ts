import { expect, test } from "bun:test";
import { createShelfWorkflow, type GitShelf, type ShelfPhase, type ShelfLayer } from "./git-shelf-workflow";

function fixture() {
  const events: string[] = [];
  let saved: GitShelf | undefined;
  let stale = false;
  let failSave = false;
  let failStep: string | undefined;
  let failRemove = false;
  let staleAfterStep: string | undefined;
  const workflow = createShelfWorkflow({
    guard: () => { if (stale) throw new Error("changed workspace"); },
    snapshot: async () => ({ stagedPatch: "index", workingPatch: "worktree", paths: ["a"] }),
    plan: async (phase: ShelfPhase): Promise<ShelfLayer[]> => {
      events.push(`plan:${phase}`);
      return phase === "clean" ? ["working", "staged"] : ["staged", "working"];
    },
    step: async (phase, layer, snapshot) => {
      expect(snapshot).toMatchObject({ stagedPatch: "index", workingPatch: "worktree" });
      const event = `${phase}:${layer}`;
      events.push(event);
      if (event === failStep) throw new Error("git.saved.changed");
      if (event === staleAfterStep) stale = true;
    },
    save: async (entry) => {
      events.push("save");
      if (failSave) throw new Error("disk full");
      saved = entry;
    },
    remove: async () => {
      events.push("remove");
      if (failRemove) throw new Error("storage unavailable");
      saved = undefined;
    },
    identity: () => "record",
    now: () => 123,
  });
  return {
    workflow, events, saved: () => saved,
    stale: () => { stale = true; },
    failSave: () => { failSave = true; },
    failStep: (event?: string) => { failStep = event; },
    failRemove: (value: boolean) => { failRemove = value; },
    staleAfterStep: (event: string) => { staleAfterStep = event; },
  };
}

test("persists before executing the Core plan and removes only after restoration", async () => {
  const f = fixture();
  const shelf = await f.workflow.capture("  WIP  ");
  expect(shelf.message).toBe("WIP");
  expect(f.events).toEqual(["save", "plan:clean", "clean:working", "clean:staged"]);
  await f.workflow.restore(shelf);
  expect(f.events.slice(4)).toEqual(["plan:restore", "restore:staged", "restore:working", "remove"]);
  expect(f.saved()).toBeUndefined();
});

test("storage failure never starts cleanup", async () => {
  const f = fixture();
  f.failSave();
  await expect(f.workflow.capture("WIP")).rejects.toThrow("disk full");
  expect(f.events).toEqual(["save"]);
});

test("failed clean keeps both captured versions", async () => {
  const f = fixture();
  f.failStep("clean:staged");
  await expect(f.workflow.capture("WIP")).rejects.toThrow("git.saved.changed");
  expect(f.saved()).toMatchObject({ stagedPatch: "index", workingPatch: "worktree" });
  expect(f.events).toEqual(["save", "plan:clean", "clean:working", "clean:staged"]);
});

test("partial restoration retains the record and retries the Core plan", async () => {
  const f = fixture();
  const shelf = await f.workflow.capture("WIP");
  f.failStep("restore:working");
  await expect(f.workflow.restore(shelf)).rejects.toThrow("git.saved.changed");
  expect(f.saved()).toEqual(shelf);
  f.failStep();
  await f.workflow.restore(shelf);
  expect(f.events.slice(-4)).toEqual(["plan:restore", "restore:staged", "restore:working", "remove"]);
});

test("a workspace switch between layers stops subsequent writes and preserves the record", async () => {
  const f = fixture();
  const shelf = await f.workflow.capture("WIP");
  f.staleAfterStep("restore:staged");
  await expect(f.workflow.restore(shelf)).rejects.toThrow("changed workspace");
  expect(f.events.slice(-2)).toEqual(["plan:restore", "restore:staged"]);
  expect(f.saved()).toEqual(shelf);
});

test("a deletion failure keeps the record for retry", async () => {
  const f = fixture();
  const shelf = await f.workflow.capture("WIP");
  f.failRemove(true);
  await expect(f.workflow.restore(shelf)).rejects.toThrow("storage unavailable");
  expect(f.saved()).toEqual(shelf);
  f.failRemove(false);
  await f.workflow.restore(shelf);
  expect(f.saved()).toBeUndefined();
});

test("a stale workspace blocks restoration before planning", async () => {
  const f = fixture();
  const shelf = await f.workflow.capture("WIP");
  f.stale();
  await expect(f.workflow.restore(shelf)).rejects.toThrow("changed workspace");
  expect(f.events).toHaveLength(4);
  expect(f.saved()).toEqual(shelf);
});
