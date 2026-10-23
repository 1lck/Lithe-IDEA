import { afterEach, describe, expect, mock, test } from "bun:test";
import type { OwnedRunProcess } from "@/features/run/api/run-host-api";
import type { RunServicesOnExit } from "@/features/settings/types/settings.types";

const executeCore = mock(async (_request: unknown): Promise<unknown> => {
  throw new Error("Core is not configured for this test");
});
mock.module("@/core/lithe-core-client", () => ({ executeCore }));

const {
  answerRunServicesPrompt,
  confirmRunServicesWithCore,
  stopRunServicesBeforeLeaving,
  useRunServicesPromptStore,
} = await import("./run-services-exit");

function owned(title: string | null, background = false): OwnedRunProcess {
  return { sessionId: title ?? "untitled", executionId: null, title, background, preparing: false };
}

/** Resolves once the guard shows a question, so a test can answer it. */
function nextPrompt() {
  return new Promise<NonNullable<ReturnType<typeof useRunServicesPromptStore.getState>["prompt"]>>(
    (resolve) => {
      const unsubscribe = useRunServicesPromptStore.subscribe((state) => {
        if (state.prompt && state.answer) {
          unsubscribe();
          resolve(state.prompt);
        }
      });
    },
  );
}

function dependencies(
  services: OwnedRunProcess[],
  options: {
    policy?: RunServicesOnExit;
    stop?: () => Promise<void>;
    confirm?: (services: OwnedRunProcess[]) => OwnedRunProcess[];
  } = {},
) {
  const stop = mock(options.stop ?? (async () => {}));
  const servicesToConfirm = mock(
    async (visible: OwnedRunProcess[], _context: string, policy: RunServicesOnExit) =>
      options.confirm?.(visible) ?? (policy === "ask" ? visible : []),
  );
  return {
    stop,
    servicesToConfirm,
    value: {
      list: async () => services,
      stop,
      servicesToConfirm,
      policy: () => options.policy ?? "ask",
    },
  };
}

afterEach(() => {
  executeCore.mockClear();
  useRunServicesPromptStore.setState({ prompt: null, owner: null, answer: null });
});

describe("stopping Run services before a window closes", () => {
  test("closes at once when the window owns no Run session", async () => {
    const { stop, value } = dependencies([]);

    expect(await stopRunServicesBeforeLeaving("window", "closeWindow", value)).toBe(true);
    expect(stop).not.toHaveBeenCalled();
  });

  test("lists every service, stops them after the user agrees and then closes", async () => {
    const { stop, servicesToConfirm, value } = dependencies([
      owned("Api"),
      owned("clean install"),
      owned(null),
    ]);
    const prompt = nextPrompt();
    const leaving = stopRunServicesBeforeLeaving("window", "closeWindow", value);

    expect(await prompt).toEqual({
      purpose: "closeWindow",
      titles: ["Api", "clean install", ""],
      stopping: false,
      error: null,
    });
    expect(servicesToConfirm.mock.calls[0]?.[1]).toBe("closeWorkspace");
    answerRunServicesPrompt("stop");

    expect(await leaving).toBe(true);
    expect(stop).toHaveBeenCalledWith("window");
    expect(useRunServicesPromptStore.getState().prompt).toBeNull();
  });

  test("keeps the window and every service when the user cancels", async () => {
    const { stop, value } = dependencies([owned("Api")]);
    const prompt = nextPrompt();
    const leaving = stopRunServicesBeforeLeaving("window", "quit", value);

    await prompt;
    answerRunServicesPrompt("cancel");

    expect(await leaving).toBe(false);
    expect(stop).not.toHaveBeenCalled();
    expect(useRunServicesPromptStore.getState().prompt).toBeNull();
  });

  test("stops without asking when the setting says so, background work included", async () => {
    const { stop, value } = dependencies([owned("Api"), owned("Dependencies", true)], {
      policy: "terminate",
    });

    expect(await stopRunServicesBeforeLeaving("window", "closeWindow", value)).toBe(true);
    expect(stop).toHaveBeenCalledTimes(1);
  });

  test("never asks about Lithe's own background work", async () => {
    const { servicesToConfirm, stop, value } = dependencies([owned("Dependencies", true)]);

    expect(await stopRunServicesBeforeLeaving("window", "closeWindow", value)).toBe(true);
    expect(servicesToConfirm.mock.calls[0]?.[0]).toEqual([]);
    expect(stop).toHaveBeenCalledTimes(1);
  });

  test("reports a service that did not stop and keeps the window until it does", async () => {
    let attempts = 0;
    const { stop, value } = dependencies([owned("Api")], {
      stop: async () => {
        attempts += 1;
        if (attempts === 1) throw new Error("Api (process 42): still running");
      },
    });
    const firstPrompt = nextPrompt();
    const leaving = stopRunServicesBeforeLeaving("window", "closeWindow", value);
    await firstPrompt;
    const failure = nextPrompt();
    answerRunServicesPrompt("stop");

    expect(await failure).toMatchObject({
      titles: ["Api"],
      stopping: false,
      error: "Api (process 42): still running",
    });
    answerRunServicesPrompt("stop");

    expect(await leaving).toBe(true);
    expect(stop).toHaveBeenCalledTimes(2);
  });

  test("a failed silent stop asks how to continue instead of closing", async () => {
    const { value } = dependencies([owned("Api")], {
      policy: "terminate",
      stop: async () => {
        throw new Error("Api (process 42): still running");
      },
    });
    const failure = nextPrompt();
    const leaving = stopRunServicesBeforeLeaving("application", "update", value);

    expect(await failure).toMatchObject({ purpose: "update", titles: ["Api"] });
    answerRunServicesPrompt("cancel");
    expect(await leaving).toBe(false);
  });

  test("still closes when the native list is unavailable", async () => {
    const { stop, value } = dependencies([]);
    value.list = async () => {
      throw new Error("Run process state is unavailable");
    };

    expect(await stopRunServicesBeforeLeaving("window", "closeWindow", value)).toBe(true);
    expect(stop).not.toHaveBeenCalled();
  });
});

describe("the shared Core rule", () => {
  test("asks for exactly the records Core marks confirmStop", async () => {
    executeCore.mockImplementationOnce(async (request) => {
      const { payload } = request as {
        payload: { context: string; settings: unknown; records: Array<{ id: string }> };
      };
      expect(payload.context).toBe("quit");
      expect(payload.settings).toEqual({ runServicesOnExit: "ask" });
      return {
        id: null,
        ok: true,
        data: {
          decisions: payload.records.map((record) => ({
            id: record.id,
            action: record.id === "1" ? "confirmStop" : "terminate",
          })),
        },
      };
    });
    const { value } = dependencies([owned("Api"), owned("Worker")]);
    const prompt = nextPrompt();
    const leaving = stopRunServicesBeforeLeaving("window", "quit", {
      ...value,
      servicesToConfirm: confirmRunServicesWithCore,
    });

    expect((await prompt).titles).toEqual(["Worker"]);
    answerRunServicesPrompt("stop");
    expect(await leaving).toBe(true);
  });

  test("asks about every service when Core cannot be reached", async () => {
    const services = [owned("Api"), owned("Worker")];

    expect(await confirmRunServicesWithCore(services, "closeWorkspace", "terminate")).toEqual(
      services,
    );
  });
});
