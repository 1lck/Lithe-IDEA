/** Controlled component regression, not product or ui:3 package admission.
 * Example (no installation or download is performed by this runner):
 * node scripts/test-windows-native-plugin-ui-browser.mjs --browser msedge
 *   --playwright-module <Python Playwright 1.60.0>/driver/package/index.mjs
 *   --report .artifacts/native-browser/edge.json
 * Omit --playwright-module only when playwright is installed by repo configuration.
 * --step-timeout-ms defaults to 60000; --timeout-ms defaults to 120000
 * (minimum 25000, including a 20000ms cleanup reserve).
 * --mode workbench drives eight connected MainLayout workflow stages.
 * --mode native-tree drives real browser keyboard/menu/focus regressions.
 * --mode controls-input drives original native-controls input and disabled groups.
 * --mode form-grid checks native-controls geometry and editing across 640px.
 * --mode lifecycle --inject-failure worker-exit|worker-hang verifies fail-closed
 * cleanup without Vite/browser dependencies; expected red reports are separate.
 */
import {
  nativeWorkbenchRegression,
  workbenchBoundaryPlugin,
  WORKBENCH_STAGES,
  WORKBENCH_OPTIMIZE_DEPS,
} from "./native-workbench-browser.mjs";
import { spawn } from "node:child_process";
import { writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { writeTestReportArtifacts } from "../.agents/skills/write-stable-tests/scripts/generate-test-report.mjs";

const script = fileURLToPath(import.meta.url);
const root = path.resolve(path.dirname(script), "..");
const app = path.join(root, "windows/tauri");
const require = createRequire(path.join(app, "package.json"));
const started = performance.now();
const textError = (error) => String(error?.stack ?? error);

async function nativeControlsInputRegression(page, step) {
  const snapshots = [];
  const controls = await page.evaluate(() => window.nativeFormGridProbe.ui.controls);
  const byId = (id) => controls.find((control) => control.id === id);
  const field = (id) =>
    page.locator(".plugin-native-grid > *").nth(controls.findIndex((c) => c.id === id));
  // Base UI checkboxes also associate their hidden validation input with the
  // field label. Drive the public checkbox rather than that implementation input.
  const input = (id) =>
    byId(id).kind === "checkbox"
      ? field(id).getByRole("checkbox", { name: byId(id).label, exact: true })
      : field(id).getByLabel(byId(id).label, { exact: true });
  const expected = Object.fromEntries(controls.map((c) => [c.id, c.value]));
  let count = 0;
  const errors = [];
  const check = (condition, message) => {
    if (!condition) throw new Error(message);
  };
  const phase = async (name, action) => {
    const begin = performance.now();
    const observation = await step(name, action);
    snapshots.push({ name, durationMs: performance.now() - begin, observation });
  };
  const calls = () => page.evaluate(() => window.nativeFormGridProbe.calls.length);
  const committed = async () => {
    count += 1;
    try {
      await page.waitForFunction((n) => window.nativeFormGridProbe.calls.length >= n, count, {
        timeout: 3000,
      });
      // The owner disables the actual input through invoke and refresh. There
      // is no aria-busy marker on this form; wait for that public ready boundary.
      await page.waitForFunction(
        () => {
          const label = window.nativeFormGridProbe.ui.controls[0].label;
          return [...document.querySelectorAll(".plugin-native-form input")].some(
            (e) => e.getAttribute("aria-label") === label && !e.disabled,
          );
        },
        null,
        { timeout: 3000 },
      );
    } catch (error) {
      const state = await page.evaluate(() => ({
        calls: window.nativeFormGridProbe.calls,
        focus: document.activeElement?.outerHTML,
      }));
      throw new Error(`submission ${count}: ${textError(error)}; ${JSON.stringify(state)}`);
    }
    check((await calls()) === count, `submission ${count} duplicated port invocation`);
    const observation = await page.evaluate(() => {
      const call = window.nativeFormGridProbe.calls.at(-1);
      return {
        calls: window.nativeFormGridProbe.calls.length,
        action: call.action,
        values: call.context.values,
        selectionUndefined: call.context.selectedID === undefined,
      };
    });
    check(observation.action === "changed", "wrong action");
    check(observation.selectionUndefined, "typed context selection must be undefined");
    check(
      JSON.stringify(observation.values) === JSON.stringify(expected),
      `full current values mismatch: ${JSON.stringify(observation)}`,
    );
    return observation;
  };
  const type = async (id, value) => {
    await input(id).click();
    await input(id).press("ControlOrMeta+A");
    await page.keyboard.type(value);
    expected[id] = value;
    check((await input(id).inputValue()) === value, `${id} draft not rendered`);
  };
  try {
    await phase("text selection, search draft/clear and multiline editor stay local", async () => {
      await input("name").waitFor({ state: "visible" });
      const validationCount = await page.evaluate(
        () => window.nativeFormGridProbe.validations.length,
      );
      await input("name").click();
      await input("name").press("ControlOrMeta+A");
      check(
        await input("name").evaluate(
          (e) => e.selectionStart === 0 && e.selectionEnd === e.value.length,
        ),
        "native select-all did not select text",
      );
      check((await calls()) === 0, "text selection invoked port");
      await type("search", "R23 search");
      await field("search").getByRole("button", { name: "Clear search", exact: true }).click();
      expected.search = "";
      check((await input("search").inputValue()) === "", "clear did not update draft");
      check(
        await input("search").evaluate((e) => document.activeElement === e),
        "clear lost input focus",
      );
      await type("search", "R23 final query");
      await type("notes", "R23 first");
      await input("notes").press("Enter");
      await page.keyboard.type("second");
      expected.notes = "R23 first\nsecond";
      check(
        (await input("notes").inputValue()) === expected.notes,
        "editor Enter did not insert newline",
      );
      check((await calls()) === 0, "draft/clear/editor called port");
      check(
        (await page.evaluate(() => window.nativeFormGridProbe.validations.length)) ===
          validationCount,
        "draft/selection called validation port",
      );
      await input("search").press("Enter");
      return { ...(await committed()), searchEnterCommits: true };
    });
    await phase("select pointer option and keyboard option commit through owner", async () => {
      await input("environment").click();
      check((await calls()) === count, "opening select invoked port");
      await page
        .getByRole("option", { name: byId("environment").options[1].label, exact: true })
        .click();
      expected.environment = "test";
      await committed();
      await page.getByRole("listbox").waitFor({ state: "hidden", timeout: 3000 });
      await input("environment").press("Space");
      await page.getByRole("listbox").waitFor({ state: "visible", timeout: 3000 });
      // Upstream schedules initial option focus while the popup mounts. Send
      // navigation only once the selected option owns the keyboard events.
      await page.waitForFunction(
        (label) =>
          document.activeElement?.getAttribute("role") === "option" &&
          document.activeElement.textContent.includes(label),
        byId("environment").options[1].label,
        { timeout: 3000 },
      );
      await page.keyboard.press("End");
      await page.waitForFunction(
        (label) =>
          document.activeElement?.getAttribute("role") === "option" &&
          document.activeElement.textContent.includes(label),
        byId("environment").options[2].label,
        { timeout: 3000 },
      );
      await page.keyboard.press("Enter");
      expected.environment = "prod";
      return committed();
    });
    await phase("checkbox pointer and Space preserve boolean values", async () => {
      await input("notify").click();
      expected.notify = false;
      await committed();
      await input("notify").press("Space");
      expected.notify = true;
      await committed();
      await input("offline").click();
      expected.offline = true;
      check((await calls()) === count, "checkbox without onCommit invoked port");
      return { calls: count, offline: true };
    });
    await phase("segmented pointer and keyboard use real buttons", async () => {
      const buttons = field("mode").locator('button[data-slot="toggle-group-item"]');
      await buttons.nth(0).click();
      expected.mode = "fast";
      await committed();
      await buttons.nth(0).press("End");
      check(
        await buttons.nth(2).evaluate((e) => document.activeElement === e),
        "segmented End did not move focus",
      );
      check((await calls()) === count, "segmented focus navigation invoked port");
      await page.keyboard.press("Space");
      expected.mode = "debug";
      return committed();
    });
    await phase("stepper pointer and ArrowUp respect numeric type and bounds", async () => {
      const increase = field("concurrency").getByRole("button", {
        name: "Increase value",
        exact: true,
      });
      await increase.click();
      expected.concurrency = 3;
      await committed();
      await input("concurrency").press("ArrowUp");
      expected.concurrency = 4;
      await committed();
      for (let value = 5; value <= 8; value += 1) {
        await increase.click();
        expected.concurrency = value;
        await committed();
      }
      check(await increase.isDisabled(), "maximum increment remains enabled");
      return { value: 8, maximumDisabled: true };
    });
    await phase(
      "disabled native groups reject pointer and keyboard without losing values",
      async () => {
        const observations = [];
        for (const control of controls.filter((c) => c.enabled === false)) {
          // InfoTip belongs to the label; assert only the actual editing controls.
          const editing =
            control.kind === "segmented"
              ? field(control.id).locator('button[data-slot="toggle-group-item"]')
              : control.kind === "stepper"
                ? field(control.id).locator(
                    'input[data-setting-primary-control="true"],button[aria-label="Increase value"],button[aria-label="Decrease value"]',
                  )
                : input(control.id);
          const expectedCount =
            control.kind === "segmented"
              ? control.options.length
              : control.kind === "stepper"
                ? 3
                : 1;
          check(
            (await editing.count()) === expectedCount,
            `${control.id} missing editing controls`,
          );
          if (control.kind === "segmented")
            check(
              await field(control.id)
                .locator("fieldset")
                .evaluate((e) => e.disabled),
              "disabled segmented fieldset lost propagation",
            );
          for (const node of await editing.all()) {
            check(await node.isDisabled(), `${control.id} editing node is enabled`);
            const box = await node.boundingBox();
            check(box !== null, `${control.id} missing editing node`);
            await node.scrollIntoViewIfNeeded();
            const visible = await node.boundingBox();
            await page.mouse.click(2, 2);
            await page.mouse.click(visible.x + visible.width / 2, visible.y + visible.height / 2);
            check(
              !(await node.evaluate((e) => document.activeElement === e)),
              `${control.id} received pointer focus`,
            );
          }
          const info = field(control.id).getByRole("button", {
            name: `Information for ${control.label}`,
            exact: true,
          });
          check(!(await info.isDisabled()), `${control.id} disabled its InfoTip`);
          await info.click();
          const dialog = page.getByRole("dialog");
          await dialog.waitFor({ state: "visible", timeout: 3000 });
          check((await dialog.textContent()) === control.info, `${control.id} InfoTip changed`);
          await info.click();
          await dialog.waitFor({ state: "detached", timeout: 3000 });
          // Start immediately before the editing controls in document order.
          // One real Tab must leave the whole disabled group, including every
          // segmented choice and both stepper buttons.
          await info.press("Tab");
          check(
            await field(control.id).evaluate(
              (e) =>
                document.activeElement !== document.body && !e.contains(document.activeElement),
            ),
            `${control.id} received Tab focus or lost the keyboard focus`,
          );
          observations.push({
            id: control.id,
            disabled: true,
            infoTipInteractive: true,
            tabSkipped: true,
          });
        }
        check((await calls()) === count, "disabled interaction called port");
        return observations;
      },
    );
    await phase(
      "one final explicit submission contains every current and disabled field",
      async () => {
        await type("name", "R23 final name");
        await type("query", "R23 final draft");
        check((await calls()) === count, "final drafts invoked port");
        const label = await page.evaluate(() => window.nativeFormGridProbe.ui.buttons[0].label);
        await page.getByRole("button", { name: label, exact: true }).click();
        const result = await committed();
        check((await calls()) === count, "final button duplicated submission");
        return { ...result, totalCalls: count };
      },
    );
  } catch (error) {
    errors.push(error);
  } finally {
    try {
      await step(
        "dispose controls-input fixture",
        () =>
          page.evaluate(() => {
            window.nativeFormGridProbe.dispose();
            if (document.querySelector('[role="listbox"]')) throw new Error("Select portal leaked");
            if (document.querySelector('[role="dialog"]')) throw new Error("InfoTip portal leaked");
          }),
        5000,
      );
    } catch (error) {
      errors.push(error);
    }
  }
  if (errors.length > 1)
    throw new AggregateError(errors, "Controls input failure and fixture cleanup failure");
  if (errors.length) throw errors[0];
  return { snapshots };
}

async function nativeFormGridRegression(page, step) {
  const snapshots = [];
  let primaryError;
  const check = (condition, message) => {
    if (!condition) throw new Error(message);
  };
  const phase = async (name, action) => {
    const begin = performance.now();
    const observation = await step(name, action);
    snapshots.push({ name, durationMs: performance.now() - begin, observation });
  };
  const grid = page.locator(".plugin-native-grid");
  const labels = await page.evaluate(() =>
    window.nativeFormGridProbe.ui.controls.map((c) => c.label),
  );
  const input = page.getByRole("textbox", { name: labels[0], exact: true });
  const draft = "R22 draft English";
  try {
    await phase("12-column fixture ready; retain all control nodes", async () => {
      await input.waitFor({ state: "visible" });
      await page.waitForFunction(() => document.fonts.status === "loaded");
      return grid.evaluate((element) => {
        const controls = window.nativeFormGridProbe.ui.controls;
        if (
          window.nativeFormGridProbe.ui.layout.columns !== 12 ||
          controls.some((c) => c.span !== 6)
        )
          throw new Error("native-controls fixture layout changed");
        window.nativeFormGridNodes = [
          ...element.querySelectorAll("input,textarea,button,fieldset"),
        ];
        window.nativeFormGridFields = [...element.children];
        if (element.children.length !== controls.length) throw new Error("missing declared fields");
        return { columns: 12, spans: controls.map((c) => c.span), fields: controls.length };
      });
    });
    await input.click();
    await input.press("ControlOrMeta+A");
    await page.keyboard.type(draft);
    // Keep the 2600px viewport fixed and resize only the fixture container.
    // This distinguishes a container query from a viewport media query.
    for (const [name, width, tracks] of [
      ["wide", 900, 12],
      ["below-640", 639, 1],
      ["at-640", 640, 12],
      ["wide-again", 900, 12],
    ]) {
      await phase(`${name}: span geometry, identity, draft and editing focus`, async () => {
        try {
          // Calibrate the real content width: a vertical scrollbar can appear
          // during reflow, so padding alone is not the host-to-grid inset.
          await page.waitForFunction(
            (expected) => {
              const host = document.getElementById("probe");
              const grid = host.querySelector(".plugin-native-grid");
              const delta = expected.width - grid.getBoundingClientRect().width;
              if (Math.abs(delta) > 0.01) {
                host.style.width = `${host.getBoundingClientRect().width + delta}px`;
                return false;
              }
              return (
                getComputedStyle(grid).gridTemplateColumns.split(" ").length === expected.tracks
              );
            },
            { width, tracks },
            { timeout: 3000, polling: "raf" },
          );
        } catch (error) {
          const diagnostic = await grid.evaluate((element) => {
            const form = element.closest(".plugin-native-form");
            return {
              gridWidth: element.getBoundingClientRect().width,
              hostWidth: document.getElementById("probe").getBoundingClientRect().width,
              formWidth: form.getBoundingClientRect().width,
              clientWidth: form.clientWidth,
              scrollHeight: form.scrollHeight,
              clientHeight: form.clientHeight,
              template: getComputedStyle(element).gridTemplateColumns,
            };
          });
          throw new Error(
            `${name}: content width ${width}px / ${tracks} tracks did not settle within 3000ms; ${JSON.stringify(diagnostic)}; ${textError(error)}`,
          );
        }
        const result = await grid.evaluate(
          (element, expected) => {
            const fields = [...element.children];
            const nodes = [...element.querySelectorAll("input,textarea,button,fieldset")];
            if (
              fields.some((field, i) => field !== window.nativeFormGridFields[i]) ||
              nodes.length !== window.nativeFormGridNodes.length ||
              nodes.some((node, i) => node !== window.nativeFormGridNodes[i])
            )
              throw new Error("control DOM identity changed during reflow");
            const boxes = fields.map((field) => field.getBoundingClientRect().toJSON());
            const rect = element.getBoundingClientRect();
            const gap = parseFloat(getComputedStyle(element).columnGap);
            const close = (a, b) => Math.abs(a - b) < 1;
            if (!close(rect.width, expected.width))
              throw new Error("wrong container content width");
            boxes.forEach((box, index) => {
              const columns = expected.tracks === 1 ? 1 : 2;
              const expectedWidth = (rect.width - gap * (columns - 1)) / columns;
              if (
                !close(box.width, expectedWidth) ||
                !close(box.x, rect.x + (index % columns) * (expectedWidth + gap)) ||
                (columns === 2 && index % 2 === 1 && !close(box.y, boxes[index - 1].y)) ||
                (index >= columns &&
                  !close(
                    box.y,
                    Math.max(
                      ...boxes
                        .slice(index - (index % columns) - columns, index - (index % columns))
                        .map((b) => b.bottom),
                    ) + gap,
                  ))
              )
                throw new Error(`field ${index} violated span packing/top alignment`);
            });
            const controls = window.nativeFormGridProbe.ui.controls;
            fields.forEach((field, index) => {
              const control = controls[index];
              if (control.enabled !== false) return;
              if (control.kind === "segmented") {
                const fieldset = field.querySelector("fieldset");
                const choices = [
                  ...field.querySelectorAll('button[data-slot="toggle-group-item"]'),
                ];
                if (
                  !fieldset?.disabled ||
                  choices.length !== control.options.length ||
                  choices.some((choice) => !choice.matches(":disabled"))
                )
                  throw new Error(`${control.id}: fieldset/button disabled semantics lost`);
                return;
              }
              const input = field.querySelector(`[aria-label=${JSON.stringify(control.label)}]`);
              if (!(input?.matches(":disabled") || input?.getAttribute("aria-disabled") === "true"))
                throw new Error(`${control.id}: disabled semantics lost`);
            });
            return {
              containerWidth: rect.width,
              viewportWidth: innerWidth,
              tracks: expected.tracks,
              gap,
              boxes,
            };
          },
          { width, tracks },
        );
        check((await input.inputValue()) === draft, "local draft changed");
        check(await input.evaluate((el) => document.activeElement === el), "editing focus lost");
        check(
          (await page.evaluate(() => window.nativeFormGridProbe.calls.length)) === 0,
          "reflow/edit invoked port",
        );
        return result;
      });
    }
    await phase(
      "disabled field InfoTip and shared readOnly primitive retain semantics",
      async () => {
        const disabled = page.getByRole("textbox", { name: labels[5], exact: true });
        check(await disabled.isDisabled(), "disabled input enabled");
        const info = page.getByRole("button", {
          name: `Information for ${labels[5]}`,
          exact: true,
        });
        await info.click();
        await page.getByRole("dialog").waitFor({ state: "visible" });
        check(
          (await page.getByRole("dialog").textContent()) ===
            (await page.evaluate(() => window.nativeFormGridProbe.ui.controls[5].info)),
          "InfoTip content changed",
        );
        await info.click();
        await page.getByRole("dialog").waitFor({ state: "detached" });
        const readonly = page.getByRole("textbox", { name: "ReadOnly primitive", exact: true });
        check(
          await readonly.evaluate((el) => el.readOnly && !el.disabled),
          "readOnly primitive flags changed",
        );
        await readonly.click();
        await readonly.press("ControlOrMeta+A");
        await page.keyboard.type("must not edit");
        check((await readonly.inputValue()) === "fixed query", "readOnly value changed");
        check(
          await page
            .locator("[data-readonly-probe]")
            .getByRole("button", { name: "Clear search" })
            .isDisabled(),
          "readOnly clear enabled",
        );
        return { nativeReadOnly: "not declared by schema 1; shared SearchField only" };
      },
    );
    await phase("Return submits complete current values exactly once", async () => {
      await input.click();
      await input.press("Enter");
      await page.waitForFunction(
        () =>
          window.nativeFormGridProbe.calls.length === 1 &&
          !document.querySelector(".plugin-native-grid input").disabled,
      );
      const calls = await page.evaluate(() => window.nativeFormGridProbe.calls);
      const expected = await page.evaluate(
        (value) =>
          Object.fromEntries(
            window.nativeFormGridProbe.ui.controls.map((c) => [
              c.id,
              c.id === "name" ? value : c.value,
            ]),
          ),
        draft,
      );
      // The typed port uses undefined for no selection; the native bridge is
      // responsible for encoding that absence as provider JSON null.
      check(
        calls.length === 1 &&
          calls[0].action === "changed" &&
          calls[0].context.selectedID === undefined,
        "wrong submission count/action/selection",
      );
      check(
        JSON.stringify(calls[0].context.values) === JSON.stringify(expected),
        "submission omitted or changed field values",
      );
      return { calls, expected };
    });
    return { snapshots };
  } catch (error) {
    primaryError = error;
    throw error;
  } finally {
    try {
      await step(
        "dispose form-grid fixture",
        () =>
          page.evaluate(() => {
            window.nativeFormGridProbe.dispose();
            delete window.nativeFormGridNodes;
            delete window.nativeFormGridFields;
            if (document.querySelector('[role="dialog"]')) throw new Error("InfoTip portal leaked");
          }),
        5000,
      );
    } catch (error) {
      throw new Error(
        `${primaryError ? textError(primaryError) + "; " : ""}fixture cleanup: ${textError(error)}`,
      );
    }
  }
}

// Playwright drives the browser's default keyboard path; fixture evaluation is
// limited to controlled port gates, DOM observation and deliberate scrolling.
async function nativeTreeRegression(page, step) {
  const snapshots = [];
  let primaryError;
  const check = (condition, message) => {
    if (!condition) throw new Error(message);
  };
  const observe = (predicate) => page.waitForFunction(predicate);
  // Context menus hide background content from the accessibility tree while
  // open. Observe its mounted DOM without changing the public modal behavior;
  // all keyboard and pointer actions below still use real browser input.
  const tree = page.locator('[role="tree"][aria-label="Sample Explorer"]');
  const menu = page.getByRole("menu");
  const selected = () => tree.getAttribute("aria-activedescendant");
  const calls = () => page.evaluate(() => window.nativeTreeProbe.calls);
  const phase = async (name, action) => {
    const begin = performance.now();
    await step(name, action);
    snapshots.push({ name, durationMs: performance.now() - begin });
  };
  const closed = () => menu.waitFor({ state: "detached" });
  const treeFocused = () => observe(() => document.activeElement?.getAttribute("role") === "tree");
  const open = async (key) => {
    await tree.press(key);
    await menu.waitFor({ state: "visible" });
    await observe(() => document.querySelector('[role="menu"]')?.contains(document.activeElement));
    // Base UI intentionally guards outside presses for 500ms after a
    // controlled context-menu open. Advance its browser clock deterministically
    // before testing dismissal, without sleeping or changing product handlers.
    await page.clock.runFor(500);
    check((await menu.count()) === 1, "expected exactly one public context menu");
  };
  try {
    await phase("ready real tree and disabled no-selection action", async () => {
      await tree.waitFor({ state: "visible" });
      await page.getByRole("treeitem", { name: "Branch", exact: false }).waitFor();
      const inspect = page.getByRole("button", { name: "Inspect", exact: true });
      check(await inspect.isDisabled(), "selection-required Inspect should be disabled");
      await inspect.focus();
      await page.keyboard.press("Enter");
      check((await calls()).length === 0, "disabled toolbar action ran");
      check((await tree.getByRole("treeitem").count()) < 100, "tree is not virtualized");
      await tree.focus();
      await tree.press("Home");
      await tree.press("ArrowRight");
      await tree.press("ArrowDown");
      await observe(
        () =>
          document.querySelector('[role="treeitem"][aria-selected="true"]')?.textContent ===
          "Child row",
      );
    });
    for (const key of ["Shift+F10", "ContextMenu"]) {
      await phase(`${key} mounts offscreen selection and Escape returns to tree`, async () => {
        await tree.evaluate((element) => {
          element.scrollTop = 8000;
        });
        await observe(
          () => !document.querySelector('[role="tree"]')?.hasAttribute("aria-activedescendant"),
        );
        await open(key);
        const mounted = tree.locator('[role="treeitem"][aria-selected="true"]');
        check(
          (await mounted.count()) === 1 && (await mounted.textContent()) === "Child row",
          "selected child not remounted",
        );
        const row = await tree.locator('[aria-selected="true"]').boundingBox();
        const viewport = await tree.boundingBox();
        const popup = await menu.boundingBox();
        check(
          row &&
            viewport &&
            popup &&
            row.y >= viewport.y &&
            row.y + row.height <= viewport.y + viewport.height + 1,
          "selected row not scrolled into viewport",
        );
        check(
          Math.abs(popup.y - row.y) < 4 && Math.abs(popup.x - (row.x + row.width)) < 4,
          "public menu not anchored beside selected row",
        );
        const before = await selected();
        for (const arrow of ["ArrowDown", "ArrowUp", "ArrowLeft", "ArrowRight", "End", "Home"]) {
          await page.keyboard.press(arrow);
          check((await selected()) === before, `${arrow} leaked into tree navigation`);
        }
        await page.keyboard.press("Escape");
        await closed();
        await treeFocused();
      });
    }
    await phase("outside pointer dismisses menu; subsequent input retains focus", async () => {
      await open("Shift+F10");
      // The public modal backdrop consumes the first pointer click to dismiss.
      // Hit the real input coordinates, then edit after dismissal using another
      // normal click; never force a click through the modal backdrop.
      const input = page.locator('input[aria-label="Other setting"]');
      const bounds = await input.boundingBox();
      check(bounds, "outside input has no geometry");
      await step("outside pointer dismisses modal menu", () =>
        page.mouse.click(bounds.x + bounds.width / 2, bounds.y + bounds.height / 2),
      );
      await step("menu closes after outside click", closed, 10000);
      await input.click();
      await observe(() => document.activeElement?.getAttribute("aria-label") === "Other setting");
      await page.keyboard.type("outside draft");
      check(
        (await page.getByRole("textbox", { name: "Other setting" }).inputValue()) ===
          "outside draft",
        "outside editing lost focus",
      );
    });
    await phase("Inspect exactly once with child target; busy menu blocks activation", async () => {
      await page.evaluate(() => window.nativeTreeProbe.configure({ hold: true }));
      await tree.focus();
      await open("ContextMenu");
      await page.keyboard.press("End");
      await page.keyboard.down("Enter");
      await page.keyboard.down("Enter");
      await page.keyboard.up("Enter");
      await closed();
      await observe(
        () => window.nativeTreeProbe.calls.length === 1 && window.nativeTreeProbe.pending() === 1,
      );
      check((await calls())[0].context.selectedID === "child", "Inspect target changed");
      check((await calls())[0].action === "inspect", "wrong action invoked");
      await tree.focus();
      await open("Shift+F10");
      check(
        (await menu.getByRole("menuitem", { name: "Inspect" }).getAttribute("aria-disabled")) ===
          "true",
        "busy Inspect is enabled",
      );
      await page.keyboard.press("End");
      await page.keyboard.press("Enter");
      check((await calls()).length === 1, "busy action executed");
      await page.keyboard.press("Escape");
      await closed();
      await treeFocused();
      await page.evaluate(() => window.nativeTreeProbe.release());
      await observe(
        () =>
          window.nativeTreeProbe.pending() === 0 &&
          !document.querySelector('button[aria-label="Inspect"]')?.disabled,
      );
    });
    await phase("action dialog retains its new focus owner", async () => {
      await page.evaluate(() => window.nativeTreeProbe.configure({ dialog: true }));
      await open("ContextMenu");
      await page.keyboard.press("End");
      await page.keyboard.press("Enter");
      await closed();
      await page.getByRole("dialog").waitFor({ state: "visible" });
      await observe(() => document.activeElement?.getAttribute("aria-label") === "Action input");
      await page.keyboard.type("action draft");
      check(
        (await page.getByRole("textbox", { name: "Action input" }).inputValue()) === "action draft",
        "menu stole dialog input focus",
      );
      const invoked = await calls();
      check(
        invoked.length === 2 && invoked.every((call) => call.context.selectedID === "child"),
        "dialog action target/count changed",
      );
      await page.evaluate(() => window.nativeTreeProbe.closeDialog());
      await page.getByRole("dialog").waitFor({ state: "detached" });
    });
    await phase("virtual row unmount closes menu without reopening", async () => {
      await tree.focus();
      await open("Shift+F10");
      await tree.evaluate((element) => {
        element.scrollTop = 8000;
      });
      await closed();
      await observe(
        () => !document.querySelector('[role="tree"]')?.hasAttribute("aria-activedescendant"),
      );
      await tree.evaluate((element) => {
        element.scrollTop = 0;
      });
      await tree.getByRole("treeitem", { name: "Child row", exact: true }).waitFor();
      check((await menu.count()) === 0, "menu reopened after row remount");
    });
    const keyboardEvents = await page.evaluate(() => window.nativeTreeKeyboardEvents);
    check(
      ["F10", "ContextMenu"].every((key) =>
        keyboardEvents.some((event) => event.key === key && event.isTrusted),
      ),
      "both menu triggers must traverse trusted browser keyboard events",
    );
    return {
      snapshots,
      calls: await calls(),
      keyboardEvents,
      input: "Playwright trusted keyboard; no synthetic click fallback",
    };
  } catch (error) {
    const diagnostic = await page
      .evaluate(() => ({
        active: document.activeElement?.outerHTML,
        menus: [...document.querySelectorAll('[role="menu"]')].map((element) => element.outerHTML),
        input: document.querySelector('input[aria-label="Other setting"]')?.outerHTML,
      }))
      .catch(() => null);
    primaryError = new Error(`${textError(error)}; DOM diagnostic: ${JSON.stringify(diagnostic)}`);
    throw primaryError;
  } finally {
    try {
      await step("dispose tree fixture", () =>
        page.evaluate(() => window.nativeTreeProbe.dispose()),
      );
      await closed();
      await page.getByRole("dialog").waitFor({ state: "detached" });
      check(
        (await page.evaluate(() => window.nativeTreeProbe.pending())) === 0,
        "controlled port gate leaked",
      );
    } catch (cleanupError) {
      throw new Error(
        `${primaryError ? textError(primaryError) + "; " : ""}fixture cleanup: ${textError(cleanupError)}`,
      );
    }
  }
}

async function worker(options) {
  if (["worker-exit", "worker-hang", "supervisor-exit"].includes(options.injectFailure)) {
    const descendant = spawn(process.execPath, ["-e", "setInterval(() => {}, 1000)"], {
      stdio: "ignore",
      windowsHide: true,
    });
    await new Promise((resolve, reject) => {
      descendant.once("spawn", resolve);
      descendant.once("error", reject);
    });
    await writeFile(
      options.injectionMarker,
      JSON.stringify({ workerPid: process.pid, descendantPid: descendant.pid }),
    );
    if (options.injectFailure === "worker-exit") process.exit(17);
    // The independent Job Object owner, not this deliberately stuck worker,
    // must terminate both processes within the caller's deadline.
    await new Promise(() => {});
  }
  let server, context, page;
  const evidence = { pageErrors: [], windowErrors: [], steps: [], cleanup: {} };
  const step = async (name, action, ms = options.stepMs) => {
    const begin = performance.now();
    let timer;
    try {
      return await Promise.race([
        Promise.resolve().then(action),
        new Promise((_, reject) => {
          timer = setTimeout(() => reject(new Error(`${name}: deadline ${ms}ms exceeded`)), ms);
        }),
      ]);
    } finally {
      clearTimeout(timer);
      evidence.steps.push({ name, durationMs: performance.now() - begin });
    }
  };
  try {
    const fixtureFile =
      options.mode === "workbench"
        ? "native-workbench.browser-test.tsx"
        : options.mode === "native-tree"
          ? "native-tree.browser-test.tsx"
          : ["form-grid", "controls-input"].includes(options.mode)
            ? "native-form-grid.browser-test.tsx"
            : "native-panel.browser-test.tsx";
    const { createServer } = await step(
      "load Vite",
      () => import(pathToFileURL(require.resolve("vite")).href),
    );
    const { chromium } = await step(
      "load Playwright",
      () =>
        import(
          options.module
            ? pathToFileURL(path.resolve(options.module)).href
            : pathToFileURL(require.resolve("playwright")).href
        ),
    );
    server = await step("create Vite", () =>
      createServer({
        root: app,
        configFile: path.join(app, "vite.config.ts"),
        cacheDir: path.join(options.scratch, "cache"),
        optimizeDeps: {
          ...(options.mode === "workbench" ? WORKBENCH_OPTIMIZE_DEPS : {}),
          entries: [
            `src/features/plugins/native-ui/${options.mode === "workbench" ? "native-main-layout.test-boundaries.tsx" : fixtureFile}`,
          ],
        },
        server: { port: 0, host: "127.0.0.1", open: false },
        plugins: [
          ...(options.mode === "workbench" ? [workbenchBoundaryPlugin(app)] : []),
          {
            name: "native-panel-browser-regression",
            configureServer(vite) {
              vite.middlewares.use("/native-panel-test.html", async (_request, response, next) => {
                try {
                  const html = await vite.transformIndexHtml(
                    "/native-panel-test.html",
                    `<html><head><link rel="icon" href="data:,"></head><body><div id="probe"></div><script type="module">
              import '/@vite/client';
              import '/src/styles.css';
              import { mockWindows, mockIPC } from '@tauri-apps/api/mocks';
              mockWindows('browser-test');
              window.bootstrapIPC = [];
              mockIPC(command => {
                window.bootstrapIPC.push(command);
                if (command === 'plugin:window|get_all_windows') return ['browser-test'];
                throw new Error('Unexpected native command in component test: ' + command);
              });
              ${
                options.mode === "workbench"
                  ? `
              const { workbenchBoundaryModules } = await import('/src/features/plugins/native-ui/native-main-layout.test-boundaries.tsx');
              const registration = await fetch('/native-workbench-boundaries', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify([...workbenchBoundaryModules].map(([id, exports]) => [id, Object.keys(exports)])),
                signal: AbortSignal.timeout(5000),
              });
              if (!registration.ok) throw new Error('Workbench boundary registration failed: ' + await registration.text());
              const { mountNativeWorkbenchBrowserTest } = await import('/src/features/plugins/native-ui/native-workbench.browser-test.tsx');
              window.nativeWorkbenchProbe = await mountNativeWorkbenchBrowserTest(document.getElementById('probe'));
              window.runNativePanelTest = () => true;
              `
                  : options.mode === "native-tree"
                    ? `
              const { mountNativeTreeBrowserTest } = await import('/src/features/plugins/native-ui/native-tree.browser-test.tsx');
              window.nativeTreeProbe = mountNativeTreeBrowserTest(document.getElementById('probe'));
              window.runNativePanelTest = () => true;
              `
                    : ["form-grid", "controls-input"].includes(options.mode)
                      ? `
              const { mountNativeFormGridBrowserTest } = await import('/src/features/plugins/native-ui/native-form-grid.browser-test.tsx');
              window.nativeFormGridProbe = mountNativeFormGridBrowserTest(document.getElementById('probe'));
              window.runNativePanelTest = () => true;
              `
                      : `
              const { testNativeActionGroupLayout } = await import('/src/features/plugins/native-ui/native-panel.browser-test.tsx');
              window.runNativePanelTest = () => testNativeActionGroupLayout(document.getElementById('probe'));
              `
              }
            </script></body></html>`,
                  );
                  response.setHeader("Content-Type", "text/html");
                  response.end(html);
                } catch (error) {
                  next(error);
                }
              });
            },
          },
        ],
      }),
    );
    await step("listen Vite", () => server.listen());
    context = await step("launch browser", () =>
      chromium.launchPersistentContext(path.join(options.scratch, "profile"), {
        ...(options.browser === "chromium" ? {} : { channel: options.browser }),
        headless: true,
        timeout: options.stepMs,
        viewport: { width: 2600, height: 1100 },
      }),
    );
    evidence.browserVersion = context.browser()?.version();
    page = await step("create page", () => context.newPage());
    page.setDefaultTimeout(options.stepMs);
    page.on("pageerror", (error) => evidence.pageErrors.push(textError(error)));
    if (options.mode === "workbench") {
      evidence.consoleErrors = [];
      page.on("console", (message) => {
        if (message.type() === "error")
          evidence.consoleErrors.push({ text: message.text(), location: message.location() });
      });
    }
    // Installed before navigation: includes ResizeObserver errors and resource errors.
    await step("install window.error listener", () =>
      page.addInitScript(() => {
        window.nativePanelWindowErrors = [];
        window.nativeTreeKeyboardEvents = [];
        document.addEventListener("keydown", (event) => {
          window.nativeTreeKeyboardEvents.push({
            key: event.key,
            shiftKey: event.shiftKey,
            isTrusted: event.isTrusted,
            defaultPrevented: event.defaultPrevented,
          });
        });
        window.addEventListener(
          "error",
          (event) =>
            window.nativePanelWindowErrors.push(
              event.message ||
                `Resource error: ${event.target?.src || event.target?.href || event.target?.tagName}`,
            ),
          true,
        );
      }),
    );
    await step("navigate", () =>
      page.goto(`http://127.0.0.1:${server.httpServer.address().port}/native-panel-test.html`, {
        timeout: options.stepMs,
        waitUntil: "domcontentloaded",
      }),
    );
    await step("bootstrap", () =>
      page.waitForFunction(() => typeof window.runNativePanelTest === "function", null, {
        timeout: options.stepMs,
      }),
    );
    await step("load resources", () =>
      page.waitForLoadState("networkidle", { timeout: options.stepMs }),
    );
    if (options.injectFailure === "page")
      await step("inject page failure", () =>
        page.evaluate(() => {
          window.dispatchEvent(new ErrorEvent("error", { message: "controlled runner failure" }));
        }),
      );
    if (options.mode === "native-tree")
      await step("install controlled browser clock", () => page.clock.install());
    evidence.component =
      options.mode === "workbench"
        ? await nativeWorkbenchRegression(page, step)
        : options.mode === "native-tree"
          ? await nativeTreeRegression(page, step)
          : ["form-grid", "controls-input"].includes(options.mode)
            ? options.mode === "controls-input"
              ? await nativeControlsInputRegression(page, step)
              : await nativeFormGridRegression(page, step)
            : await step("six-stage component regression", () =>
                page.evaluate(() => window.runNativePanelTest()),
              );
    evidence.windowErrors = await step("collect window errors", () =>
      page.evaluate(() => window.nativePanelWindowErrors),
    );
    evidence.bootstrapIPC = await step("collect mock IPC", () =>
      page.evaluate(() => window.bootstrapIPC),
    );
    if (
      evidence.windowErrors.length ||
      evidence.pageErrors.length ||
      evidence.consoleErrors?.length
    )
      throw new Error(
        JSON.stringify({
          windowErrors: evidence.windowErrors,
          pageErrors: evidence.pageErrors,
          consoleErrors: evidence.consoleErrors,
        }),
      );
  } catch (error) {
    evidence.error = textError(error);
    if (error.workbenchEvidence) evidence.component = error.workbenchEvidence;
    if (page) {
      try {
        evidence.windowErrors = await step(
          "collect window errors after failure",
          () => page.evaluate(() => window.nativePanelWindowErrors ?? []),
          2000,
        );
      } catch (observationError) {
        evidence.error += `; window.error collection: ${textError(observationError)}`;
      }
    }
  } finally {
    for (const [name, close] of [
      ["browser", () => context?.close()],
      ["Vite", () => server?.close()],
    ]) {
      try {
        await step(`close ${name}`, close, 5000);
        evidence.cleanup[name] = true;
      } catch (error) {
        (evidence.cleanup.errors ??= []).push(textError(error));
      }
    }
    evidence.cleanup.serverListening = server?.httpServer?.listening ?? false;
  }
  await writeFile(options.evidenceFile, JSON.stringify(evidence));
  // The independent supervisor always terminates and proves the entire job
  // empty, including drivers left behind after this worker exits unexpectedly.
  process.exit(evidence.error || evidence.cleanup.errors?.length ? 1 : 0);
}

async function main() {
  const options = {
    mode: "action-group",
    browser: "msedge",
    stepMs: 60000,
    overallMs: 120000,
    report: path.join(root, ".artifacts/test-stability/native-panel-browser.json"),
  };
  let child, timer, hardTimer, scratch;
  const result = {
    scope: "controlled browser component; no product or ui:3 admission",
    command: process.argv,
    exitCode: 1,
  };
  try {
    const args = process.argv.slice(2);
    for (let index = 0; index < args.length; index++) {
      const flag = args[index];
      const value = args[++index];
      if (!value) throw new Error(`Missing value for ${flag}`);
      if (flag === "--browser") options.browser = value;
      else if (flag === "--mode") options.mode = value;
      else if (flag === "--playwright-module") options.module = value;
      else if (flag === "--report") options.report = path.resolve(value);
      else if (flag === "--step-timeout-ms") options.stepMs = Number(value);
      else if (flag === "--timeout-ms") options.overallMs = Number(value);
      else if (
        flag === "--inject-failure" &&
        ["page", "worker-exit", "worker-hang", "supervisor-exit"].includes(value)
      )
        options.injectFailure = value;
      else throw new Error(`Unknown argument: ${flag}`);
    }
    if (process.platform !== "win32")
      throw new Error("This runner requires Windows process-tree cleanup");
    if (
      ![
        "action-group",
        "native-tree",
        "form-grid",
        "controls-input",
        "workbench",
        "lifecycle",
      ].includes(options.mode)
    )
      throw new Error(
        "mode must be action-group, native-tree, form-grid, controls-input, workbench or lifecycle",
      );
    if (
      options.mode === "lifecycle" &&
      !["worker-exit", "worker-hang"].includes(options.injectFailure)
    )
      throw new Error("lifecycle requires --inject-failure worker-exit or worker-hang");
    if (!["msedge", "chrome", "chromium"].includes(options.browser))
      throw new Error("browser must be msedge, chrome or chromium");
    for (const ms of [options.stepMs, options.overallMs])
      if (!Number.isSafeInteger(ms) || ms < 1 || ms > 600000)
        throw new Error("Deadlines must be integers in 1..600000ms");
    if (!options.report.endsWith(".json")) throw new Error("--report must end in .json");
    if (options.overallMs < 25000)
      throw new Error("--timeout-ms must be at least 25000ms, including cleanup reserve");
    hardTimer = setTimeout(
      () => {
        // This watchdog also covers a stalled finalizer or a failed supervisor
        // termination. The supervisor owns a non-inherited KILL_ON_JOB_CLOSE
        // handle and an earlier independent worker deadline.
        try {
          if (child && child.exitCode === null && child.signalCode === null) child.kill();
        } catch (error) {
          result.supervisorTerminationError = textError(error);
        }
        result.exitCode = 1;
        result.error = `Overall deadline ${options.overallMs}ms exceeded including cleanup`;
        result.cleanup ??= {};
        result.cleanup.ownershipCleanupUnproven = true;
        result.cleanup.retainedScratch = scratch;
        result.durationMs = performance.now() - started;
        try {
          writeFileSync(
            options.report,
            JSON.stringify(
              {
                schemaVersion: 1,
                runner: "native-panel controlled browser",
                warnMs: 30000,
                maxMs: options.overallMs,
                result,
                tests: [
                  {
                    name: "browser runner overall watchdog",
                    suite: "native-panel.browser-test.tsx",
                    status: "timeout",
                    durationMs: result.durationMs,
                    message: result.error,
                  },
                ],
              },
              null,
              2,
            ),
          );
          writeTestReportArtifacts(options.report);
        } finally {
          process.exit(1);
        }
      },
      Math.max(1, options.overallMs - (performance.now() - started)),
    );
    await mkdir(path.dirname(options.report), { recursive: true });
    await writeFile(
      options.report,
      JSON.stringify({
        schemaVersion: 1,
        runner: "native-panel controlled browser",
        warnMs: 30000,
        maxMs: options.overallMs,
        tests: [
          {
            name: "browser runner pending completion",
            suite: "native-panel.browser-test.tsx",
            status: "incomplete",
            durationMs: 0,
          },
        ],
      }),
    );
    writeTestReportArtifacts(options.report);
    await mkdir(path.join(root, ".artifacts"), { recursive: true });
    scratch = await mkdtemp(path.join(root, ".artifacts/native-browser-"));
    options.scratch = scratch;
    options.evidenceFile = path.join(scratch, "worker-evidence.json");
    options.injectionMarker = path.join(scratch, "injection.json");
    const jobResult = path.join(scratch, "job-result.json");
    const executionMs = Math.max(
      1,
      Math.floor(options.overallMs - 20000 - (performance.now() - started)),
    );
    const supervisorArgs = [
      "-B",
      path.join(root, "scripts/plugin-host-acceptance/native_browser_supervisor.py"),
      "--timeout-ms",
      String(executionMs),
      "--result",
      jobResult,
      "--log",
      path.join(scratch, "worker.log"),
      ...(options.injectFailure === "supervisor-exit"
        ? ["--force-owner-exit-on", options.injectionMarker]
        : []),
      "--",
      process.execPath,
      script,
      "--worker",
      JSON.stringify(options),
    ];
    const supervisorExit = await new Promise((resolve, reject) => {
      child = spawn("python", supervisorArgs, {
        stdio: ["ignore", "inherit", "inherit"],
        windowsHide: true,
      });
      child.once("error", reject);
      child.once("exit", (code, signal) => resolve({ code, signal }));
      // The helper's worker budget ends 20s before overall. Its existing job
      // cleanup has 7s; reserve the remaining time for parent cleanup/reporting.
      timer = setTimeout(
        () => reject(new Error("Job supervisor exceeded its cleanup deadline")),
        Math.max(1, options.overallMs - 10000 - (performance.now() - started)),
      );
    });
    result.supervisorExit = supervisorExit;
    try {
      result.job = JSON.parse(await readFile(jobResult, "utf8"));
    } catch (error) {
      throw new Error(`Job cleanup proof unavailable: ${textError(error)}`);
    }
    if (
      result.job.cleanup?.jobTerminated !== true ||
      result.job.cleanup?.activeProcesses !== 0 ||
      result.job.cleanupError
    ) {
      throw new Error("Job cleanup did not prove zero active processes");
    }
    try {
      result.evidence = JSON.parse(await readFile(options.evidenceFile, "utf8"));
    } catch (error) {
      throw new Error(
        `Worker evidence unavailable after ${result.job.exitCode}: ${textError(error)}`,
      );
    }
    const evidence = result.evidence;
    if (
      evidence.component?.snapshots?.length !==
        (options.mode === "workbench"
          ? WORKBENCH_STAGES
          : ["native-tree", "form-grid", "controls-input"].includes(options.mode)
            ? 7
            : 6) &&
      !evidence.error
    )
      throw new Error("Expected all component regression stages");
    if (evidence.error) throw new Error(evidence.error);
    if (evidence.cleanup.errors?.length || evidence.cleanup.serverListening)
      throw new Error("Worker cleanup failed");
    if (supervisorExit.code !== 0 || result.job.status !== "passed")
      throw new Error(`Job supervisor failed: ${result.job.error ?? supervisorExit.code}`);
    result.exitCode = 0;
  } catch (error) {
    result.error = textError(error);
  } finally {
    clearTimeout(timer);
    result.cleanup = {};
    if (child && child.exitCode === null && child.signalCode === null) {
      // Terminating this exact direct child closes its native Job handle. We
      // still fail closed without a published zero-member proof.
      result.cleanup.supervisorTerminationRequested = child.kill();
      result.exitCode = 1;
      result.cleanup.supervisorExited = await new Promise((resolve) => {
        if (child.exitCode !== null || child.signalCode !== null) return resolve(true);
        const deadline = setTimeout(() => resolve(false), 5000);
        child.once("exit", () => {
          clearTimeout(deadline);
          resolve(true);
        });
      });
      if (!result.cleanup.supervisorExited) child.unref();
    }
    const ownershipProven =
      result.job?.cleanup?.jobTerminated === true &&
      result.job?.cleanup?.activeProcesses === 0 &&
      !result.job?.cleanupError;
    result.cleanup.ownershipProven = ownershipProven;
    if (options.injectFailure && options.injectionMarker) {
      try {
        result.lifecycleInjection = JSON.parse(await readFile(options.injectionMarker, "utf8"));
      } catch {
        /* No injection marker means the controlled worker never started. */
      }
    }
    if (scratch && !ownershipProven) {
      result.cleanup.retainedScratch = scratch;
      result.exitCode = 1;
    }
    if (scratch && ownershipProven) {
      let cleanupTimer;
      try {
        result.workerLog = options.report.replace(/\.json$/, ".worker.log");
        await writeFile(result.workerLog, await readFile(path.join(scratch, "worker.log")));
        await Promise.race([
          rm(scratch, { recursive: true, force: true, maxRetries: 3, retryDelay: 100 }),
          new Promise((_, reject) => {
            cleanupTimer = setTimeout(
              () => reject(new Error("Profile/cache cleanup exceeded 5000ms")),
              5000,
            );
          }),
        ]);
        result.cleanup.profileAndCacheRemoved = true;
      } catch (error) {
        result.cleanup.error = textError(error);
        result.cleanup.retainedScratch = scratch;
        result.exitCode = 1;
      } finally {
        clearTimeout(cleanupTimer);
      }
    }
    result.durationMs = performance.now() - started;
    if (result.durationMs >= options.overallMs) {
      result.error ??= `Overall deadline ${options.overallMs}ms exceeded including cleanup`;
      result.exitCode = 1;
    }
    let report = {
      schemaVersion: 1,
      runner: "native-panel controlled browser",
      warnMs: 30000,
      maxMs: options.overallMs,
      processDurationMs: result.durationMs,
      result,
      tests: [
        {
          name: `${options.mode} browser regression`,
          suite:
            options.mode === "workbench"
              ? "native-workbench.browser-test.tsx"
              : options.mode === "native-tree"
                ? "native-tree.browser-test.tsx"
                : ["form-grid", "controls-input"].includes(options.mode)
                  ? "native-form-grid.browser-test.tsx"
                  : "native-panel.browser-test.tsx",
          status: result.exitCode === 0 ? "passed" : "failed",
          durationMs: result.durationMs,
          message: result.error ?? result.cleanup.error,
        },
        ...(result.evidence?.component?.snapshots ?? []).map((stage) => ({
          name: stage.name,
          suite:
            options.mode === "workbench"
              ? "native-workbench workflow"
              : options.mode === "native-tree"
                ? "native-tree keyboard"
                : ["form-grid", "controls-input"].includes(options.mode)
                  ? options.mode === "controls-input"
                    ? "native-controls input"
                    : "native-form grid"
                  : "native-panel geometry",
          status: "passed",
          durationMs: stage.durationMs,
        })),
      ],
    };
    if (options.mode === "lifecycle") {
      // Preserve the expected red report separately. Only positive assertions
      // about that failure and its cleanup enter the lifecycle pass totals.
      const expectedCode = options.injectFailure === "worker-exit" ? 17 : 124;
      report.expectedFailure = { injection: options.injectFailure, workerExitCode: expectedCode };
      const expectedReport = path.join(
        path.dirname(options.report),
        "expected-failures",
        path.basename(options.report),
      );
      await mkdir(path.dirname(expectedReport), { recursive: true });
      await writeFile(expectedReport, JSON.stringify(report, null, 2));
      writeTestReportArtifacts(expectedReport);
      const assertions = {
        "runner fails closed": result.exitCode === 1 && !!result.error,
        "injected worker and descendant started":
          Number.isInteger(result.lifecycleInjection?.workerPid) &&
          Number.isInteger(result.lifecycleInjection?.descendantPid) &&
          result.lifecycleInjection.workerPid !== result.lifecycleInjection.descendantPid,
        "expected worker failure observed":
          result.job?.exitCode === expectedCode &&
          result.job?.status === "failed" &&
          result.supervisorExit?.code === 1,
        "job proves owned descendants terminated":
          result.cleanup.ownershipProven === true && result.job?.cleanup?.totalProcesses >= 3,
        "owned profile and cache removed":
          result.cleanup.profileAndCacheRemoved === true && !result.cleanup.retainedScratch,
        "total deadline respected": result.durationMs < options.overallMs,
      };
      report = {
        schemaVersion: 1,
        runner: `native browser lifecycle ${options.injectFailure}`,
        warnMs: 30000,
        maxMs: options.overallMs,
        processDurationMs: result.durationMs,
        expectedFailureReport: expectedReport,
        result,
        assertions,
        tests: [
          {
            name: "bounded injected worker lifecycle",
            suite: `native browser lifecycle ${options.injectFailure}`,
            status: Object.values(assertions).every(Boolean) ? "passed" : "failed",
            durationMs: result.durationMs,
            message: Object.entries(assertions)
              .filter(([, passed]) => !passed)
              .map(([name]) => name)
              .join("; "),
          },
        ],
      };
      result.exitCode = Object.values(assertions).every(Boolean) ? 0 : 1;
    }
    await mkdir(path.dirname(options.report), { recursive: true });
    await writeFile(options.report, JSON.stringify(report, null, 2));
    writeTestReportArtifacts(options.report);
    console.log(JSON.stringify(result, null, 2));
    clearTimeout(hardTimer);
    // An abandoned timed-out promise must not keep a failed CLI alive.
    process.exit(result.exitCode);
  }
}
if (process.argv[2] === "--worker") await worker(JSON.parse(process.argv[3]));
else await main();
