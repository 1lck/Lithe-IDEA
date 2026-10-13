import { afterEach, beforeEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { LocaleProvider } from "@/i18n/locale-provider";
import { createTranslator } from "@/i18n/locale";
import { installHappyDom } from "@/test-utils/happy-dom";
import { mapCoreConfiguration } from "../utils/run-configuration";
import type { RunConfiguration, RunSession } from "../types/run.types";

let restoreDom: () => void;
let container: HTMLDivElement;
let root: Root;
let RunConfigurationList: typeof import("./run-configuration-list").RunConfigurationList;
const environment = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
let previousEnvironment: boolean | undefined;

const configurations = [
  { id: "worker", name: "WorkerApplication", provider: "spring-boot.maven", execution: "service" },
  { id: "api", name: "ApiApplication", provider: "spring-boot.maven", execution: "service" },
  {
    id: "main",
    name: "Main (src/main/java/example/Main.java)",
    provider: "java.main",
    execution: "application",
  },
  {
    id: "db",
    name: "database",
    provider: "docker.compose",
    category: "infrastructure",
    execution: "service",
  },
].map(mapCoreConfiguration);
const selected: string[] = [];
const launched: string[] = [];
const stopped: string[] = [];
const edited: string[] = [];
const t = createTranslator("en-US");

beforeEach(async () => {
  restoreDom = installHappyDom();
  previousEnvironment = environment.IS_REACT_ACT_ENVIRONMENT;
  environment.IS_REACT_ACT_ENVIRONMENT = true;
  container = document.createElement("div");
  document.body.append(container);
  root = createRoot(container);
  selected.length = launched.length = stopped.length = edited.length = 0;
  ({ RunConfigurationList } = await import("./run-configuration-list"));
});

afterEach(() => {
  try {
    act(() => root.unmount());
  } finally {
    container.remove();
    if (previousEnvironment === undefined) delete environment.IS_REACT_ACT_ENVIRONMENT;
    else environment.IS_REACT_ACT_ENVIRONMENT = previousEnvironment;
    restoreDom();
  }
});

function render(
  selectedId: string | null = null,
  sessions: RunSession[] = [],
  entries: RunConfiguration[] = configurations,
) {
  act(() =>
    root.render(
      <LocaleProvider language="en-US">
        <RunConfigurationList
          configurations={entries}
          selectedId={selectedId}
          sessions={sessions}
          onSelect={(id) => selected.push(id)}
          onRun={(configuration) => launched.push(configuration.id)}
          onStop={(id) => stopped.push(id)}
          onEdit={(id) => edited.push(id)}
        />
      </LocaleProvider>,
    ),
  );
}

function group(title: string): HTMLButtonElement {
  const button = Array.from(
    container.querySelectorAll<HTMLButtonElement>("button[aria-expanded]"),
  ).find((element) => element.textContent === title);
  if (!button) throw new Error(`Missing configuration group: ${title}`);
  return button;
}

test("configuration types form collapsible groups and selected infrastructure is revealed", () => {
  render();
  expect(
    Array.from(container.querySelectorAll("button[aria-expanded]")).map((node) => node.textContent),
  ).toEqual(["Spring Boot", "Java Application", "Docker"]);
  const spring = group("Spring Boot");
  const children = document.getElementById(spring.getAttribute("aria-controls")!);
  expect(children?.textContent).toBe("ApiApplicationWorkerApplication");
  expect(spring.getAttribute("aria-expanded")).toBe("true");
  expect(group("Docker").getAttribute("aria-expanded")).toBe("false");
  act(() => spring.click());
  expect(children?.hidden).toBe(true);
  act(() =>
    spring.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowRight", bubbles: true })),
  );
  expect(children?.hidden).toBe(false);
  act(() =>
    spring.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowLeft", bubbles: true })),
  );
  expect(children?.hidden).toBe(true);
  render("db");
  expect(group("Docker").getAttribute("aria-expanded")).toBe("true");
  expect(
    container.querySelector('[title="database"][aria-pressed]')?.getAttribute("aria-pressed"),
  ).toBe("true");
  // Selecting a configuration via another entry point must reveal it in a collapsed group.
  render("api");
  expect(group("Spring Boot").getAttribute("aria-expanded")).toBe("true");
});

test("mixed npm services group by Core framework and keep type icons across process states", () => {
  const entries = [
    {
      id: "vue",
      name: "Web",
      execution: "service",
      extensions: { npm: { framework: "vue", manager: "pnpm" } },
    },
    {
      id: "next",
      name: "Admin",
      execution: "service",
      extensions: { npm: { framework: "next", manager: "pnpm" } },
    },
    {
      id: "build",
      name: "Build",
      execution: "task",
      extensions: { npm: { framework: "vue", manager: "pnpm" } },
    },
  ].map((entry) => mapCoreConfiguration({ ...entry, provider: "npm.script" }));
  render("vue", [], entries);
  for (const [title, icon] of [
    ["Vue", "vue"],
    ["Next.js", "next"],
    ["pnpm", "pnpm"],
  ]) {
    const header = group(title);
    expect(header.querySelector("[data-run-icon]")?.getAttribute("data-run-icon")).toBe(icon);
    const children = document.getElementById(header.getAttribute("aria-controls")!);
    expect(children?.querySelector("[data-run-icon]")?.getAttribute("data-run-icon")).toBe(icon);
  }
  const session = {
    id: "web-session",
    configurationId: "vue",
    title: "Web",
    output: "",
    isRunning: true,
    exitCode: null,
  };
  for (const state of [session, { ...session, isRunning: false, exitCode: 1 }]) {
    render("vue", [state], entries);
    const row = container.querySelector('[title="Web"][aria-pressed]')!.closest("li")!;
    expect(row.querySelector("[data-run-icon]")?.getAttribute("data-run-icon")).toBe("vue");
    expect(
      row.querySelector(`[aria-label="${t(state.isRunning ? "run.stop" : "run.title")}"]`),
    ).not.toBeNull();
  }
});

test("same-title custom providers stay separate while known frameworks share a group", () => {
  const entries = [
    { id: "custom", name: "Custom command", provider: "react.command", execution: "service" },
    {
      id: "react",
      name: "React app",
      provider: "npm.script",
      execution: "service",
      extensions: { npm: { framework: "react", manager: "pnpm" } },
    },
    { id: "maven", name: "Maven API", provider: "spring-boot.maven", execution: "service" },
    {
      id: "gradle",
      name: "Gradle API",
      provider: "gradle.task",
      execution: "service",
      extensions: { gradle: { plugin: "org.springframework.boot" } },
    },
    {
      id: "external",
      name: "External API",
      provider: "spring-boot.maven",
      execution: "service",
      category: "infrastructure",
    },
  ].map(mapCoreConfiguration);
  render(null, [], entries);
  const headers = Array.from(
    container.querySelectorAll<HTMLButtonElement>("button[aria-expanded]"),
  );
  expect(headers).toHaveLength(4);
  function headerFor(id: string): HTMLButtonElement {
    const name = entries.find((entry) => entry.id === id)!.name;
    const row = container.querySelector(`[title="${name}"][aria-pressed]`)!;
    const children = row.closest("li")!.parentElement!;
    return headers.find((header) => header.getAttribute("aria-controls") === children.id)!;
  }
  const custom = headerFor("custom");
  const react = headerFor("react");
  expect(custom.textContent).toBe("React");
  expect(react.textContent).toBe("React");
  expect(custom).not.toBe(react);
  expect(headerFor("maven")).toBe(headerFor("gradle"));
  expect(headerFor("maven")).not.toBe(headerFor("external"));
  for (const header of headers) {
    const icon = header.querySelector("[data-run-icon]")!.getAttribute("data-run-icon");
    const children = document.getElementById(header.getAttribute("aria-controls")!)!;
    for (const child of children.querySelectorAll("[data-run-icon]")) {
      expect(child.getAttribute("data-run-icon")).toBe(icon);
    }
  }
  expect(custom.querySelector("[data-run-icon]")?.getAttribute("data-run-icon")).toBe("terminal");
  expect(react.querySelector("[data-run-icon]")?.getAttribute("data-run-icon")).toBe("react");
  act(() => custom.click());
  expect(custom.getAttribute("aria-expanded")).toBe("false");
  expect(react.getAttribute("aria-expanded")).toBe("true");
  act(() => react.click());
  render("custom", [], entries);
  expect(custom.getAttribute("aria-expanded")).toBe("true");
  expect(react.getAttribute("aria-expanded")).toBe("false");
});

test("list selection, launch, stop and edit target the correct configuration or session", () => {
  render("main", [
    {
      id: "worker-session",
      configurationId: "worker",
      title: "Worker",
      output: "",
      isRunning: true,
      exitCode: null,
    },
  ]);
  const main = container.querySelector<HTMLButtonElement>(
    '[title="Main (src/main/java/example/Main.java)"]',
  )!;
  expect(main.getAttribute("aria-pressed")).toBe("true");
  act(() => main.click());
  act(() =>
    main
      .closest("li")!
      .querySelector<HTMLButtonElement>(`[aria-label="${t("run.title")}"]`)!
      .click(),
  );
  act(() =>
    main
      .closest("li")!
      .querySelector<HTMLButtonElement>(`[aria-label="${t("run.editService")}"]`)!
      .click(),
  );
  act(() => container.querySelector<HTMLButtonElement>(`[aria-label="${t("run.stop")}"]`)!.click());
  expect(selected).toEqual(["main"]);
  expect(launched).toEqual(["main"]);
  expect(edited).toEqual(["main"]);
  expect(stopped).toEqual(["worker-session"]);
});
