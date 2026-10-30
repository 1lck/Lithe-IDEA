// Drives the production Windows frontend in Chromium against the in-page mock
// host. Every wait has its own deadline, so a broken scenario fails with the
// step it was on instead of hanging the run.
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { PROJECT_ROOT } from "./fixture.mjs";
import { keySummary, totalBlockingTime } from "./stats.mjs";

const STEP_TIMEOUT_MILLISECONDS = 30_000;
const SETTLE_TIMEOUT_MILLISECONDS = 8_000;
const SETTLE_POLL_MILLISECONDS = 100;
const TREE_ROW = "[data-file-path]";
const EDITOR_LINES = ".monaco-editor .view-lines";
const OPEN_FOLDER_BUTTON = /^(Open|打开)$/;

const delay = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));
const normalized = (path) => path.replaceAll("\\", "/");

export class Harness {
  constructor(context, page, cdp) {
    this.context = context;
    this.page = page;
    this.cdp = cdp;
    this.pageErrors = [];
    page.on("pageerror", (error) => {
      // Monaco cancels in-flight work on dispose and leaves the rejection unhandled.
      if (error.message !== "Canceled") this.pageErrors.push(String(error.stack ?? error));
    });
  }

  static async launch(browser, { url, fixtureScript, cpuThrottle, profile = false }) {
    const context = await browser.newContext({
      viewport: { width: 1440, height: 900 },
      locale: "en-US",
      // The frontend chooses its keymap and path handling from the platform.
      userAgent:
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36",
    });
    // Update checks and other remote calls would make timings depend on the network.
    await context.route(
      (target) => !target.href.startsWith(url),
      (route) => route.abort(),
    );
    const directory = import.meta.dirname;
    await context.addInitScript({ content: "Object.defineProperty(navigator, 'platform', { get: () => 'Win32' });" });
    await context.addInitScript({ content: fixtureScript });
    await context.addInitScript({ path: join(directory, "mock-tauri-host.js") });
    await context.addInitScript({ path: join(directory, "in-page-probe.js") });
    const page = await context.newPage();
    page.setDefaultTimeout(STEP_TIMEOUT_MILLISECONDS);
    const cdp = await context.newCDPSession(page);
    await cdp.send("Performance.enable");
    if (profile) await cdp.send("Profiler.enable");
    if (cpuThrottle > 1) await cdp.send("Emulation.setCPUThrottlingRate", { rate: cpuThrottle });
    const harness = new Harness(context, page, cdp);
    harness.url = url;
    harness.profiling = profile;
    return harness;
  }

  async close() {
    await this.context.close();
  }

  async counters() {
    const { metrics } = await this.cdp.send("Performance.getMetrics");
    const value = (name) => metrics.find((metric) => metric.name === name)?.value ?? 0;
    return {
      taskMs: value("TaskDuration") * 1_000,
      scriptMs: value("ScriptDuration") * 1_000,
      styleLayoutMs: (value("LayoutDuration") + value("RecalcStyleDuration")) * 1_000,
      heapMb: value("JSHeapUsedSize") / 1_048_576,
      domNodes: value("Nodes"),
      listeners: value("JSEventListeners"),
    };
  }

  host(expression) {
    return this.page.evaluate(`window.__LITHE_PERF_HOST__.${expression}`);
  }

  async refreshMilliseconds() {
    return this.page.evaluate(
      () =>
        new Promise((resolve) => {
          const stamps = [];
          const tick = (time) => {
            stamps.push(time);
            if (stamps.length < 31) requestAnimationFrame(tick);
            else {
              const gaps = stamps.slice(1).map((stamp, index) => stamp - stamps[index]);
              resolve(gaps.sort((a, b) => a - b)[Math.floor(gaps.length / 2)]);
            }
          };
          requestAnimationFrame(tick);
        }),
    );
  }

  /** Waits until a long-task-free window passes, so a measurement starts from idle. */
  quiet(quietMilliseconds = 400) {
    return this.page.evaluate(
      ([quiet, timeout]) => window.__LITHE_PERF__.waitQuiet(quiet, timeout),
      [quietMilliseconds, STEP_TIMEOUT_MILLISECONDS],
    );
  }

  /** Time from the input `act` performs to the first frame that shows the target. */
  async inputToShown(act, selector, text = null) {
    await this.page.evaluate(() => window.__LITHE_PERF__.arm());
    const shown = this.page.evaluate(
      ([target, label, timeout]) => window.__LITHE_PERF__.waitShown(target, label, timeout),
      [selector, text, STEP_TIMEOUT_MILLISECONDS],
    );
    await act();
    return shown;
  }

  openFolderButton() {
    return this.page.getByRole("button", { name: OPEN_FOLDER_BUTTON }).last();
  }

  async loadApp() {
    await this.page.goto(this.url, { waitUntil: "load" });
    await this.openFolderButton().waitFor();
  }

  async openProject() {
    await this.openFolderButton().click();
    await this.page.locator(`[data-path="${PROJECT_ROOT}"]`).first().waitFor();
    await this.quiet();
  }

  async visibleRows() {
    return this.page.locator(TREE_ROW).evaluateAll((rows) => rows.map((row) => row.getAttribute("data-path")));
  }

  rowSelector(path) {
    return `[data-path="${path.replaceAll("\\", "\\\\")}"]`;
  }

  /** Expands the tree towards `relative`; compact package rows may skip levels. */
  async revealRow(relative) {
    const target = `${PROJECT_ROOT}/${relative}`;
    const expanded = new Set();
    for (let step = 0; step < 16; step += 1) {
      const rows = await this.visibleRows();
      const exact = rows.find((row) => normalized(row) === target);
      if (exact) return exact;
      const parent = rows
        .filter((row) => !expanded.has(row) && target.startsWith(`${normalized(row)}/`))
        .sort((a, b) => b.length - a.length)[0];
      if (!parent) throw new Error(`No tree row leads to ${relative}; visible: ${rows.slice(0, 12).join(", ")}`);
      expanded.add(parent);
      await this.page.locator(this.rowSelector(parent)).first().click();
      await this.page.keyboard.press("ArrowRight");
      await this.page
        .waitForFunction((count) => document.querySelectorAll("[data-file-path]").length > count, rows.length, {
          timeout: 5_000,
        })
        .catch(() => {});
    }
    throw new Error(`Could not reveal ${relative}`);
  }

  async openFile(relative) {
    const row = await this.revealRow(relative);
    const name = relative.slice(relative.lastIndexOf("/") + 1);
    const milliseconds = await this.inputToShown(
      () => this.page.locator(this.rowSelector(row)).first().dblclick(),
      `${EDITOR_LINES}`,
      null,
    );
    await this.page.getByText(name, { exact: true }).first().waitFor();
    return milliseconds;
  }

  async focusEditor() {
    // The line layer scrolls away with the content; the guard stays in the viewport.
    await this.page.locator(".monaco-editor .overflow-guard").first().click({ position: { x: 300, y: 200 } });
  }

  async goToLine(line) {
    await this.focusEditor();
    await this.page.keyboard.press("Control+g");
    await this.page.keyboard.type(String(line));
    await this.page.keyboard.press("Enter");
    await this.quiet();
    await this.page.keyboard.press("End");
  }

  /** Polls `read` until `done` accepts its value or the deadline passes, returning the last value. */
  async settled(read, done) {
    const deadline = performance.now() + SETTLE_TIMEOUT_MILLISECONDS;
    let value = await read();
    while (!done(value) && performance.now() < deadline) {
      await delay(SETTLE_POLL_MILLISECONDS);
      value = await read();
    }
    return value;
  }

  /** Counts the visible lines whose code renders in more than one token color. */
  async multiColorLines() {
    return this.page.evaluate((selector) => {
      const lines = [...document.querySelector(selector).querySelectorAll(".view-line")];
      return lines.filter((line) => {
        const colors = new Set([...line.querySelectorAll("span > span")].map((span) => span.className));
        return colors.size > 1;
      }).length;
    }, EDITOR_LINES);
  }

  /**
   * Types `text` at one key per `intervalMilliseconds`, keeping to a fixed
   * schedule. `burst` adds a thinking pause after that many keys, the rhythm that
   * lets debounced work such as autosave fire.
   */
  async typeMeasured(text, intervalMilliseconds, burst = null) {
    const refresh = await this.refreshMilliseconds();
    await this.page.evaluate(() => {
      const probe = window.__LITHE_PERF__;
      probe.keyLatencies.length = 0;
      probe.longTasks.length = 0;
      probe.recordKeys = true;
    });
    await this.host("resetCounts()");
    const before = await this.counters();
    if (this.profiling) await this.cdp.send("Profiler.start");
    let due = performance.now();
    for (let index = 0; index < text.length; index += 1) {
      const character = text[index];
      if (character === "\n") await this.page.keyboard.press("Enter");
      else await this.page.keyboard.type(character);
      due += intervalMilliseconds;
      if (burst && (index + 1) % burst.keys === 0) due += burst.pauseMilliseconds;
      const wait = due - performance.now();
      if (wait > 0) await delay(wait);
    }
    await this.page.evaluate(() => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))));
    const after = await this.counters();
    if (this.profiling) this.cpuProfile = (await this.cdp.send("Profiler.stop")).profile;
    const { latencies, tasks } = await this.page.evaluate(() => {
      const probe = window.__LITHE_PERF__;
      probe.recordKeys = false;
      return { latencies: [...probe.keyLatencies], tasks: [...probe.longTasks] };
    });
    // Autosave fires shortly after the last key; let it finish so its cost is counted.
    await delay(400);
    const commands = await this.host("commandCounts()");
    const payloadBytes = await this.host("payloadBytes()");
    this.payloadByCommand = await this.host("payloadByCommand()");
    const keys = text.length;
    return {
      ...keySummary(latencies, refresh),
      mainThreadMsPerKey: (after.taskMs - before.taskMs) / keys,
      scriptMsPerKey: (after.scriptMs - before.scriptMs) / keys,
      styleLayoutMsPerKey: (after.styleLayoutMs - before.styleLayoutMs) / keys,
      tbtMs: totalBlockingTime(tasks),
      saves: commands.save_document_file ?? 0,
      ipcPerKey: Object.entries(commands)
        .filter(([command]) => !command.startsWith("core:") && !command.startsWith("platform_invoke:") && command !== "frontend_trace")
        .reduce((sum, [, calls]) => sum + calls, 0) / keys,
      ipcKilobytesPerKey: payloadBytes / 1_024 / keys,
    };
  }

  async startFrames() {
    await this.page.evaluate(() => {
      window.__LITHE_PERF__.longTasks.length = 0;
      window.__LITHE_PERF__.startFrames();
    });
  }

  async stopFrames() {
    return this.page.evaluate(() => ({
      frames: window.__LITHE_PERF__.stopFrames(),
      tasks: [...window.__LITHE_PERF__.longTasks],
    }));
  }
}

export function fixtureScript(fixture) {
  return `window.__LITHE_PERF_FIXTURE__ = ${JSON.stringify(fixture)};`;
}

export function initialBundleKilobytes(distDirectory) {
  const html = readFileSync(join(distDirectory, "index.html"), "utf8");
  const assets = [...html.matchAll(/(?:src|href)="\/?(assets\/[^"]+\.(js|css))"/g)];
  const size = (extension) =>
    assets
      .filter((match) => match[2] === extension)
      .reduce((sum, match) => sum + readFileSync(join(distDirectory, match[1])).length, 0) / 1_024;
  return { initialJsKb: size("js"), initialCssKb: size("css") };
}
