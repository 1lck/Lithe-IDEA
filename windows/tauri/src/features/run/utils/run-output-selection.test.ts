import { expect, test } from "bun:test";
import { selectRunOutput } from "./run-output-selection";
import type { RunSession } from "../types/run.types";

const primary = { configurationId: "main", output: "Main output", isRunning: true, exitCode: null };
const sessions: RunSession[] = [
  {
    id: "api-slot",
    configurationId: "api",
    title: "API",
    output: "API output",
    isRunning: true,
    exitCode: null,
  },
  {
    id: "web-slot",
    configurationId: "web",
    title: "Web",
    output: "Web error",
    isRunning: false,
    exitCode: 1,
  },
];

test("switching configurations selects only their own output and stdin/stop session", () => {
  expect(selectRunOutput("api", sessions, primary)).toMatchObject({
    sessionId: "api-slot",
    output: "API output",
    isRunning: true,
    exitCode: null,
  });
  expect(selectRunOutput("web", sessions, primary)).toMatchObject({
    sessionId: "web-slot",
    output: "Web error",
    isRunning: false,
    exitCode: 1,
  });
  expect(selectRunOutput("main", sessions, primary)).toMatchObject({
    sessionId: "primary",
    output: "Main output",
    isRunning: true,
    hasOutputOwner: true,
  });
});

test("an unstarted configuration never borrows another application's output or controls", () => {
  expect(selectRunOutput("unstarted", sessions, primary)).toMatchObject({
    output: "",
    isRunning: false,
    exitCode: null,
    hasOutputOwner: false,
  });
  expect(selectRunOutput(null, sessions, primary)).toMatchObject({
    output: "Main output",
    isRunning: true,
  });
});
