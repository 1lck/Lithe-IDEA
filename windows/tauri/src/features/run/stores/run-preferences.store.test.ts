import { beforeEach, expect, test } from "bun:test";
import {
  javaBuildFailurePolicyForWorkspace,
  useRunPreferencesStore,
} from "./run-preferences.store";

beforeEach(() => {
  useRunPreferencesStore.setState({ javaBuildFailurePolicyByWorkspace: {} });
});

test("stores the Java build-failure choice under a normalized workspace key", () => {
  useRunPreferencesStore
    .getState()
    .actions.setJavaBuildFailurePolicy("C:\\Work\\Project\\", "alwaysProceed");

  expect(javaBuildFailurePolicyForWorkspace("c:/work/project")).toBe("alwaysProceed");
  expect(javaBuildFailurePolicyForWorkspace("C:/other")).toBe("ask");
});

test("Ask Again replaces an earlier Always Continue choice", () => {
  const actions = useRunPreferencesStore.getState().actions;
  actions.setJavaBuildFailurePolicy("C:/work/project", "alwaysProceed");
  actions.setJavaBuildFailurePolicy("C:/work/project", "ask");

  expect(javaBuildFailurePolicyForWorkspace("C:/work/project")).toBe("ask");
});

test("scroll-to-end defaults on and the run pane toggle flips it", () => {
  expect(useRunPreferencesStore.getState().scrollOutputToEnd).toBe(true);

  const { setScrollOutputToEnd } = useRunPreferencesStore.getState().actions;
  setScrollOutputToEnd(false);
  expect(useRunPreferencesStore.getState().scrollOutputToEnd).toBe(false);

  setScrollOutputToEnd(true);
  expect(useRunPreferencesStore.getState().scrollOutputToEnd).toBe(true);
});

test("soft wraps default on and toggling keeps single-line mode sticky", () => {
  expect(useRunPreferencesStore.getState().wrapOutputLines).toBe(true);

  const { setWrapOutputLines } = useRunPreferencesStore.getState().actions;
  setWrapOutputLines(false);
  expect(useRunPreferencesStore.getState().wrapOutputLines).toBe(false);

  setWrapOutputLines(true);
  expect(useRunPreferencesStore.getState().wrapOutputLines).toBe(true);
});
