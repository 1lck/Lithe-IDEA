import { expect, test } from "bun:test";
import { act, useState } from "react";
import { createRoot, type Root } from "react-dom/client";
import { createTranslator } from "@/i18n/locale";
import { LocaleProvider } from "@/i18n/locale-provider";
import { installHappyDom } from "@/test-utils/happy-dom";
import { mapCoreConfiguration } from "../utils/run-configuration";

test("service menu opens without unmounting the workbench and runs the selected services", async () => {
  const restoreDom = installHappyDom();
  let RunServicesMenu: typeof import("./run-services-menu").RunServicesMenu;
  const environment = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
  const previousEnvironment = environment.IS_REACT_ACT_ENVIRONMENT;
  const container = document.createElement("div");
  const t = createTranslator("en-US");
  const services = ["api", "worker"].map((id) =>
    mapCoreConfiguration({
      id,
      name: id,
      provider: "spring-boot.maven",
      execution: "service",
    }),
  );
  const executions: string[][] = [];
  let root: Root | undefined;

  function Workbench() {
    const [selected, setSelected] = useState(["api"]);
    return (
      <LocaleProvider language="en-US">
        <main>Editor remains mounted</main>
        <RunServicesMenu
          services={services}
          selectedServiceIDs={selected}
          disabled={false}
          onSelectionChange={setSelected}
          onRunSelected={() => executions.push(selected)}
          onRunAll={() => executions.push(services.map((service) => service.id))}
        />
      </LocaleProvider>
    );
  }

  const click = async (element: Element | null) => {
    expect(element).not.toBeNull();
    await act(async () => (element as HTMLElement).click());
  };
  const menuItem = (label: string) =>
    Array.from(document.querySelectorAll('[role="menuitem"]')).find(
      (element) => element.textContent === label,
    ) ?? null;
  const checkbox = (label: string) =>
    Array.from(document.querySelectorAll('[role="menuitemcheckbox"]')).find(
      (element) => element.textContent === label,
    ) ?? null;
  const openMenu = async () => {
    if (!document.querySelector('[role="menu"]')) {
      await click(container.querySelector(`[aria-label="${t("run.chooseServices")}"]`));
    }
  };

  try {
    ({ RunServicesMenu } = await import("./run-services-menu"));
    environment.IS_REACT_ACT_ENVIRONMENT = true;
    document.body.append(container);
    root = createRoot(container);
    const mountedRoot = root;
    await act(async () => mountedRoot.render(<Workbench />));
    await openMenu();
    expect(container.querySelector("main")?.textContent).toBe("Editor remains mounted");
    const group = document.querySelector('[role="group"]');
    expect(group).not.toBeNull();
    const labelId = group?.getAttribute("aria-labelledby");
    expect(labelId).toBeTruthy();
    expect(document.getElementById(labelId!)?.textContent).toBe(t("run.services"));
    expect(checkbox("api")?.getAttribute("aria-checked")).toBe("true");
    await click(checkbox("worker"));
    await openMenu();
    expect(checkbox("worker")?.getAttribute("aria-checked")).toBe("true");
    await click(menuItem(t("run.runSelectedServices")));
    expect(executions).toEqual([["api", "worker"]]);
    await openMenu();
    await click(checkbox("api"));
    await openMenu();
    await click(checkbox("worker"));
    await openMenu();
    expect(menuItem(t("run.runSelectedServices"))?.getAttribute("aria-disabled")).toBe("true");
    await click(menuItem(t("run.runAllServices")));
    expect(executions).toEqual([
      ["api", "worker"],
      ["api", "worker"],
    ]);
    expect(container.querySelector("main")).not.toBeNull();
  } finally {
    try {
      await act(async () => root?.unmount());
    } finally {
      container.remove();
      if (previousEnvironment === undefined) delete environment.IS_REACT_ACT_ENVIRONMENT;
      else environment.IS_REACT_ACT_ENVIRONMENT = previousEnvironment;
      restoreDom();
    }
  }
}, 5000);

test("repository menu opens and selects a repository without unmounting the workbench", async () => {
  const restoreDom = installHappyDom();
  const environment = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
  const previousEnvironment = environment.IS_REACT_ACT_ENVIRONMENT;
  const container = document.createElement("div");
  let root: Root | undefined;
  let restoreStore = () => {};
  try {
    const { default: GitProjectSelector } = await import("@/features/git/components/git-project-selector");
    const { useRepositoryStore } = await import("@/features/git/stores/git-repository.store");
    const previousState = useRepositoryStore.getState();
    restoreStore = () => useRepositoryStore.setState(previousState);
    useRepositoryStore.setState({
      workspaceRootPath: "/workspace",
      availableRepoPaths: ["/workspace/api", "/workspace/worker"],
      activeRepoPath: "/workspace/api",
      isDiscovering: false,
    });
    const selected: string[] = [];
    environment.IS_REACT_ACT_ENVIRONMENT = true;
    document.body.append(container);
    root = createRoot(container);
    const mountedRoot = root;
    await act(async () => mountedRoot.render(
      <LocaleProvider language="en-US">
        <main>Editor remains mounted</main>
        <GitProjectSelector onRepositoryChange={(path) => path && selected.push(path)} />
      </LocaleProvider>,
    ));
    const trigger = container.querySelector<HTMLElement>('[data-slot="dropdown-menu-trigger"]');
    expect(trigger).not.toBeNull();
    await act(async () => trigger!.click());
    expect(document.querySelector('[role="menu"]')).not.toBeNull();
    const worker = Array.from(document.querySelectorAll<HTMLElement>('[role="menuitemradio"]'))
      .find((element) => element.textContent?.includes("worker"));
    expect(worker).toBeDefined();
    await act(async () => worker!.click());
    expect(selected).toEqual(["/workspace/worker"]);
    expect(useRepositoryStore.getState().activeRepoPath).toBe("/workspace/worker");
    expect(container.querySelector("main")).not.toBeNull();
  } finally {
    try {
      await act(async () => root?.unmount());
    } finally {
      restoreStore();
      container.remove();
      if (previousEnvironment === undefined) delete environment.IS_REACT_ACT_ENVIRONMENT;
      else environment.IS_REACT_ACT_ENVIRONMENT = previousEnvironment;
      restoreDom();
    }
  }
}, 5000);
