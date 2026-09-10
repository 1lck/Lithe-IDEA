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
  const options = (toast.warning.mock.calls as unknown as [string, { id: string; action: { onClick: () => void } }][])[0][1];
  expect(options.id).toBe("java-maven-profiles:java");
  options.action.onClick();
  expect(effects.retry).toHaveBeenCalledWith("java");
  await effects.retry.mock.results[0].value;
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
