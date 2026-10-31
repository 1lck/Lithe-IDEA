import { afterAll, afterEach, expect, spyOn, test } from "bun:test";
import { act, useState } from "react";
import type { Root } from "react-dom/client";
import { LocaleProvider } from "@/i18n/locale-provider";
import type { DisplayLanguage } from "@/i18n/locale";
import { installHappyDom } from "@/test-utils/happy-dom";
import * as native from "@/platform/tauri-core";
import type {
  DeclarativeMarketplaceSource,
  DeclarativeMarketplaceSourcesState,
} from "./declarative-marketplace-sources";

const restoreDom = installHappyDom();
afterAll(restoreDom);
// Load browser-dependent modules after installing DOM globals, exactly like
// the settings-path-input test: react-dom and the component observe
// happy-dom, while react and LocaleProvider stay static.
const { createRoot } = await import("react-dom/client");
const { StrictMode } = await import("react");
const { DeclarativeMarketplaceSources } = await import("./declarative-marketplace-sources-section");

const officialSource: DeclarativeMarketplaceSource = {
  id: "lithe-official",
  name: "Lithe",
  input:
    "https://raw.githubusercontent.com/Lithe-IDEA/Lithe-IDEA/HEAD/Plugins/marketplace/index.json",
  indexURL:
    "https://raw.githubusercontent.com/Lithe-IDEA/Lithe-IDEA/HEAD/Plugins/marketplace/index.json",
  repository: "https://github.com/Lithe-IDEA/Lithe-IDEA",
  isEnabled: true,
  kind: "official",
  isOfficial: true,
  deletable: false,
};

const communitySource: DeclarativeMarketplaceSource = {
  id: "source-39170ddcae1870bf",
  name: "Lithe Store",
  input: "https://github.com/Lithe-IDEA/Lithe-store",
  indexURL: "https://raw.githubusercontent.com/Lithe-IDEA/Lithe-store/HEAD/lithe-plugin-index.json",
  repository: "https://github.com/Lithe-IDEA/Lithe-store",
  isEnabled: true,
  kind: "thirdParty",
  isOfficial: false,
  deletable: true,
};

function setInputValue(input: HTMLInputElement, value: string) {
  // React 19 only sees the change through a real InputEvent; a plain Event
  // updates the DOM value without reaching the controlled state.
  const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!;
  setter.call(input, value);
  input.dispatchEvent(new window.InputEvent("input", { bubbles: true, inputType: "insertText" }));
}

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (reason: unknown) => void;
  const promise = new Promise<T>((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
}

const state = (
  sources: DeclarativeMarketplaceSource[],
  problem: string | null = null,
): DeclarativeMarketplaceSourcesState => ({
  sources,
  problem,
});

const consoleErrorSpy = spyOn(console, "error").mockImplementation(() => {});
afterEach(() => consoleErrorSpy.mockClear());
afterAll(() => consoleErrorSpy.mockRestore());

async function mountWith(
  invokeImpl: (command: string) => Promise<unknown>,
  render: (mountedRoot: Root) => Promise<void>,
): Promise<{
  host: HTMLDivElement;
  unmount: () => Promise<void>;
  invokeSpy: ReturnType<typeof spyOn>;
}> {
  const environment = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
  const previousAct = environment.IS_REACT_ACT_ENVIRONMENT;
  const invokeSpy = spyOn(native, "invoke").mockImplementation(invokeImpl);
  const host = document.createElement("div");
  let root: Root | undefined;
  environment.IS_REACT_ACT_ENVIRONMENT = true;
  document.body.append(host);
  root = createRoot(host);
  const mountedRoot = root;
  await act(async () => render(mountedRoot));
  const unmount = async () => {
    try {
      await act(async () => root?.unmount());
    } finally {
      host.remove();
      invokeSpy.mockRestore();
      if (previousAct === undefined) delete environment.IS_REACT_ACT_ENVIRONMENT;
      else environment.IS_REACT_ACT_ENVIRONMENT = previousAct;
    }
  };
  return { host, unmount, invokeSpy };
}

test("source management renders host state and drives the host commands", async () => {
  const sources = [officialSource, communitySource];
  const { host, unmount, invokeSpy } = await mountWith(
    async (command) => {
      if (command === "declarative_marketplace_sources_state") return state(sources);
      if (command === "declarative_marketplace_sources_add") {
        sources.push({ ...communitySource, id: "source-added1", name: "example/lithe-plugins" });
        return sources;
      }
      if (command === "declarative_marketplace_sources_set_enabled") return sources;
      if (command === "declarative_marketplace_sources_remove") return sources;
      throw new Error(`unexpected command ${command}`);
    },
    (mountedRoot) =>
      Promise.resolve(
        mountedRoot.render(
          <LocaleProvider language="en-US">
            <DeclarativeMarketplaceSources />
          </LocaleProvider>,
        ),
      ),
  );
  try {
    // Both presets render; only the deletable one offers removal.
    const rows = host.querySelectorAll<HTMLLIElement>(
      '[data-testid="declarative-marketplace-source-list"] > li',
    );
    expect(rows.length).toBe(2);
    expect(
      host.querySelector('[data-testid="declarative-marketplace-source-lithe-official"]'),
    ).not.toBeNull();
    expect(
      host.querySelector('[data-testid="declarative-marketplace-source-source-39170ddcae1870bf"]'),
    ).not.toBeNull();
    const removeButtons = [...rows]
      .flatMap((row) => [...row.querySelectorAll("button")])
      .filter((button) => button.textContent === "Remove");
    expect(removeButtons.length).toBe(1);

    // Adding a source forwards the typed URL and refreshes the list.
    const input = host.querySelector<HTMLInputElement>('input[type="text"]')!;
    await act(async () => setInputValue(input, "https://github.com/example/lithe-plugins"));
    const addButtons = [...host.querySelectorAll("button")].filter(
      (button) => button.textContent === "Add source",
    );
    expect(addButtons.length).toBe(1);
    await act(async () => addButtons[0].click());
    const addCalls = invokeSpy.mock.calls.filter(
      ([command]) => command === "declarative_marketplace_sources_add",
    );
    expect(addCalls.length).toBe(1);
    expect(addCalls[0][1]).toEqual({ url: "https://github.com/example/lithe-plugins" });
    expect(
      host.querySelector('[data-testid="declarative-marketplace-source-source-added1"]'),
    ).not.toBeNull();

    // Removing Lithe Store targets exactly its stable ID.
    invokeSpy.mockClear();
    await act(async () => removeButtons[0].click());
    const removeCalls = invokeSpy.mock.calls.filter(
      ([command]) => command === "declarative_marketplace_sources_remove",
    );
    expect(removeCalls.length).toBe(1);
    expect(removeCalls[0][1]).toEqual({ sourceId: "source-39170ddcae1870bf" });
    expect(consoleErrorSpy).not.toHaveBeenCalled();
  } finally {
    await unmount();
  }
});

// Operations must stay unreachable until the first load resolves: with the
// initial request still pending, the add button is disabled and only the
// state command has been issued.
test("operations stay disabled while the first load is pending", async () => {
  const pending = deferred<DeclarativeMarketplaceSourcesState>();
  const { host, unmount, invokeSpy } = await mountWith(
    async (command) => {
      if (command === "declarative_marketplace_sources_state") return pending.promise;
      throw new Error(`unexpected command ${command}`);
    },
    (mountedRoot) =>
      Promise.resolve(
        mountedRoot.render(
          <LocaleProvider language="en-US">
            <DeclarativeMarketplaceSources />
          </LocaleProvider>,
        ),
      ),
  );
  try {
    const addButton = [...host.querySelectorAll("button")].find(
      (button) => button.textContent === "Add source",
    );
    expect(addButton).toBeDefined();
    const input = host.querySelector<HTMLInputElement>('input[type="text"]')!;
    // The input itself is the ready gate while nothing has loaded.
    expect(input.disabled).toBe(true);
    expect(
      invokeSpy.mock.calls.every(
        ([command]) => command === "declarative_marketplace_sources_state",
      ),
    ).toBe(true);
    await act(async () => pending.resolve(state([officialSource, communitySource])));
    expect(input.disabled).toBe(false);
    await act(async () => setInputValue(input, "https://github.com/example/lithe-plugins"));
    expect(addButton!.disabled).toBe(false);
  } finally {
    await unmount();
  }
});

// StrictMode double-invokes the mount effect, so two list requests race.
// Whichever resolves first must lose: the later generation wins even when
// the older response arrives last.
test("a late older response cannot overwrite a newer generation", async () => {
  const first = deferred<DeclarativeMarketplaceSourcesState>();
  const second = deferred<DeclarativeMarketplaceSourcesState>();
  const responses = [first.promise, second.promise];
  let call = 0;
  const { host, unmount } = await mountWith(
    async (command) => {
      if (command !== "declarative_marketplace_sources_state")
        throw new Error(`unexpected ${command}`);
      const index = call++;
      return responses[Math.min(index, responses.length - 1)];
    },
    async (mountedRoot) => {
      await act(async () =>
        mountedRoot.render(
          <StrictMode>
            <LocaleProvider language="en-US">
              <DeclarativeMarketplaceSources />
            </LocaleProvider>
          </StrictMode>,
        ),
      );
    },
  );
  try {
    expect(call).toBe(2, "StrictMode double-invokes the mount effect");
    // The newer generation resolves first with the fresher data...
    await act(async () => second.resolve(state([officialSource, communitySource])));
    expect(
      host.querySelector('[data-testid="declarative-marketplace-source-source-39170ddcae1870bf"]'),
    ).not.toBeNull();
    // ...then the stale first response arrives with an extra source and must
    // be discarded instead of overwriting the newer result.
    await act(async () =>
      first.resolve(
        state([
          { ...officialSource },
          { ...communitySource },
          { ...communitySource, id: "source-stale1", name: "Stale source" },
        ]),
      ),
    );
    expect(
      host.querySelector('[data-testid="declarative-marketplace-source-source-stale1"]'),
    ).toBeNull();
    expect(consoleErrorSpy).not.toHaveBeenCalled();
  } finally {
    await unmount();
  }
});

// A response that arrives after unmount must not touch the component.
test("a response resolving after unmount is dropped quietly", async () => {
  const pending = deferred<DeclarativeMarketplaceSourcesState>();
  const { unmount } = await mountWith(
    async (command) => {
      if (command !== "declarative_marketplace_sources_state")
        throw new Error(`unexpected ${command}`);
      return pending.promise;
    },
    (mountedRoot) =>
      Promise.resolve(
        mountedRoot.render(
          <LocaleProvider language="en-US">
            <DeclarativeMarketplaceSources />
          </LocaleProvider>,
        ),
      ),
  );
  await unmount();
  await act(async () =>
    pending.resolve(
      state([officialSource, communitySource], "plugin.marketplace.sources.corrupt: diagnosed"),
    ),
  );
  expect(consoleErrorSpy).not.toHaveBeenCalled();
});

// Host rejections carry stable plugin.* codes; the UI must show the
// localized message instead of the code, and clear the busy state so the
// user can retry.
test("operation failures map to localized messages", async () => {
  const { host, unmount, invokeSpy } = await mountWith(
    async (command) => {
      if (command === "declarative_marketplace_sources_state")
        return state([officialSource, communitySource]);
      if (command === "declarative_marketplace_sources_remove") {
        throw new Error("plugin.marketplace.sourceAlreadyAdded: Lithe Store");
      }
      throw new Error(`unexpected command ${command}`);
    },
    (mountedRoot) =>
      Promise.resolve(
        mountedRoot.render(
          <LocaleProvider language="en-US">
            <DeclarativeMarketplaceSources />
          </LocaleProvider>,
        ),
      ),
  );
  try {
    const removeButton = [...host.querySelectorAll("button")].find(
      (button) => button.textContent === "Remove",
    );
    expect(removeButton).toBeDefined();
    await act(async () => removeButton!.click());
    const alert = host.querySelector<HTMLParagraphElement>('[role="alert"]');
    expect(alert?.textContent).toBe("That source has already been added.");
    expect(alert?.textContent).not.toContain("plugin.marketplace");
    expect(removeButton!.disabled).toBe(false);
    expect(
      invokeSpy.mock.calls.filter(
        ([command]) => command === "declarative_marketplace_sources_remove",
      ).length,
    ).toBe(1);
  } finally {
    await unmount();
  }
});

// A failed first read owns a retry link. Once that retry succeeds, the old
// load diagnosis must leave the UI instead of surviving beside valid data.
test("a successful retry clears the previous load error", async () => {
  let readCalls = 0;
  const { host, unmount } = await mountWith(
    async (command) => {
      if (command !== "declarative_marketplace_sources_state") {
        throw new Error(`unexpected command ${command}`);
      }
      readCalls += 1;
      if (readCalls === 1) throw new Error("temporary read failure");
      return state([officialSource, communitySource]);
    },
    (mountedRoot) =>
      Promise.resolve(
        mountedRoot.render(
          <LocaleProvider language="en-US">
            <DeclarativeMarketplaceSources />
          </LocaleProvider>,
        ),
      ),
  );
  try {
    const retry = [...host.querySelectorAll("button")].find(
      (button) => button.textContent === "Retry",
    );
    expect(retry).toBeDefined();
    expect(host.querySelector('[role="alert"]')?.textContent).toContain(
      "The source list could not be loaded.",
    );

    await act(async () => retry!.click());

    expect(readCalls).toBe(2);
    expect(host.querySelector('[role="alert"]')).toBeNull();
    expect(
      host.querySelector('[data-testid="declarative-marketplace-source-source-39170ddcae1870bf"]'),
    ).not.toBeNull();
  } finally {
    await unmount();
  }
});

// Reads are also used to re-localize state after a language switch. They may
// refresh the list, but they cannot dismiss an actionable mutation failure.
test.each(["before mutation", "after mutation"] as const)(
  "a language-switch read started %s preserves the mutation error",
  async (readOrder) => {
    let switchLanguage: (language: DisplayLanguage) => void = () => {};
    function Harness() {
      const [language, setLanguage] = useState<DisplayLanguage>("en-US");
      switchLanguage = setLanguage;
      return (
        <LocaleProvider language={language}>
          <DeclarativeMarketplaceSources />
        </LocaleProvider>
      );
    }
    let readCalls = 0;
    const languageRead = deferred<DeclarativeMarketplaceSourcesState>();
    const { host, unmount } = await mountWith(
      async (command) => {
        if (command === "declarative_marketplace_sources_state") {
          readCalls += 1;
          return readCalls === 1 ? state([officialSource, communitySource]) : languageRead.promise;
        }
        if (command === "declarative_marketplace_sources_remove") {
          throw new Error("plugin.marketplace.sourceNotFound: stale source");
        }
        throw new Error(`unexpected command ${command}`);
      },
      (mountedRoot) => Promise.resolve(mountedRoot.render(<Harness />)),
    );
    try {
      if (readOrder === "before mutation") {
        await act(async () => switchLanguage("zh-CN"));
      }
      const removeButton = [...host.querySelectorAll("button")].find(
        (button) => button.textContent === "Remove" || button.textContent === "删除",
      );
      expect(removeButton).toBeDefined();
      await act(async () => removeButton!.click());
      const mutationError = host.querySelector('[role="alert"]')?.textContent;
      expect(mutationError).toBeTruthy();
      if (readOrder === "after mutation") {
        expect(mutationError).toBe("That source no longer exists.");
        await act(async () => switchLanguage("zh-CN"));
      }
      await act(async () => languageRead.resolve(state([officialSource, communitySource])));

      expect(readCalls).toBe(2);
      expect(host.querySelector('[role="alert"]')?.textContent).toBe(mutationError);
    } finally {
      await act(async () => languageRead.resolve(state([officialSource, communitySource])));
      await unmount();
    }
  },
);

// The in-flight gate is shared by the keyboard and pointer paths: while one
// mutation is pending, a second Enter and the Add button alike must not
// reach the host again.
test("an in-flight add is serialized and preserves a newer input draft", async () => {
  const pending = deferred<DeclarativeMarketplaceSource[]>();
  let addCalls = 0;
  const { host, unmount } = await mountWith(
    async (command) => {
      if (command === "declarative_marketplace_sources_state")
        return state([officialSource, communitySource]);
      if (command === "declarative_marketplace_sources_add") {
        addCalls += 1;
        if (addCalls === 1) return pending.promise;
        throw new Error("second add must never happen");
      }
      throw new Error(`unexpected command ${command}`);
    },
    (mountedRoot) =>
      Promise.resolve(
        mountedRoot.render(
          <LocaleProvider language="en-US">
            <DeclarativeMarketplaceSources />
          </LocaleProvider>,
        ),
      ),
  );
  try {
    const input = host.querySelector<HTMLInputElement>('input[type="text"]')!;
    await act(async () => setInputValue(input, "https://github.com/example/lithe-plugins"));
    await act(async () =>
      input.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Enter", bubbles: true })),
    );
    expect(addCalls).toBe(1);
    // The mutation is in flight: repeated Enter and the Add button are both
    // synchronous no-ops (the in-flight gate, not just the disabled state).
    await act(async () => {
      input.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Enter", bubbles: true }));
      [...host.querySelectorAll("button")]
        .find((button) => button.textContent === "Add source")!
        .click();
    });
    expect(addCalls).toBe(1);
      await act(async () => setInputValue(input, "https://github.com/example/next-plugins"));
    await act(async () =>
      pending.resolve([
        { ...officialSource },
        { ...communitySource },
        { ...communitySource, id: "source-added1", name: "example/lithe-plugins" },
      ]),
    );
    expect(
      host.querySelector('[data-testid="declarative-marketplace-source-source-added1"]'),
    ).not.toBeNull();
    expect(addCalls).toBe(1);
      expect(input.value).toBe("https://github.com/example/next-plugins");
  } finally {
    await unmount();
  }
});

// A language switch re-reads the list. Read and mutation lifetimes are
// separate: whichever resolves first, the mutation's authoritative list
// wins, the busy flag clears, and the user can operate again.
test("a language-switch read during a mutation cannot clobber it", async () => {
  let switchLanguage: (language: DisplayLanguage) => void = () => {};
  function Harness() {
    const [language, setLanguage] = useState<DisplayLanguage>("en-US");
    switchLanguage = setLanguage;
    return (
      <LocaleProvider language={language}>
        <DeclarativeMarketplaceSources />
      </LocaleProvider>
    );
  }
  const mutation = deferred<DeclarativeMarketplaceSource[]>();
  const languageRead = deferred<DeclarativeMarketplaceSourcesState>();
  let readCalls = 0;
  let removeCalls = 0;
  const { host, unmount, invokeSpy } = await mountWith(
    async (command) => {
      if (command === "declarative_marketplace_sources_state") {
        readCalls += 1;
        if (readCalls === 1) return state([officialSource, communitySource]);
        return languageRead.promise;
      }
      if (command === "declarative_marketplace_sources_add") return mutation.promise;
      if (command === "declarative_marketplace_sources_remove") {
        removeCalls += 1;
        return [{ ...officialSource }];
      }
      throw new Error(`unexpected command ${command}`);
    },
    (mountedRoot) =>
      Promise.resolve(
        mountedRoot.render(
          <LocaleProvider language="en-US">
            <Harness />
          </LocaleProvider>,
        ),
      ),
  );
  try {
    const input = host.querySelector<HTMLInputElement>('input[type="text"]')!;
    await act(async () => setInputValue(input, "https://github.com/Lithe-IDEA/Lithe-store"));
    await act(async () =>
      input.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Enter", bubbles: true })),
    );
    // The mutation is in flight; switching language starts a fresh read.
    await act(async () => switchLanguage("zh-CN"));
    expect(readCalls).toBe(2);
    // The read resolves first with the pre-mutation list: it must be
    // discarded instead of hiding the pending mutation's result.
    await act(async () => languageRead.resolve(state([officialSource, communitySource])));
    expect(
      host.querySelector('[data-testid="declarative-marketplace-source-source-added1"]'),
    ).toBeNull();
    // The mutation resolves afterwards and owns the list.
    await act(async () =>
      mutation.resolve([
        { ...officialSource },
        { ...communitySource },
        { ...communitySource, id: "source-added1", name: "Lithe Store" },
      ]),
    );
    expect(
      host.querySelector('[data-testid="declarative-marketplace-source-source-added1"]'),
    ).not.toBeNull();
    // The busy flag cleared with the mutation, so the user can operate
    // again immediately; the UI is now in Chinese after the switch, and the
    // Remove button reflects the busy state.
    const removeButton = [...host.querySelectorAll("button")].find(
      (button) => button.textContent === "删除",
    )!;
    expect(removeButton.disabled).toBe(false);
    await act(async () => removeButton.click());
    expect(removeCalls).toBe(1);
  } finally {
    await unmount();
  }
});

// Reverse resolve order: the mutation completes first and the language read
// afterwards must not roll the list back.
test("a language-switch read after the mutation cannot roll it back", async () => {
  let switchLanguage: (language: DisplayLanguage) => void = () => {};
  function Harness() {
    const [language, setLanguage] = useState<DisplayLanguage>("en-US");
    switchLanguage = setLanguage;
    return (
      <LocaleProvider language={language}>
        <DeclarativeMarketplaceSources />
      </LocaleProvider>
    );
  }
  const mutation = deferred<DeclarativeMarketplaceSource[]>();
  const languageRead = deferred<DeclarativeMarketplaceSourcesState>();
  let readCalls = 0;
  const { host, unmount } = await mountWith(
    async (command) => {
      if (command === "declarative_marketplace_sources_state") {
        readCalls += 1;
        if (readCalls === 1) return state([officialSource, communitySource]);
        return languageRead.promise;
      }
      if (command === "declarative_marketplace_sources_add") return mutation.promise;
      throw new Error(`unexpected command ${command}`);
    },
    (mountedRoot) =>
      Promise.resolve(
        mountedRoot.render(
          <LocaleProvider language="en-US">
            <Harness />
          </LocaleProvider>,
        ),
      ),
  );
  try {
    const input = host.querySelector<HTMLInputElement>('input[type="text"]')!;
    await act(async () => setInputValue(input, "https://github.com/Lithe-IDEA/Lithe-store"));
    await act(async () =>
      input.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Enter", bubbles: true })),
    );
    await act(async () => switchLanguage("zh-CN"));
    expect(readCalls).toBe(2);
    // The mutation resolves first...
    await act(async () =>
      mutation.resolve([
        { ...officialSource },
        { ...communitySource },
        { ...communitySource, id: "source-added1", name: "Lithe Store" },
      ]),
    );
    expect(
      host.querySelector('[data-testid="declarative-marketplace-source-source-added1"]'),
    ).not.toBeNull();
    // ...then the stale read lands and must not roll the list back.
    await act(async () => languageRead.resolve(state([officialSource, communitySource])));
    expect(
      host.querySelector('[data-testid="declarative-marketplace-source-source-added1"]'),
    ).not.toBeNull();
  } finally {
    await unmount();
  }
});
