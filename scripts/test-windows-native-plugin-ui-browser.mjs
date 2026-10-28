/** Controlled component regression, not product or ui:3 package admission.
 * Example (no installation or download is performed by this runner):
 * node scripts/test-windows-native-plugin-ui-browser.mjs --browser msedge
 *   --playwright-module <Python Playwright 1.60.0>/driver/package/index.mjs
 *   --report .artifacts/native-browser/edge.json
 * Omit --playwright-module only when playwright is installed by repo configuration.
 * --step-timeout-ms defaults to 60000; --timeout-ms defaults to 120000
 * (minimum 25000, including a 20000ms cleanup reserve).
 * --mode native-tree drives real browser keyboard/menu/focus regressions.
 * --mode lifecycle --inject-failure worker-exit|worker-hang verifies fail-closed
 * cleanup without Vite/browser dependencies; expected red reports are separate.
 */
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
  let server, context;
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
          entries: [
            options.mode === "native-tree"
              ? "src/features/plugins/native-ui/native-tree.browser-test.tsx"
              : "src/features/plugins/native-ui/native-panel.browser-test.tsx",
          ],
        },
        server: { port: 0, host: "127.0.0.1", open: false },
        plugins: [
          {
            name: "native-panel-browser-regression",
            configureServer(vite) {
              vite.middlewares.use("/native-panel-test.html", async (_request, response, next) => {
                try {
                  const html = await vite.transformIndexHtml(
                    "/native-panel-test.html",
                    `<html><body><div id="probe"></div><script type="module">
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
                options.mode === "native-tree"
                  ? `
              const { mountNativeTreeBrowserTest } = await import('/src/features/plugins/native-ui/native-tree.browser-test.tsx');
              window.nativeTreeProbe = mountNativeTreeBrowserTest(document.getElementById('probe'));
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
    const page = await step("create page", () => context.newPage());
    page.setDefaultTimeout(options.stepMs);
    page.on("pageerror", (error) => evidence.pageErrors.push(textError(error)));
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
      options.mode === "native-tree"
        ? await nativeTreeRegression(page, step)
        : await step("six-stage component regression", () =>
            page.evaluate(() => window.runNativePanelTest()),
          );
    evidence.windowErrors = await step("collect window errors", () =>
      page.evaluate(() => window.nativePanelWindowErrors),
    );
    evidence.bootstrapIPC = await step("collect mock IPC", () =>
      page.evaluate(() => window.bootstrapIPC),
    );
    if (evidence.windowErrors.length || evidence.pageErrors.length)
      throw new Error(
        JSON.stringify({ windowErrors: evidence.windowErrors, pageErrors: evidence.pageErrors }),
      );
  } catch (error) {
    evidence.error = textError(error);
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
    if (!["action-group", "native-tree", "lifecycle"].includes(options.mode))
      throw new Error("mode must be action-group, native-tree or lifecycle");
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
      evidence.component?.snapshots?.length !== (options.mode === "native-tree" ? 7 : 6) &&
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
            options.mode === "native-tree"
              ? "native-tree.browser-test.tsx"
              : "native-panel.browser-test.tsx",
          status: result.exitCode === 0 ? "passed" : "failed",
          durationMs: result.durationMs,
          message: result.error ?? result.cleanup.error,
        },
        ...(result.evidence?.component?.snapshots ?? []).map((stage) => ({
          name: stage.name,
          suite: options.mode === "native-tree" ? "native-tree keyboard" : "native-panel geometry",
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
