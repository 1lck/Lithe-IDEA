import { afterAll, expect, test } from "bun:test";
import { act } from "react";
import type { Root } from "react-dom/client";
import { installHappyDom } from "@/test-utils/happy-dom";
import { LocaleProvider } from "@/i18n/locale-provider";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import { PluginFunctionAction } from "./plugin-function-action";
import {
  PluginFunctionSession,
  type FunctionInput,
  type FunctionReview,
} from "./plugin-function-session";

const restore = installHappyDom();
afterAll(restore);
const { createRoot } = await import("react-dom/client");

async function mounted(body: (host: HTMLDivElement, calls: string[]) => Promise<void>) {
  const globals = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
  const previousAct = globals.IS_REACT_ACT_ENVIRONMENT;
  const previous = workspaceRuntimeRegistry.getActiveWorkspace()!.descriptor;
  const id = "function-action-ui";
  const host = document.createElement("div");
  const calls: string[] = [];
  const sessions: PluginFunctionSession[] = [];
  let root: Root | null = null;
  const factory = (
    input: FunctionInput,
    assertCurrent: () => void,
    publish: ConstructorParameters<typeof PluginFunctionSession>[2],
  ) => {
    const review: FunctionReview = {
      context: {
        window: "workspace-fixture",
        workspacePath: input.workspacePath,
        generation: 1,
        pluginId: input.pluginId,
        packageIdentity: "package-bytes",
        settingIdentity: input.expectedIdentity,
        actionId: input.actionId,
        functionId: "snapshot.refresh",
        operationId: input.operationId,
      },
      title: "Refresh",
      confirm: true,
      executesProjectCode: true,
      mayUseNetwork: false,
      launchPlan: { launch: { kind: "packaged" } },
      program: { serverPath: "/fixture/backend" },
    };
    const session = new PluginFunctionSession(
      input,
      {
        prepare: async () => {
          calls.push("prepare");
          return review;
        },
        confirm: async () => {
          calls.push("confirm");
        },
        read: async () => ({
          context: review.context,
          phase: "succeeded",
          result: { refreshed: true },
        }),
        cancel: async () => {
          calls.push("cancel");
        },
        assertCurrent,
        wait: async () => {},
        deadline: () => () => {},
      },
      publish,
      () => {},
    );
    sessions.push(session);
    return session;
  };
  try {
    globals.IS_REACT_ACT_ENVIRONMENT = true;
    workspaceRuntimeRegistry.activateWorkspace(
      { id, name: "Fixture", path: "/fixture/project" },
      "ready",
    );
    document.body.append(host);
    root = createRoot(host);
    await act(async () =>
      root!.render(
        <LocaleProvider language="en-US">
          <PluginFunctionAction
            pluginId="example.plugin"
            action={{
              id: "refresh",
              title: "Refresh",
              function: "snapshot.refresh",
              confirm: true,
            }}
            workspacePath="/fixture/project"
            identity="saved-values"
            createSession={factory}
          />
        </LocaleProvider>,
      ),
    );
    expect(calls).toEqual([]);
    await body(host, calls);
  } finally {
    try {
      await act(async () => root?.unmount());
      for (const session of sessions) {
        session.dispose();
        await session.cancel();
      }
    } finally {
      host.remove();
      workspaceRuntimeRegistry.activateWorkspace(previous);
      workspaceRuntimeRegistry.removeWorkspace(id);
      if (previousAct === undefined) delete globals.IS_REACT_ACT_ENVIRONMENT;
      else globals.IS_REACT_ACT_ENVIRONMENT = previousAct;
    }
  }
}

function button(host: HTMLDivElement, text: string) {
  return [...host.querySelectorAll<HTMLButtonElement>("button")].find(
    (item) => item.textContent === text,
  )!;
}

test("settings action shows native program and action confirmation; cancel never starts", async () => {
  await mounted(async (host, calls) => {
    await act(async () => button(host, "Refresh").click());
    expect(host.textContent).toContain("/fixture/backend");
    expect(host.textContent).toContain("/fixture/project");
    expect(host.textContent).toContain("This action requires confirmation");
    expect(calls).toEqual(["prepare"]);
    await act(async () => button(host, "Cancel").click());
    expect(calls).toEqual(["prepare", "cancel"]);
    expect(host.textContent).toContain("Plugin action cancelled");
  });
}, 3000);

test("explicit confirmation renders the actual result and a new attempt prepares again", async () => {
  await mounted(async (host, calls) => {
    await act(async () => button(host, "Refresh").click());
    await act(async () => button(host, "Confirm and run").click());
    expect(calls).toEqual(["prepare", "confirm", "cancel"]);
    expect(host.textContent).toContain('"refreshed": true');
    await act(async () => button(host, "Run again").click());
    expect(calls).toEqual(["prepare", "confirm", "cancel", "prepare"]);
  });
}, 3000);
