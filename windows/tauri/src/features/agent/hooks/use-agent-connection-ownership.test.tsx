import { afterEach, beforeEach, expect, mock, test } from "bun:test";
import { act, useEffect } from "react";
import { createRoot, type Root } from "react-dom/client";
import { installHappyDom } from "@/test-utils/happy-dom";
import { DEFAULT_AGENT_PANEL_SETTINGS } from "../types/agent-settings.types";

interface PendingOpen {
  workspace: string;
  resolve: () => void;
}

const pendingOpens: PendingOpen[] = [];
let connectedWorkspace: string | null = null;

mock.module("../stores/agent-connection-service", () => ({
  agentConnectionMatches: (workspace: string | null) =>
    workspace !== null && connectedWorkspace === workspace,
  openAgentConnection: (workspace: string) =>
    new Promise<void>((resolve) => {
      pendingOpens.push({
        workspace,
        resolve: () => {
          connectedWorkspace = workspace;
          resolve();
        },
      });
    }),
  closeAgentConnection: async () => {
    connectedWorkspace = null;
  },
}));

const { useAgentConnectionOwnership } = await import("./use-agent-connection-ownership");

const settings = { ...DEFAULT_AGENT_PANEL_SETTINGS, enabled: true };
const actGlobal = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
let previousActEnvironment: boolean | undefined;
let restoreDom: () => void;
let root: Root | undefined;
let container: HTMLDivElement;
const ownership = new Map<string, boolean>();

function Probe({
  id,
  isActive,
  workspace,
}: {
  id: string;
  isActive: boolean;
  workspace: string;
}) {
  const { ownsConnection } = useAgentConnectionOwnership({
    isActive,
    workspacePath: workspace,
    settings,
  });
  useEffect(() => {
    ownership.set(id, ownsConnection);
  }, [id, ownsConnection]);
  return null;
}

beforeEach(() => {
  restoreDom = installHappyDom();
  previousActEnvironment = actGlobal.IS_REACT_ACT_ENVIRONMENT;
  actGlobal.IS_REACT_ACT_ENVIRONMENT = true;
  pendingOpens.length = 0;
  ownership.clear();
  connectedWorkspace = null;
  container = document.createElement("div");
  document.body.append(container);
  root = createRoot(container);
});

afterEach(async () => {
  try {
    await act(async () => root?.unmount());
  } finally {
    root = undefined;
    container.remove();
    restoreDom();
    if (previousActEnvironment === undefined) delete actGlobal.IS_REACT_ACT_ENVIRONMENT;
    else actGlobal.IS_REACT_ACT_ENVIRONMENT = previousActEnvironment;
  }
});

async function settle() {
  await act(async () => {
    await Promise.resolve();
  });
}

test("cached workspaces claim the connection only after their own activation opens", async () => {
  let activeA = true;
  let activeB = false;
  const render = () =>
    root!.render(
      <>
        <Probe id="A" isActive={activeA} workspace="A" />
        <Probe id="B" isActive={activeB} workspace="B" />
      </>,
    );

  await act(async () => render());
  expect(pendingOpens.map((open) => open.workspace)).toEqual(["A"]);
  expect(ownership.get("A")).toBe(false);

  await act(async () => pendingOpens[0].resolve());
  await settle();
  expect(ownership.get("A")).toBe(true);
  expect(ownership.get("B")).toBe(false);

  await act(async () => {
    activeA = false;
    activeB = true;
    render();
  });
  expect(pendingOpens.map((open) => open.workspace)).toEqual(["A", "B"]);
  expect(ownership.get("A")).toBe(false);
  expect(ownership.get("B")).toBe(false);

  await act(async () => pendingOpens[1].resolve());
  await settle();
  expect(ownership.get("A")).toBe(false);
  expect(ownership.get("B")).toBe(true);

  await act(async () => {
    activeA = true;
    activeB = false;
    render();
  });
  expect(pendingOpens.map((open) => open.workspace)).toEqual(["A", "B", "A"]);
  expect(ownership.get("A")).toBe(false);
  expect(ownership.get("B")).toBe(false);

  await act(async () => pendingOpens[2].resolve());
  await settle();
  expect(ownership.get("A")).toBe(true);
  expect(ownership.get("B")).toBe(false);
});
