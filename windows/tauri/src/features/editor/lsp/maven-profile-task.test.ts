import { expect, mock, test } from "bun:test";
import { presentMavenProfileTask } from "./maven-profile-task";
import { readFileSync } from "node:fs";

test("Maven failure retains retry and never becomes a Java readiness success", async () => {
  const toast = {
    loading: mock(() => "id"), success: mock(() => "id"),
    warning: mock(() => "id"), error: mock(() => "id"), dismiss: mock(() => "id"),
  };
  const effects = { toast, clearProjects: mock(() => {}), retry: mock(async () => {}) };
  presentMavenProfileTask({ sessionId: "java", status: "running" }, effects);
  expect(effects.clearProjects).toHaveBeenCalledWith("java");
  for (const status of ["failed", "timedOut", "partiallySucceeded"]) {
    presentMavenProfileTask({ sessionId: "java", status }, effects);
  }
  expect(toast.success).not.toHaveBeenCalled();
  expect(toast.warning).toHaveBeenCalledTimes(3);
  const options = (toast.warning.mock.calls as unknown as [string, { id: string; action: { onClick: (event: Event) => void } }][])[0][1];
  expect(options.id).toBe("java-maven-profiles:java");
  options.action.onClick(new Event("click", { cancelable: true }));
  expect(effects.retry).toHaveBeenCalledWith("java");
  await effects.retry.mock.results[0].value;
});

test("rejected retry prevents action removal and can be retried after the old batch ends", async () => {
  const toast = {
    loading: mock(() => "id"), success: mock(() => "id"),
    warning: mock(() => "id"), error: mock(() => "id"), dismiss: mock(() => "id"),
  };
  let stopping = true;
  const retry = mock(async () => { if (stopping) throw new Error("Previous requests are stopping"); });
  presentMavenProfileTask({ sessionId: "java", status: "timedOut" }, { toast, clearProjects: () => {}, retry });
  const options = (toast.warning.mock.calls as unknown as [string, { duration: number; action: { onClick: (event: Event) => void } }][])[0][1];
  let removed = false;
  const pendingRemovals: (() => void)[] = [];
  const click = () => {
    const event = new Event("click", { cancelable: true });
    options.action.onClick(event);
    // Sonner schedules removal only when the action did not prevent default.
    if (!event.defaultPrevented) pendingRemovals.push(() => { removed = true; });
  };
  click();
  await Promise.resolve(retry.mock.results[0].value).catch(() => {});
  pendingRemovals.splice(0).forEach((remove) => remove());
  expect(removed).toBe(false);
  expect(options.duration).toBe(Infinity);
  expect(toast.error).toHaveBeenCalledWith("Previous requests are stopping", { id: "java-maven-profiles:java:retry-error", duration: 8000 });
  stopping = false;
  click();
  await retry.mock.results[1].value;
  expect(retry).toHaveBeenCalledTimes(2);
});

test("shared Maven event fixture keeps task warnings separate from service readiness", () => {
  const fixture = JSON.parse(readFileSync(new URL("../../../../../../shared/fixtures/lsp/maven-profile-events-v1.json", import.meta.url), "utf8"));
  const toast = {
    loading: mock(() => "id"), success: mock(() => "id"),
    warning: mock(() => "id"), error: mock(() => "id"), dismiss: mock(() => "id"),
  };
  const effects = { toast, clearProjects: mock(() => {}), retry: mock(async () => {}) };
  for (const event of fixture.events) {
    if (event.mavenProfileTask) presentMavenProfileTask({ sessionId: event.sessionId, status: event.mavenProfileTask }, effects);
  }
  expect(toast.loading).toHaveBeenCalledTimes(1);
  expect(toast.warning).toHaveBeenCalledTimes(1);
  expect(toast.success).not.toHaveBeenCalled();
});
