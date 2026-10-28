/** Controlled component regression, not product or ui:3 package admission.
 * Example (no installation or download is performed by this runner):
 * node scripts/test-windows-native-plugin-ui-browser.mjs --browser msedge
 *   --playwright-module <Python Playwright 1.60.0>/driver/package/index.mjs
 *   --report .artifacts/native-browser/edge.json
 * Omit --playwright-module only when playwright is installed by repo configuration.
 * --step-timeout-ms defaults to 60000; --timeout-ms defaults to 120000
 * (minimum 25000, including a 20000ms cleanup reserve).
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
        optimizeDeps: { entries: ["src/features/plugins/native-ui/native-panel.browser-test.tsx"] },
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
              const { testNativeActionGroupLayout } = await import('/src/features/plugins/native-ui/native-panel.browser-test.tsx');
              window.runNativePanelTest = () => testNativeActionGroupLayout(document.getElementById('probe'));
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
    evidence.component = await step("six-stage component regression", () =>
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
    if (evidence.component?.snapshots?.length !== 6 && !evidence.error)
      throw new Error("Expected six geometry stages");
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
    const report = {
      schemaVersion: 1,
      runner: "native-panel controlled browser",
      warnMs: 30000,
      maxMs: options.overallMs,
      processDurationMs: result.durationMs,
      result,
      tests: [
        {
          name: "six-stage native action group browser regression",
          suite: "native-panel.browser-test.tsx",
          status: result.exitCode === 0 ? "passed" : "failed",
          durationMs: result.durationMs,
          message: result.error ?? result.cleanup.error,
        },
        ...(result.evidence?.component?.snapshots ?? []).map((stage) => ({
          name: stage.name,
          suite: "native-panel geometry",
          status: "passed",
          durationMs: stage.durationMs,
        })),
      ],
    };
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
