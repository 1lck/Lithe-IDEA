import { expect, mock, test } from "bun:test";
import { isJavaLifecycle, ownedLifecycleHandler } from "./owned-lifecycle-event";

test("broadcast Maven events affect only the window owning the session, including background projects", () => {
  const windowA = new Set(["java-a", "background-a"]);
  const windowB = new Set(["java-b"]);
  const receivedA = mock(() => {});
  const receivedB = mock(() => {});
  const handlers = [
    ownedLifecycleHandler((id) => windowA.has(id), receivedA),
    ownedLifecycleHandler((id) => windowB.has(id), receivedB),
  ];
  for (const sessionId of ["java-a", "background-a"]) {
    handlers.forEach((handler) => handler({ payload: { sessionId, providerId: "java" } }));
  }
  expect(receivedA).toHaveBeenCalledTimes(2);
  expect(receivedB).not.toHaveBeenCalled();
});

test("non-Java readiness updates generic state without Java presentation", () => {
  const updateState = mock(() => {});
  const javaToast = mock(() => {});
  const handle = ownedLifecycleHandler(() => true, (payload) => {
    updateState();
    if (isJavaLifecycle(payload)) javaToast();
  });
  handle({ payload: { sessionId: "python", providerId: "python" } });
  expect(updateState).toHaveBeenCalledTimes(1);
  expect(javaToast).not.toHaveBeenCalled();
});
