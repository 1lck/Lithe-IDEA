import { afterEach, describe, expect, test } from "bun:test";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";

const { activeRunServices, useRunStore } = await import("./run.store");
const { PRIMARY_SESSION_ID } = await import("../types/run.types");

function session(id: string, values: { isRunning?: boolean; isPreparing?: boolean }) {
  return {
    id,
    executionId: `${id}-execution`,
    configurationId: id,
    title: `Service ${id}`,
    output: "",
    isRunning: values.isRunning ?? false,
    isPreparing: values.isPreparing,
    exitCode: null,
  };
}

/** Replaces the native stop so a test can see which execution the close would end. */
function recordStops(workspaceId: string, stops: Array<[string, string | undefined]>) {
  const store = useRunStore.getStore(workspaceId);
  store.setState({
    actions: {
      ...store.getState().actions,
      stop: async (sessionId?: string, executionId?: string) => {
        stops.push([sessionId ?? "", executionId]);
      },
    },
  });
  return store;
}

describe("active Run services for window close (#1137)", () => {
  afterEach(() => workspaceRuntimeRegistry.resetForTests());

  test("an idle window has nothing to stop", () => {
    useRunStore.getStore("idle-project");
    expect(activeRunServices()).toEqual([]);
  });

  test("lists running and launching services of every project in the window", async () => {
    // Native Run ownership is per window, so a background project's service
    // dies with the window too and must be listed, not only the active one.
    const stops: Array<[string, string | undefined]> = [];
    recordStops("project-a", stops).setState({
      primaryRunning: true,
      primaryTitle: "Application",
      primaryExecutionId: "primary-execution",
      sessions: [session("api", { isRunning: true }), session("done", {})],
    });
    recordStops("project-b", stops).setState({
      sessions: [session("worker", { isPreparing: true })],
    });

    const services = activeRunServices();
    expect(services.map((service) => service.title)).toEqual([
      "Application",
      "Service api",
      "Service worker",
    ]);

    await Promise.all(services.map((service) => service.stop()));
    expect(stops).toEqual([
      [PRIMARY_SESSION_ID, "primary-execution"],
      ["api", "api-execution"],
      ["worker", "worker-execution"],
    ]);
  });
});
