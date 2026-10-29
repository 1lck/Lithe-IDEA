import { afterAll, afterEach, expect, test } from "bun:test";
import { act } from "react";
import type { Root } from "react-dom/client";
import { LocaleProvider } from "@/i18n/locale-provider";
import { installHappyDom } from "@/test-utils/happy-dom";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import { WorkspaceStoreScopeContext } from "@/features/workspace/stores/create-workspace-scoped-store";
import {
  buildOutputSessionId,
  type BuildOperationIdentity,
  type BuildOutputEvent,
  type BuildOutputPort,
} from "../build-output-types";
import { useBuildOutputStore } from "../build-output-store";

const restoreDom = installHappyDom();
const { createRoot } = await import("react-dom/client");
const { default: BuildOutputPane } = await import("./build-output-pane");
afterAll(restoreDom);

/**
 * Component tests for the mountable build output panel: event streaming
 * through the injected port, operation binding of late events, the stop
 * control's honest success and failure paths, subscription cleanup on close
 * and operation switch without cancelling runs the panel does not own, and
 * isolation between two session identities.
 */

const WORKSPACE = "C:/work/output-pane-fixture";
const PLUGIN = "dev.lithe.fixture.build-static-file";
const SESSION_A = buildOutputSessionId(PLUGIN, "cargo", ".");
const SESSION_B = buildOutputSessionId(PLUGIN, "cargo", "crates/app");

/**
 * Deterministic port double: the test drives every event and resolution, so
 * no timer, poll, or real process is involved.
 */
class FakeBuildOutputPort implements BuildOutputPort {
  private readonly sinks = new Map<string, (event: BuildOutputEvent) => void>();
  readonly subscribed: string[] = [];
  readonly unsubscribed: string[] = [];
  readonly cancelRequests: BuildOperationIdentity[] = [];
  readonly retainedSinks: Array<(event: BuildOutputEvent) => void> = [];
  subscribeOutcome: (() => Promise<() => void>) | null = null;
  private cancelOutcome: ((identity: BuildOperationIdentity) => Promise<void>) | null = null;

  subscribe(
    identity: BuildOperationIdentity,
    sink: (event: BuildOutputEvent) => void,
  ): (() => void) | Promise<() => void> {
    this.subscribed.push(identity.operationId);
    this.sinks.set(identity.operationId, sink);
    this.retainedSinks.push(sink);
    const unsubscribe = () => {
      this.sinks.delete(identity.operationId);
      this.unsubscribed.push(identity.operationId);
    };
    return this.subscribeOutcome ? this.subscribeOutcome() : unsubscribe;
  }

  cancel(identity: BuildOperationIdentity): Promise<void> {
    this.cancelRequests.push(identity);
    return (this.cancelOutcome ?? (() => Promise.resolve()))(identity);
  }

  /** Redirects future cancel calls; defaults to resolving successfully. */
  onCancel(outcome: (identity: BuildOperationIdentity) => Promise<void>): void {
    this.cancelOutcome = outcome;
  }

  emit(event: BuildOutputEvent): void {
    this.sinks.get(event.operationId)?.(event);
  }
}

const cleanups: Array<() => void | Promise<void>> = [];
afterEach(async () => {
  for (const cleanup of cleanups.splice(0).reverse()) await cleanup();
  workspaceRuntimeRegistry.resetForTests();
});

function deferred<T>(cleanupValue: T) {
  let resolve!: (value: T) => void;
  let reject!: (error: Error) => void;
  const promise = new Promise<T>((yes, no) => {
    resolve = yes;
    reject = no;
  });
  cleanups.push(() => resolve(cleanupValue));
  return { promise, resolve, reject };
}

function identity(operationId: string, root = "."): BuildOperationIdentity {
  return {
    operationId,
    pluginId: PLUGIN,
    buildSystemId: "cargo",
    root,
    workspaceRoot: WORKSPACE,
    generation: 1,
    title: "cargo build",
  };
}

function ref(operationId: string, root = ".") {
  return identity(operationId, root);
}

function diagnostic(path: string, line: number) {
  return { path, line, severity: "error" as const, message: `problem ${path}:${line}` };
}

function begin(sessionId: string, run: BuildOperationIdentity) {
  useBuildOutputStore.getState().actions.beginOperation(sessionId, run);
}

async function mount(props: {
  sessionId?: string;
  port: FakeBuildOutputPort;
  onClose?: () => void;
  workspaceId?: string;
  scoped?: boolean;
}) {
  await act(async () =>
    workspaceRuntimeRegistry.activateWorkspace(
      { id: props.workspaceId ?? "output-pane-tests", name: "Fixture", path: WORKSPACE },
      "ready",
    ),
  );
  await act(async () => useBuildOutputStore.getState().actions.reset());
  const environment = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
  const previousAct = environment.IS_REACT_ACT_ENVIRONMENT;
  environment.IS_REACT_ACT_ENVIRONMENT = true;
  const host = document.createElement("div");
  document.body.append(host);
  const root: Root = createRoot(host);
  cleanups.push(async () => {
    try {
      await act(async () => root.unmount());
    } finally {
      host.remove();
      if (previousAct === undefined) delete environment.IS_REACT_ACT_ENVIRONMENT;
      else environment.IS_REACT_ACT_ENVIRONMENT = previousAct;
    }
  });
  const sessionId = props.sessionId ?? SESSION_A;
  const render = () =>
    root.render(
      <LocaleProvider language="en-US">
        <WorkspaceStoreScopeContext.Provider value={props.scoped ? props.workspaceId! : null}>
          <BuildOutputPane
            sessionId={sessionId}
            port={props.port}
            onClose={props.onClose ?? (() => {})}
          />
        </WorkspaceStoreScopeContext.Provider>
      </LocaleProvider>,
    );
  await act(async () => render());
  return { host, root, render, sessionId };
}

function stopButton(host: HTMLElement): HTMLButtonElement | null {
  return host.querySelector<HTMLButtonElement>('button[aria-label="Stop build task"]');
}

function clearButton(host: HTMLElement): HTMLButtonElement | null {
  return host.querySelector<HTMLButtonElement>('button[aria-label="Clear build output"]');
}

test("mounts into the empty state and subscribes once a run begins", async () => {
  const port = new FakeBuildOutputPort();
  const { host } = await mount({ port });

  expect(host.textContent).toContain("Run a build task to see output.");
  expect(port.subscribed).toEqual([]);

  await act(async () => begin(SESSION_A, identity("op-1")));
  expect(port.subscribed).toEqual(["op-1"]);

  await act(async () =>
    port.emit({ type: "chunk", ...ref("op-1"), stream: "stdout", text: "Compiling app\n" }),
  );
  expect(host.textContent).toContain("Compiling app");
});

test("stderr, terminal state, and post-terminal decodes all render", async () => {
  const port = new FakeBuildOutputPort();
  const { host } = await mount({ port });
  await act(async () => begin(SESSION_A, identity("op-1")));

  await act(async () => {
    port.emit({
      type: "chunk",
      ...ref("op-1"),
      stream: "stderr",
      text: "warning: unused import\n",
    });
    port.emit({
      type: "terminal",
      ...ref("op-1"),
      terminal: { kind: "failed", exitCode: 1, message: "compile error" },
    });
    port.emit({ type: "diagnostics", ...ref("op-1"), diagnostics: [diagnostic("src/main.rs", 4)] });
    port.emit({
      type: "testResults",
      ...ref("op-1"),
      results: {
        tests: [{ suite: "OrderTest", case: "refunds", status: "failed", invocations: 1 }],
        summary: { total: 1, passed: 0, failed: 1, errors: 0, skipped: 0 },
        success: false,
      },
    });
  });

  expect(host.textContent).toContain("warning: unused import");
  expect(host.textContent).toContain("Failed");
  expect(host.textContent).toContain("compile error");
  expect(host.textContent).toContain("src/main.rs:4");
  expect(host.textContent).toContain("Tests failed");
  expect(stopButton(host)).toBeNull();
});

test("cancel acceptance keeps the run stopping until an authoritative terminal event", async () => {
  const port = new FakeBuildOutputPort();
  const { host } = await mount({ port });
  await act(async () => begin(SESSION_A, identity("op-1")));

  const cancellation = deferred<void>(undefined);
  port.onCancel(() => cancellation.promise);
  await act(async () => stopButton(host)!.click());

  // While the owner has not confirmed, the run is still running.
  expect(port.cancelRequests).toHaveLength(1);
  expect(host.querySelector('[aria-label="Stop build task"]')!.hasAttribute("disabled")).toBe(true);
  expect(useBuildOutputStore.getState().sessions[SESSION_A]!.status).toBe("running");

  await act(async () => cancellation.resolve());

  expect(useBuildOutputStore.getState().sessions[SESSION_A]!.status).toBe("running");
  expect(host.textContent).toContain("Stopping");
  await act(async () =>
    port.emit({ type: "terminal", ...ref("op-1"), terminal: { kind: "cancelled" } }),
  );

  const session = useBuildOutputStore.getState().sessions[SESSION_A]!;
  expect(session.status).toBe("cancelled");
  expect(session.terminal?.kind).toBe("cancelled");
  expect(host.textContent).toContain("Cancelled");
});

test("a rejected cancel keeps the run running and restores the stop control", async () => {
  const port = new FakeBuildOutputPort();
  const { host } = await mount({ port });
  await act(async () => begin(SESSION_A, identity("op-1")));
  port.onCancel(() => Promise.reject(new Error("owner refused")));

  await act(async () => stopButton(host)!.click());
  await act(async () => stopButton(host)!.click());

  expect(port.cancelRequests).toHaveLength(2);
  const session = useBuildOutputStore.getState().sessions[SESSION_A]!;
  expect(session.status).toBe("running");
  expect(session.cancelError).toBe("owner refused");
  expect(host.textContent).toContain("Stopping the run failed: owner refused");
  expect(stopButton(host)!.hasAttribute("disabled")).toBe(false);
});

test("a native terminal that lands first wins over the cancel confirmation", async () => {
  const port = new FakeBuildOutputPort();
  const { host } = await mount({ port });
  await act(async () => begin(SESSION_A, identity("op-1")));
  const cancellation = deferred<void>(undefined);
  port.onCancel(() => cancellation.promise);

  await act(async () => stopButton(host)!.click());
  // The process finishes on its own while the stop is pending.
  await act(async () =>
    port.emit({
      type: "terminal",
      ...ref("op-1"),
      terminal: { kind: "succeeded", exitCode: 0 },
    }),
  );
  await act(async () => cancellation.resolve());

  expect(useBuildOutputStore.getState().sessions[SESSION_A]!.status).toBe("succeeded");
  expect(host.textContent).toContain("Succeeded");
});

test("closing the panel unsubscribes without cancelling the run", async () => {
  const port = new FakeBuildOutputPort();
  const { host, root } = await mount({ port });
  await act(async () => begin(SESSION_A, identity("op-1")));
  expect(port.subscribed).toEqual(["op-1"]);

  await act(async () => root.render(null));

  expect(port.unsubscribed).toEqual(["op-1"]);
  expect(port.cancelRequests).toEqual([]);
  expect(useBuildOutputStore.getState().sessions[SESSION_A]!.status).toBe("running");
  expect(host.textContent).not.toContain("Cancelled");
});

test("switching operations resubscribes and drops the old operation's late terminal", async () => {
  const port = new FakeBuildOutputPort();
  const { host } = await mount({ port });
  await act(async () => begin(SESSION_A, identity("op-1")));
  await act(async () =>
    port.emit({ type: "chunk", ...ref("op-1"), stream: "stdout", text: "first run\n" }),
  );

  await act(async () => begin(SESSION_A, identity("op-2")));
  expect(port.subscribed).toEqual(["op-1", "op-2"]);
  expect(port.unsubscribed).toEqual(["op-1"]);
  expect(host.textContent).not.toContain("first run");

  await act(async () => {
    // The stale sink is gone; even a direct store write must not land.
    port.emit({
      type: "terminal",
      ...ref("op-1"),
      terminal: { kind: "failed", message: "late failure" },
    });
  });

  const session = useBuildOutputStore.getState().sessions[SESSION_A]!;
  expect(session.identity.operationId).toBe("op-2");
  expect(session.status).toBe("running");
});

test("clear returns the panel to the empty state and drops the subscription", async () => {
  const port = new FakeBuildOutputPort();
  const { host } = await mount({ port });
  await act(async () => begin(SESSION_A, identity("op-1")));
  await act(async () =>
    port.emit({ type: "chunk", ...ref("op-1"), stream: "stdout", text: "output\n" }),
  );

  await act(async () => clearButton(host)!.click());

  expect(host.textContent).toContain("Run a build task to see output.");
  expect(port.unsubscribed).toEqual(["op-1"]);
  expect(useBuildOutputStore.getState().sessions[SESSION_A]).toBeUndefined();
});

test("two session identities stay isolated on one port", async () => {
  const port = new FakeBuildOutputPort();
  const { host: hostA } = await mount({ port, sessionId: SESSION_A });
  // A second host for another instance root in the same workspace.
  const secondHost = document.createElement("div");
  document.body.append(secondHost);
  const rootB: Root = createRoot(secondHost);
  cleanups.push(async () => {
    try {
      await act(async () => rootB.unmount());
    } finally {
      secondHost.remove();
    }
  });
  await act(async () =>
    rootB.render(
      <LocaleProvider language="en-US">
        <BuildOutputPane sessionId={SESSION_B} port={port} onClose={() => {}} />
      </LocaleProvider>,
    ),
  );

  await act(async () => {
    begin(SESSION_A, identity("op-a"));
    begin(SESSION_B, identity("op-b", "crates/app"));
  });
  await act(async () => {
    port.emit({ type: "chunk", ...ref("op-a"), stream: "stdout", text: "root output\n" });
    port.emit({
      type: "chunk",
      ...ref("op-b", "crates/app"),
      stream: "stdout",
      text: "nested output\n",
    });
    port.emit({ type: "terminal", ...ref("op-a"), terminal: { kind: "succeeded" } });
  });

  expect(hostA.textContent).toContain("root output");
  expect(hostA.textContent).toContain("Succeeded");
  expect(secondHost.textContent).toContain("nested output");
  expect(secondHost.textContent).not.toContain("Succeeded");
  expect(secondHost.textContent).not.toContain("root output");
});

test("late cancellation failure and success do not affect a replacement run", async () => {
  const port = new FakeBuildOutputPort();
  const { host } = await mount({ port });
  const first = deferred<void>(undefined);
  const second = deferred<void>(undefined);
  port.onCancel(() => first.promise);
  await act(async () => begin(SESSION_A, identity("old")));
  await act(async () => stopButton(host)!.click());
  await act(async () => begin(SESSION_A, identity("new")));
  port.onCancel(() => second.promise);
  await act(async () => stopButton(host)!.click());
  await act(async () => first.reject(new Error("old failure")));
  expect(host.textContent).not.toContain("old failure");
  expect(useBuildOutputStore.getState().sessions[SESSION_A]!.cancelling).toBe(true);
  await act(async () => begin(SESSION_A, identity("latest")));
  await act(async () => second.resolve());
  expect(useBuildOutputStore.getState().sessions[SESSION_A]!.status).toBe("running");
  expect(useBuildOutputStore.getState().sessions[SESSION_A]!.cancelling).toBe(false);
});

test("clear invalidates retained sinks even if the same identity is rebound", async () => {
  const port = new FakeBuildOutputPort();
  const { host } = await mount({ port });
  await act(async () => begin(SESSION_A, identity("old")));
  const stale = port.retainedSinks[0]!;
  await act(async () => clearButton(host)!.click());
  await act(async () => begin(SESSION_A, identity("old")));
  await act(async () => {
    stale({ type: "chunk", ...ref("old"), stream: "stderr", text: "late output\n" });
    stale({ type: "diagnostics", ...ref("old"), diagnostics: [diagnostic("src/main.rs", 1)] });
    stale({
      type: "testResults",
      ...ref("old"),
      results: {
        tests: [],
        summary: { total: 0, passed: 0, failed: 0, errors: 0, skipped: 0 },
        success: true,
      },
    });
    stale({ type: "terminal", ...ref("old"), terminal: { kind: "failed" } });
  });
  expect(host.textContent).not.toContain("late output");
  expect(useBuildOutputStore.getState().sessions[SESSION_A]!.status).toBe("running");
  expect(useBuildOutputStore.getState().sessions[SESSION_A]!.diagnostics).toEqual([]);
  expect(useBuildOutputStore.getState().sessions[SESSION_A]!.testResults).toBeNull();
});

test("a subscription acquired after unmount is released and its retained sink is inert", async () => {
  const port = new FakeBuildOutputPort();
  let releases = 0;
  const acquired = deferred<() => void>(() => {});
  port.subscribeOutcome = () => acquired.promise;
  const { root } = await mount({ port });
  await act(async () => begin(SESSION_A, identity("pending")));
  await act(async () => root.render(null));
  await act(async () =>
    acquired.resolve(() => {
      releases += 1;
    }),
  );
  await act(async () =>
    port.retainedSinks[0]!({ type: "chunk", ...ref("pending"), stream: "stdout", text: "late\n" }),
  );
  expect(releases).toBe(1);
  expect(useBuildOutputStore.getState().sessions[SESSION_A]!.lines).toEqual([]);
  expect(port.cancelRequests).toEqual([]);
});

test("subscription acquisition errors are visible without inventing a run terminal", async () => {
  const port = new FakeBuildOutputPort();
  const acquired = deferred<() => void>(() => {});
  port.subscribeOutcome = () => acquired.promise;
  const { host } = await mount({ port });
  await act(async () => begin(SESSION_A, identity("pending")));
  await act(async () => acquired.reject(new Error("channel unavailable")));
  expect(host.querySelector('[role="alert"]')!.textContent).toContain("channel unavailable");
  expect(useBuildOutputStore.getState().sessions[SESSION_A]!.status).toBe("running");
});

test("workspace switches discard late events and old cancellation callbacks on A to B to A", async () => {
  const port = new FakeBuildOutputPort();
  const { host } = await mount({ port });
  const cancellation = deferred<void>(undefined);
  port.onCancel(() => cancellation.promise);
  await act(async () => begin(SESSION_A, identity("old")));
  await act(async () => stopButton(host)!.click());
  const stale = port.retainedSinks[0]!;
  await act(async () =>
    workspaceRuntimeRegistry.activateWorkspace(
      { id: "other-output-workspace", name: "Other", path: "C:/work/other-output-fixture" },
      "ready",
    ),
  );
  await act(async () => stale({ type: "terminal", ...ref("old"), terminal: { kind: "failed" } }));
  expect(host.textContent).toContain("Run a build task");
  expect(port.unsubscribed).toContain("old");
  await act(async () =>
    workspaceRuntimeRegistry.activateWorkspace(
      { id: "output-pane-tests", name: "Fixture", path: WORKSPACE },
      "ready",
    ),
  );
  await act(async () => begin(SESSION_A, identity("fresh")));
  await act(async () => cancellation.reject(new Error("old cancellation failed")));
  expect(host.textContent).not.toContain("old cancellation failed");
  expect(useBuildOutputStore.getState().sessions[SESSION_A]!.identity.operationId).toBe("fresh");
});

test("two window scopes with the same root and operation ID use their owning port and store", async () => {
  const portA = new FakeBuildOutputPort();
  const portB = new FakeBuildOutputPort();
  const { host: hostA } = await mount({ port: portA, workspaceId: "window-a", scoped: true });
  await act(async () =>
    useBuildOutputStore
      .getStore("window-a")
      .getState()
      .actions.beginOperation(SESSION_A, identity("same")),
  );
  const { host: hostB } = await mount({ port: portB, workspaceId: "window-b", scoped: true });
  await act(async () =>
    useBuildOutputStore
      .getStore("window-b")
      .getState()
      .actions.beginOperation(SESSION_A, identity("same")),
  );
  await act(async () => {
    portA.emit({ type: "chunk", ...ref("same"), stream: "stdout", text: "window A\n" });
    portB.emit({ type: "chunk", ...ref("same"), stream: "stderr", text: "window B\n" });
  });
  expect(hostA.textContent).toContain("window A");
  expect(hostA.textContent).not.toContain("window B");
  expect(hostB.textContent).toContain("window B");
  await act(async () => stopButton(hostA)!.click());
  expect(portA.cancelRequests).toHaveLength(1);
  expect(portB.cancelRequests).toHaveLength(0);
  expect(useBuildOutputStore.getStore("window-a").getState().sessions[SESSION_A]!.cancelling).toBe(
    true,
  );
  expect(useBuildOutputStore.getStore("window-b").getState().sessions[SESSION_A]!.cancelling).toBe(
    false,
  );
});

test("a decoded source link uses the existing workspace file action with one-based coordinates", async () => {
  const port = new FakeBuildOutputPort();
  const { host } = await mount({ port });
  const files = useFileSystemStore.getStore("output-pane-tests");
  const original = files.getState().handleFileSelect;
  const opened: unknown[][] = [];
  files.setState({
    handleFileSelect: async (...args) => {
      opened.push(args);
      return undefined;
    },
  });
  cleanups.push(() => files.setState({ handleFileSelect: original }));
  await act(async () => begin(SESSION_A, identity("reveal")));
  await act(async () =>
    port.emit({
      type: "diagnostics",
      ...ref("reveal"),
      diagnostics: [{ ...diagnostic("src/main.rs", 4), column: 9 }],
    }),
  );
  await act(async () =>
    host.querySelector<HTMLButtonElement>('[data-slot="build-output-problems"] button')!.click(),
  );
  expect(opened).toEqual([
    [
      expect.stringMatching(/C:[\\/]work[\\/]output-pane-fixture[\\/]src[\\/]main\.rs/),
      false,
      4,
      9,
    ],
  ]);
});

test("removing an inactive scoped workspace immediately releases its subscription without cancelling", async () => {
  const port = new FakeBuildOutputPort();
  await mount({ port, workspaceId: "removed-window", scoped: true });
  const store = useBuildOutputStore.getStore("removed-window");
  await act(async () => store.getState().actions.beginOperation(SESSION_A, identity("removed")));
  await act(async () =>
    workspaceRuntimeRegistry.activateWorkspace(
      { id: "remaining-window", name: "Other", path: WORKSPACE },
      "ready",
    ),
  );
  await act(async () => workspaceRuntimeRegistry.removeWorkspace("removed-window"));
  expect(port.unsubscribed).toEqual(["removed"]);
  await act(async () =>
    port.retainedSinks[0]!({ type: "terminal", ...ref("removed"), terminal: { kind: "failed" } }),
  );
  expect(store.getState().sessions[SESSION_A]!.status).toBe("running");
  expect(port.cancelRequests).toEqual([]);
});
