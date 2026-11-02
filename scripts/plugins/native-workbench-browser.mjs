import path from "node:path";

export const WORKBENCH_STAGES = 8;

// The boundary catalog is registered in the client before MainLayout is loaded,
// so Vite cannot scan that graph at server startup. Prebundle its third-party
// controls explicitly and disable discovery to prevent mid-workflow reloads.
export const WORKBENCH_OPTIMIZE_DEPS = {
  noDiscovery: true,
  include: [
    "@tauri-apps/api/mocks",
    "react",
    "react/jsx-runtime",
    "react/jsx-dev-runtime",
    "react-dom/client",
    "zustand",
    "zustand/vanilla",
    "zustand/traditional",
    "zustand/middleware",
    "zustand/middleware/immer",
    "immer",
    "@base-ui/react",
    "@base-ui/react/context-menu",
    "@base-ui/react/use-render",
    "@base-ui/react/checkbox",
    "@base-ui/react/combobox",
    "@base-ui/react/number-field",
    "@base-ui/react/popover",
    "@base-ui/react/select",
    "@base-ui/react/separator",
    "@base-ui/react/tabs",
    "@base-ui/react/toggle-group",
    "@base-ui/react/toggle",
    "@tanstack/react-virtual",
    "class-variance-authority",
    "clsx",
    "lucide-react",
    "motion",
    "motion/react",
    "tailwind-merge",
  ],
};

/** Drives only public DOM interactions. Evaluation observes boundary receipts,
 * retains DOM identity, or controls external asynchronous completion gates. */
export async function nativeWorkbenchRegression(page, step) {
  const snapshots = [];
  const observe = () => page.evaluate(() => window.nativeWorkbenchProbe.observe());
  const check = (value, message) => {
    if (!value) throw new Error(message);
  };
  const rail = (name) => page.getByRole("button", { name: `Panel ${name}`, exact: true });
  const input = (name) => page.getByRole("textbox", { name: `Name ${name}`, exact: true });
  const slot = (name) => page.locator(`[data-native-tool-window-slot="${name}"]`);
  const wait = (predicate, arg) => page.waitForFunction(predicate, arg, { timeout: 5000 });
  const ready = (name) =>
    wait((name) => {
      const input = document.querySelector(`input[aria-label="Name ${name}"]`);
      return input && !input.disabled;
    }, name);
  const phase = async (name, action) => {
    const begin = performance.now();
    try {
      const observation = await step(name, action);
      snapshots.push({ name, durationMs: performance.now() - begin, observation });
    } catch (error) {
      let boundary;
      try {
        boundary = await step("observe failed workbench phase", observe, 2000);
      } catch (observationError) {
        boundary = { observationError: String(observationError) };
      }
      throw new Error(`${name}: ${error.stack ?? error}; boundary=${JSON.stringify(boundary)}`);
    }
  };
  const edit = async (name, value) => {
    await input(name).click();
    await input(name).press("ControlOrMeta+A");
    await page.keyboard.type(value);
    check((await input(name).inputValue()) === value, `${name} draft missing`);
  };
  const move = async (name, placement) => {
    await rail(name).click({ button: "right" });
    await page.getByRole("menuitem", { name: placement, exact: true }).click();
    await slot(placement)
      .getByRole("textbox", { name: `Name ${name}`, exact: true })
      .waitFor();
    await ready(name);
  };
  const hold = (kind, id) =>
    page.evaluate(([kind, id]) => window.nativeWorkbenchProbe.hold(kind, id), [kind, id]);
  const release = (kind, id) =>
    page.evaluate(([kind, id]) => window.nativeWorkbenchProbe.release(kind, id), [kind, id]);
  let primaryError;
  let cleanup;
  try {
    await phase("activity rail opens three production slots; input saves full values", async () => {
      await page.getByTestId("terminal-session").waitFor({ state: "attached" });
      await page.evaluate(() => {
        window.nativeWorkbenchTerminal = document.querySelector('[data-testid="terminal-session"]');
      });
      for (const name of ["left", "tree", "right"]) await rail(name).click();
      await ready("left");
      await ready("right");
      await page.getByRole("tree").waitFor();
      for (const name of ["left", "bottom", "right"])
        check((await slot(name).count()) === 1, `missing ${name} slot`);
      await edit("left", "A left draft");
      await page.getByRole("button", { name: "Save left", exact: true }).click();
      await wait(() =>
        window.nativeWorkbenchProbe
          .observe()
          .prepared.some((p) => p.actionId === "save" && p.values?.name === "A left draft"),
      );
      await ready("left");
      const state = await observe();
      check(
        state.terminalMounts === 1 && state.terminalUnmounts === 0,
        "terminal remounted on slot open",
      );
      check(state.prepared.filter((p) => p.actionId === "save").length === 1, "save duplicated");
      return {
        slots: ["left", "bottom", "right"],
        fullValues: { name: "A left draft" },
        terminalMounts: state.terminalMounts,
      };
    });
    await phase("tree keyboard selection and toolbar action use current selected ID", async () => {
      const tree = page.getByRole("tree");
      await tree.click();
      for (const key of ["Home", "ArrowRight", "ArrowDown"]) await tree.press(key);
      await page.getByRole("treeitem", { name: "Child", exact: true }).waitFor();
      check(
        (await page
          .getByRole("treeitem", { name: "Child", exact: true })
          .getAttribute("aria-selected")) === "true",
        "child not selected",
      );
      await page.getByRole("button", { name: "Run tree", exact: true }).click();
      await wait(() =>
        window.nativeWorkbenchProbe
          .observe()
          .prepared.some((p) => p.actionId === "save" && p.selectedId === "child"),
      );
      await wait(() =>
        [...document.querySelectorAll("button")].some(
          (button) => button.getAttribute("aria-label") === "Run tree" && !button.disabled,
        ),
      );
      const actionCount = (await observe()).prepared.filter(
        (p) => p.actionId === "save" && p.selectedId === "child",
      ).length;
      check(actionCount === 1, "tree action duplicated");
      return { selectedId: "child", actionCount };
    });
    await phase(
      "same-slot replacement and context-menu moves preserve the owning draft",
      async () => {
        await edit("right", "A right draft");
        await rail("other").click();
        await ready("other");
        check((await input("right").count()) === 0, "same-slot content remained mounted");
        await rail("right").click();
        await ready("right");
        check((await input("right").inputValue()) === "A right draft", "replacement lost draft");
        for (const placement of ["bottom", "left", "right"]) {
          await move("right", placement);
          check(
            (await input("right").inputValue()) === "A right draft",
            `move to ${placement} lost draft`,
          );
          check(
            (await page.getByTestId("native-plugin-panel").count()) ===
              (placement === "bottom" ? 2 : 1),
            "move duplicated panel or failed to replace destination",
          );
        }
        return { moves: ["bottom", "left", "right"], draft: await input("right").inputValue() };
      },
    );
    await phase(
      "close restores rail focus; hide and reopen retain draft and terminal DOM",
      async () => {
        await page.getByRole("button", { name: "Close native plugin panel", exact: true }).click();
        await slot("right").waitFor({ state: "detached" });
        check(
          await rail("right").evaluate((e) => document.activeElement === e),
          "close did not restore trigger focus",
        );
        await rail("right").click();
        await ready("right");
        await rail("right").click();
        await slot("right").waitFor({ state: "detached" });
        await rail("right").click();
        await ready("right");
        check((await input("right").inputValue()) === "A right draft", "hide lost draft");
        check(
          await page.evaluate(
            () =>
              document.querySelector('[data-testid="terminal-session"]') ===
              window.nativeWorkbenchTerminal,
          ),
          "terminal DOM replaced",
        );
        return { restoredFocus: true, retainedTerminal: true, retainedDraft: true };
      },
    );
    await phase(
      "reverse open and late exact close cannot release the replacement owner",
      async () => {
        await rail("right").click();
        await slot("right").waitFor({ state: "detached" });
        const stale = `binding-${(await observe()).opened.length + 1}`;
        await hold("open", stale);
        await hold("close", stale);
        await rail("right").click();
        await wait(
          (id) => window.nativeWorkbenchProbe.observe().opened.some((b) => b.bindingId === id),
          stale,
        );
        await rail("other").click();
        await ready("other");
        await release("open", stale);
        await rail("right").click();
        await ready("right");
        const current = (await observe()).opened.at(-1).bindingId;
        await release("close", stale);
        await wait((id) => window.nativeWorkbenchProbe.observe().closed.includes(id), stale);
        const state = await observe();
        check(
          state.owners.includes(current) && !state.owners.includes(stale),
          "late close removed new owner",
        );
        check(!state.prepared.some((p) => p.bindingId === stale), "stale open prepared work");
        check(
          (await input("right").inputValue()) === "A right draft",
          "reverse open changed draft",
        );
        await page.getByRole("button", { name: "Save right", exact: true }).click();
        await wait(
          (id) =>
            window.nativeWorkbenchProbe
              .observe()
              .prepared.some((p) => p.bindingId === id && p.actionId === "save"),
          current,
        );
        await ready("right");
        return { stale, current, stalePrepared: false, replacementActionable: true };
      },
    );
    await phase(
      "controlled workspace lifecycle isolates B and restores A placement and values",
      async () => {
        await page.getByRole("tab", { name: "Workspace B", exact: true }).click();
        await input("right").waitFor({ state: "detached" });
        await rail("right").click();
        await ready("right");
        check((await input("right").inputValue()) === "initial", "B inherited A draft");
        await edit("right", "B right draft");
        await page.getByRole("tab", { name: "Workspace A", exact: true }).click();
        await ready("right");
        await wait(
          () => document.querySelector('input[aria-label="Name right"]')?.value === "A right draft",
        );
        check((await slot("right").count()) === 1, "A placement not restored");
        check(
          (await page
            .getByRole("tab", { name: "Workspace A", exact: true })
            .getAttribute("aria-selected")) === "true",
          "production project tab did not select A",
        );
        check(
          await page.evaluate(
            () =>
              document.querySelector('[data-testid="terminal-session"]') ===
              window.nativeWorkbenchTerminal,
          ),
          "workspace tabs replaced terminal mount identity",
        );
        return {
          boundary: "production ProjectTabBar; controlled filesystem switch API",
          A: "A right draft",
          B: "B right draft",
        };
      },
    );
    await phase(
      "package replacement cancels pending action; late prepare cleans only its captured receipt",
      async () => {
        const old = (await observe()).opened.at(-1).bindingId;
        await hold("prepare", old);
        await page.getByRole("button", { name: "Save right", exact: true }).click();
        await wait(
          (id) =>
            window.nativeWorkbenchProbe
              .observe()
              .prepared.some((p) => p.bindingId === id && p.actionId === "save"),
          old,
        );
        const pending = (await observe()).prepared.findLast(
          (p) => p.bindingId === old && p.actionId === "save",
        );
        await page
          .getByRole("button", { name: "External replace right package", exact: true })
          .click();
        await wait(() =>
          window.nativeWorkbenchProbe
            .observe()
            .opened.at(-1)
            .entry.packageIdentity.endsWith("-replacement"),
        );
        await ready("right");
        check(
          (await input("right").inputValue()) === "initial",
          "new package inherited old bytes' draft",
        );
        await edit("right", "new package draft");
        const current = (await observe()).opened.at(-1).bindingId;
        await release("prepare", old);
        await wait(
          (operation) => window.nativeWorkbenchProbe.observe().cancelled.includes(operation),
          pending.operationId,
        );
        await wait((id) => window.nativeWorkbenchProbe.observe().closed.includes(id), old);
        const afterCancellation = await observe();
        check(
          !afterCancellation.confirmed.includes(pending.operationId) &&
            !afterCancellation.reads.includes(pending.operationId),
          "abandoned action executed after late prepare",
        );
        await page.getByRole("button", { name: "Save right", exact: true }).click();
        await wait(
          (id) =>
            window.nativeWorkbenchProbe
              .observe()
              .prepared.some(
                (p) =>
                  p.bindingId === id &&
                  p.actionId === "save" &&
                  p.values?.name === "new package draft",
              ),
          current,
        );
        await ready("right");
        const afterReplacement = await observe();
        const currentAction = afterReplacement.prepared.findLast(
          (p) => p.bindingId === current && p.actionId === "save",
        );
        check(
          afterReplacement.confirmed.includes(currentAction.operationId) &&
            afterReplacement.reads.includes(currentAction.operationId),
          "replacement action did not confirm and read",
        );
        check(afterReplacement.owners.includes(current), "old cancellation removed new owner");
        return {
          old,
          current,
          cancelledOperation: pending.operationId,
          abandonedActionExecuted: false,
          replacementOperation: currentAction.operationId,
          newPackageActionable: true,
        };
      },
    );
    await phase(
      "controlled window reconstruction isolates drafts; final close releases every exact owner",
      async () => {
        await page.getByRole("button", { name: "External host secondary", exact: true }).click();
        await wait(() => window.nativeWorkbenchProbe.observe().opened.at(-1).host === "secondary");
        await ready("right");
        check((await input("right").inputValue()) === "initial", "secondary inherited main draft");
        await edit("right", "secondary draft");
        await page.getByRole("button", { name: "External host main", exact: true }).click();
        await wait(() => window.nativeWorkbenchProbe.observe().opened.at(-1).host === "main");
        await ready("right");
        await wait(() => window.nativeWorkbenchProbe.observe().terminalMounts === 3);
        check(
          (await input("right").inputValue()) === "new package draft",
          "main draft not restored",
        );
        await page.getByRole("button", { name: "Close native plugin panel", exact: true }).click();
        await slot("right").waitFor({ state: "detached" });
        check(
          await rail("right").evaluate((e) => document.activeElement === e),
          "final close lost focus",
        );
        await page.evaluate(() => window.nativeWorkbenchProbe.dispose());
        await wait(() => {
          const s = window.nativeWorkbenchProbe.observe();
          return s.owners.length === 0 && s.closed.length === s.opened.length;
        });
        const state = await observe();
        check(new Set(state.closed).size === state.opened.length, "binding closed twice or missed");
        check(
          state.terminalMounts === 3 && state.terminalUnmounts === 3,
          "unexpected terminal mount lifecycle",
        );
        check(state.errors.length === 0, `external boundary errors: ${state.errors}`);
        return {
          boundary: "one Edge page reconstructs controlled host identity; not two product windows",
          opened: state.opened.length,
          closed: state.closed.length,
          owners: state.owners,
          terminalMounts: state.terminalMounts,
          terminalUnmounts: state.terminalUnmounts,
        };
      },
    );
  } catch (error) {
    primaryError = error;
  } finally {
    try {
      await step(
        "dispose workbench fixture",
        () => page.evaluate(() => window.nativeWorkbenchProbe.dispose()),
        5000,
      );
      await wait(() => {
        const s = window.nativeWorkbenchProbe.observe();
        return s.owners.length === 0 && s.closed.length === s.opened.length;
      });
      cleanup = await step("observe workbench cleanup", observe, 2000);
    } catch (error) {
      const errors = [...(primaryError ? [primaryError] : []), error];
      primaryError = new AggregateError(
        errors,
        `Workbench or fixture cleanup failed: ${errors.map((error) => error.stack ?? error).join("\n")}`,
      );
    }
  }
  if (primaryError)
    throw Object.assign(primaryError, { workbenchEvidence: { snapshots, cleanup } });
  return {
    snapshots,
    cleanup,
    scope: "real Edge MainLayout and public controls; controlled external lifecycle and native I/O",
  };
}

// Workbench-only test doubles, shared with the isolated Bun suite. No product
// alias or capability gate is changed. The browser loads the shared fixture
// through Vite and registers its actual export names before importing MainLayout.
// This avoids executing client-only store dependencies through Vite's SSR runner.
export function workbenchBoundaryPlugin(app) {
  const fixture = "/src/features/plugins/native-ui/native-main-layout.test-boundaries.tsx";
  const owner = path.join(app, "src/features/plugins/native-ui");
  const modules = new Map();
  const canonical = (id, importer) => {
    if (id.startsWith("@/")) id = path.join(app, "src", id.slice(2));
    else if (id.startsWith(".")) id = path.resolve(path.dirname(importer ?? owner), id);
    return id.replaceAll("\\", "/").replace(/\.(tsx?|jsx?)$/, "");
  };
  return {
    name: "native-workbench-boundaries",
    enforce: "pre",
    configureServer(server) {
      server.middlewares.use("/native-workbench-boundaries", (request, response) => {
        if (request.method !== "POST") {
          response.statusCode = 405;
          response.end();
          return;
        }
        request.setTimeout(5000, () => request.destroy());
        let body = "";
        request.setEncoding("utf8");
        request.on("data", (chunk) => {
          body += chunk;
          if (Buffer.byteLength(body) > 65536) request.destroy();
        });
        request.on("end", () => {
          try {
            const catalog = JSON.parse(body);
            if (!Array.isArray(catalog) || !catalog.length || catalog.length > 128)
              throw new Error("Invalid workbench boundary catalog");
            const next = new Map();
            for (const entry of catalog) {
              if (!Array.isArray(entry) || entry.length !== 2)
                throw new Error("Invalid workbench boundary entry");
              const [id, names] = entry;
              if (
                typeof id !== "string" ||
                !(
                  id.startsWith("@/") ||
                  id.startsWith("../") ||
                  ["sonner", "@tauri-apps/plugin-os", "@tauri-apps/api/window"].includes(id)
                ) ||
                !Array.isArray(names) ||
                !names.length ||
                names.some((name) => typeof name !== "string" || !/^[A-Za-z_$][\w$]*$/.test(name))
              )
                throw new Error("Invalid workbench boundary exports");
              // Keep the real project tab entry path in Edge. Bun's existing
              // suite still isolates this leaf while driving registry fixtures.
              if (id === "@/features/window/components/project-tab-bar") continue;
              next.set(canonical(id, path.join(owner, "native-main-layout.test-support.tsx")), {
                id,
                names,
              });
            }
            modules.clear();
            for (const [id, entry] of next) modules.set(id, entry);
            response.statusCode = 204;
            response.end();
          } catch (error) {
            response.statusCode = 400;
            response.end(String(error));
          }
        });
      });
    },
    resolveId(id, importer) {
      const key = canonical(id, importer);
      if (modules.has(key)) return `\0native-workbench:${key}`;
    },
    load(id) {
      if (!id.startsWith("\0native-workbench:")) return;
      const entry = modules.get(id.slice("\0native-workbench:".length));
      return [
        `import { workbenchBoundaryModules } from ${JSON.stringify(fixture)};`,
        `const boundary = workbenchBoundaryModules.get(${JSON.stringify(entry.id)});`,
        ...entry.names.map((name) =>
          name === "default"
            ? "export default boundary.default;"
            : `export const ${name} = boundary[${JSON.stringify(name)}];`,
        ),
      ].join("\n");
    },
  };
}
