import { expect, test } from "bun:test";
import { createShelfWorkflow, type GitShelf, type ShelfSnapshot } from "./git-shelf-workflow";
import type { GitPatchTarget } from "../types/git-patch.types";

function fixture() {
  const events: string[] = [];
  let snapshot: ShelfSnapshot = { stagedPatch: "index", workingPatch: "worktree", paths: ["a"] };
  let saved: GitShelf | undefined;
  let stale = false;
  let failSave = false;
  let failTarget = "";
  let changeAfterSave = false;
  let failRemove = false;
  let failCheck = false;
  let staleAfterCheck = false;
  const applied = new Set<GitPatchTarget>();
  const workflow = createShelfWorkflow({
    guard: () => {
      if (stale) throw new Error("changed workspace");
    },
    snapshot: async () => ({ ...snapshot }),
    save: async (entry) => {
      events.push("save");
      if (failSave) throw new Error("disk full");
      saved = entry;
      if (changeAfterSave) snapshot = { ...snapshot, workingPatch: "external edit" };
    },
    remove: async () => {
      events.push("remove");
      if (failRemove) throw new Error("storage unavailable");
      saved = undefined;
    },
    apply: async (_patch, target, reverse) => {
      events.push(`${target}:${reverse}`);
      if (target === failTarget) throw new Error("conflict");
      if (!reverse && applied.has(target)) throw new Error("patch is already applied");
      if (reverse) {
        applied.delete(target);
        snapshot = {
          ...snapshot,
          ...(target === "worktree" ? { workingPatch: "" } : { stagedPatch: "" }),
        };
      } else applied.add(target);
    },
    isApplied: async (_patch, target) => {
      if (failCheck) throw new Error("check unavailable");
      if (staleAfterCheck) stale = true;
      return applied.has(target) && target !== failTarget;
    },
    identity: () => "record",
    now: () => 123,
  });
  return {
    workflow,
    events,
    saved: () => saved,
    change: (value: ShelfSnapshot) => {
      snapshot = value;
    },
    stale: () => {
      stale = true;
    },
    changeAfterSave: () => {
      changeAfterSave = true;
    },
    failSave: () => {
      failSave = true;
    },
    failApply: (target: string) => {
      failTarget = target;
    },
    failRemove: (value: boolean) => {
      failRemove = value;
    },
    failCheck: () => {
      failCheck = true;
    },
    staleAfterCheck: () => {
      staleAfterCheck = true;
    },
  };
}

test("shelf persists both versions before cleaning and restores index before worktree", async () => {
  const f = fixture();
  const shelf = await f.workflow.capture("  WIP  ");
  expect(shelf.message).toBe("WIP");
  expect(f.events).toEqual(["save", "worktree:true", "indexAndWorktree:true"]);
  await f.workflow.restore(shelf);
  expect(f.events.slice(3)).toEqual(["indexAndWorktree:false", "worktree:false", "remove"]);
  expect(f.saved()).toBeUndefined();
});

test("storage failure never cleans repository changes", async () => {
  const f = fixture();
  f.failSave();
  await expect(f.workflow.capture("WIP")).rejects.toThrow("disk full");
  expect(f.events).toEqual(["save"]);
});

test("partial restoration keeps the full recovery record", async () => {
  const f = fixture();
  const shelf = await f.workflow.capture("WIP");
  f.failApply("worktree");
  await expect(f.workflow.restore(shelf)).rejects.toThrow("conflict");
  expect(f.saved()).toEqual(shelf);
  expect(f.events).not.toContain("remove");
});

test("retry continues with the working patch after the index was restored before a conflict", async () => {
  const f = fixture();
  const shelf = await f.workflow.capture("WIP");
  f.failApply("worktree");
  await expect(f.workflow.restore(shelf)).rejects.toThrow("conflict");
  f.failApply("");
  await f.workflow.restore(shelf);
  expect(f.saved()).toBeUndefined();
  expect(f.events.slice(-2)).toEqual(["worktree:false", "remove"]);
});

test("retry removes a fully restored shelf after its previous deletion failed", async () => {
  const f = fixture();
  const shelf = await f.workflow.capture("WIP");
  f.failRemove(true);
  await expect(f.workflow.restore(shelf)).rejects.toThrow("storage unavailable");
  expect(f.saved()).toEqual(shelf);
  f.failRemove(false);
  await f.workflow.restore(shelf);
  expect(f.saved()).toBeUndefined();
});

test("a failed already-applied check keeps the shelf instead of assuming restoration succeeded", async () => {
  const f = fixture();
  const shelf = await f.workflow.capture("WIP");
  f.failApply("worktree");
  f.failCheck();
  await expect(f.workflow.restore(shelf)).rejects.toThrow("check unavailable");
  expect(f.saved()).toEqual(shelf);
  expect(f.events).not.toContain("remove");
});

test("a workspace change during the retry check blocks later patches and deletion", async () => {
  const f = fixture();
  const shelf = await f.workflow.capture("WIP");
  f.failApply("worktree");
  await expect(f.workflow.restore(shelf)).rejects.toThrow("conflict");
  f.failApply("");
  f.staleAfterCheck();
  const previousEvents = f.events.length;
  await expect(f.workflow.restore(shelf)).rejects.toThrow("changed workspace");
  expect(f.events.slice(previousEvents)).toEqual(["indexAndWorktree:false"]);
  expect(f.saved()).toEqual(shelf);
});

test("workspace changes block writes and retain persisted snapshots", async () => {
  const f = fixture();
  const shelf = await f.workflow.capture("WIP");
  f.stale();
  await expect(f.workflow.restore(shelf)).rejects.toThrow("changed workspace");
  expect(f.saved()).toEqual(shelf);
  expect(f.events).toHaveLength(3);
});

test("an edit after durable capture keeps the shelf and blocks all cleaning", async () => {
  const f = fixture();
  f.changeAfterSave();
  await expect(f.workflow.capture("WIP")).rejects.toThrow("git.saved.changed");
  expect(f.saved()?.workingPatch).toBe("worktree");
  expect(f.events).toEqual(["save"]);
});

test("partial cleaning retains both captured versions for manual recovery", async () => {
  const f = fixture();
  f.failApply("indexAndWorktree");
  await expect(f.workflow.capture("WIP")).rejects.toThrow("conflict");
  expect(f.saved()).toMatchObject({ stagedPatch: "index", workingPatch: "worktree" });
  expect(f.events).toEqual(["save", "worktree:true", "indexAndWorktree:true"]);
});
