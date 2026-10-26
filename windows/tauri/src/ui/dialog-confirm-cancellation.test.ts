import { expect, spyOn, test } from "bun:test";
import { showConfirmDialog } from "./dialog";

test("aborting an enqueued review resolves false and removes the abort listener", async () => {
  const controller = new AbortController();
  const removed = spyOn(controller.signal, "removeEventListener");
  const pending = showConfirmDialog("fixture review", { signal: controller.signal });
  try {
    controller.abort();
    expect(await pending).toBe(false);
    expect(removed).toHaveBeenCalledWith("abort", expect.any(Function));
  } finally {
    controller.abort();
    await pending;
    removed.mockRestore();
  }
}, 2000);

test("an already revoked review never queues or registers a new listener", async () => {
  const controller = new AbortController();
  controller.abort();
  const added = spyOn(controller.signal, "addEventListener");
  try {
    expect(await showConfirmDialog("fixture review", { signal: controller.signal })).toBe(false);
    expect(added).not.toHaveBeenCalled();
  } finally {
    added.mockRestore();
  }
}, 2000);
