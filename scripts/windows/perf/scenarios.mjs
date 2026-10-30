// Interaction scenarios. Each returns flat metrics, lower is better; budgets in
// budgets.json are keyed `<scenario>.<metric>`.
import {
  LARGE_FILE,
  LARGE_FILE_LINES,
  MODEL_COUNT,
  MODEL_DIRECTORY,
  SERVICE_COUNT,
  SERVICE_DIRECTORY,
  SMALL_FILE,
} from "./lib/fixture.mjs";
import { percentile, totalBlockingTime, frameSummary } from "./lib/stats.mjs";

const TYPED = "int total = orders.stream().mapToInt(Order::amount).sum();\nif (total > limit) log(\"over limit\");\n";
const TYPING_INTERVAL_MILLISECONDS = 80;
const KEY_REPEAT_INTERVAL_MILLISECONDS = 33;
const RECOLOR_DISTANCE_LINES = 300;
const THINKING_PAUSE = { keys: 8, pauseMilliseconds: 400 };
const EDITOR_LINES = ".monaco-editor .view-lines";
const TAB_SELECTOR = '[role="tab"]';
const QUICK_OPEN_INPUT = 'input[data-quick-open-input], [role="dialog"] input, [cmdk-input]';

const delay = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));

async function setupProject(harness) {
  await harness.loadApp();
  await harness.openProject();
}

const startup = {
  id: "startup",
  title: "Load the app to the welcome screen",
  async run(harness) {
    await harness.page.goto(harness.url, { waitUntil: "commit" });
    const startedAt = await harness.page.evaluate(() => performance.timeOrigin);
    await harness.openFolderButton().waitFor();
    const readyMs = (await harness.page.evaluate(() => performance.timeOrigin + performance.now())) - startedAt;
    await harness.quiet();
    const counters = await harness.counters();
    const commands = await harness.host("commandCounts()");
    const tasks = await harness.page.evaluate(() => window.__LITHE_PERF__.longTasks);
    return {
      readyMs,
      tbtMs: totalBlockingTime(tasks),
      heapMb: counters.heapMb,
      domNodes: counters.domNodes,
      // The mock store starts empty, so its first-run defaults are not startup work.
      ipcCalls:
        Object.values(commands).reduce((sum, calls) => sum + calls, 0) - (commands["plugin:store|set"] ?? 0),
    };
  },
};

const openProject = {
  id: "openProject",
  title: "Open a project from the welcome screen",
  async run(harness) {
    await harness.loadApp();
    await harness.quiet();
    await harness.host("resetCounts()");
    const openMs = await harness.inputToShown(
      () => harness.openFolderButton().click(),
      '[data-file-path]',
    );
    await harness.quiet();
    const commands = await harness.host("commandCounts()");
    return { openMs, ipcCalls: Object.values(commands).reduce((sum, calls) => sum + calls, 0) };
  },
};

const typing = {
  id: "typing",
  title: "Type into a 200-line Java file",
  async run(harness) {
    await setupProject(harness);
    const openMs = await harness.openFile(SMALL_FILE);
    await harness.quiet();
    await harness.goToLine(100);
    return { openMs, ...(await harness.typeMeasured(TYPED, TYPING_INTERVAL_MILLISECONDS)) };
  },
};

const typingLarge = {
  id: "typingLarge",
  title: `Type into a ${LARGE_FILE_LINES}-line Java file`,
  async run(harness) {
    await setupProject(harness);
    const openMs = await harness.openFile(LARGE_FILE);
    await harness.quiet();
    await harness.goToLine(Math.floor(LARGE_FILE_LINES / 2));
    return { openMs, ...(await harness.typeMeasured(TYPED, TYPING_INTERVAL_MILLISECONDS)) };
  },
};

const typingBursts = {
  id: "typingBursts",
  title: `Type in bursts with short pauses in a ${LARGE_FILE_LINES}-line Java file`,
  async run(harness) {
    await setupProject(harness);
    await harness.openFile(LARGE_FILE);
    await harness.quiet();
    await harness.goToLine(Math.floor(LARGE_FILE_LINES / 2));
    return harness.typeMeasured(TYPED, TYPING_INTERVAL_MILLISECONDS, THINKING_PAUSE);
  },
};

// A text block stays open to the end of the file, unlike a block comment, which
// the next Javadoc in the fixture would close.
const textBlockRecolor = {
  id: "textBlockRecolor",
  title: "Open and close a text block far above the viewport while typing",
  async run(harness) {
    await setupProject(harness);
    await harness.openFile(LARGE_FILE);
    await harness.quiet();
    const edited = Math.floor(LARGE_FILE_LINES / 2);
    const below = edited + RECOLOR_DISTANCE_LINES;
    await harness.goToLine(below);
    const colored = await harness.multiColorLines();
    if (colored === 0) throw new Error("The fixture shows no multi-color lines to compare");

    await harness.goToLine(edited);
    await harness.page.keyboard.press("Enter");
    // Fast enough that tokens from the first keys arrive after the next edit.
    await harness.page.keyboard.type('String s = """ unterminated', { delay: 25 });
    await harness.goToLine(below);
    const stillColored = await harness.settled(() => harness.multiColorLines(), (lines) => lines === 0);

    await harness.goToLine(edited);
    await harness.page.keyboard.press("Shift+ArrowDown");
    await harness.page.keyboard.press("Shift+End");
    await harness.page.keyboard.press("Delete");
    await harness.goToLine(below);
    const recolored = await harness.settled(() => harness.multiColorLines(), (lines) => lines === colored);
    return { stillColoredLines: stillColored, lostColorLines: colored - recolored };
  },
};

const keyRepeat = {
  id: "keyRepeat",
  title: `Auto-repeat a key in a ${LARGE_FILE_LINES}-line Java file`,
  async run(harness) {
    await setupProject(harness);
    await harness.openFile(LARGE_FILE);
    await harness.quiet();
    await harness.goToLine(Math.floor(LARGE_FILE_LINES / 3));
    return harness.typeMeasured("x".repeat(90), KEY_REPEAT_INTERVAL_MILLISECONDS);
  },
};

const scroll = {
  id: "scroll",
  title: `Wheel-scroll a ${LARGE_FILE_LINES}-line Java file`,
  async run(harness) {
    await setupProject(harness);
    await harness.openFile(LARGE_FILE);
    await harness.quiet();
    await harness.focusEditor();
    const refresh = await harness.refreshMilliseconds();
    await harness.startFrames();
    for (let notch = 0; notch < 120; notch += 1) {
      await harness.page.mouse.wheel(0, 120);
      await delay(refresh);
    }
    const { frames, tasks } = await harness.stopFrames();
    return { ...frameSummary(frames, refresh), tbtMs: totalBlockingTime(tasks) };
  },
};

const tabs = {
  id: "tabs",
  title: "Switch between open editor tabs",
  async run(harness) {
    await setupProject(harness);
    const names = Array.from({ length: MODEL_COUNT }, (_, index) => `Model${index}`);
    for (const name of names) await harness.openFile(`${MODEL_DIRECTORY}/${name}.java`);
    await harness.openFile(SMALL_FILE);
    await harness.quiet();
    const switches = [];
    for (let round = 0; round < 8; round += 1) {
      const name = names[round % names.length];
      switches.push(
        await harness.inputToShown(
          () => harness.page.locator(TAB_SELECTOR, { hasText: `${name}.java` }).first().click(),
          EDITOR_LINES,
          name,
        ),
      );
      await harness.quiet(150);
    }
    return { switchP50Ms: percentile(switches, 50), switchP95Ms: percentile(switches, 95) };
  },
};

// More files than the mounted editors, so the last opens reuse an editor. Each
// open waits for the file's own text: hidden editors' lines are already on screen.
const OPENED_FILE_COUNT = 12;
const MOUNTED_EDITOR_COUNT = 8;

const classNameOf = (fileName) => fileName.replace(".java", "");

// The tree sorts by name and renders only its first rows.
function firstServiceFiles(count) {
  return Array.from({ length: SERVICE_COUNT }, (_, index) => `Service${index}.java`)
    .sort()
    .slice(0, count);
}

const fileOpen = {
  id: "fileOpen",
  title: `Open ${OPENED_FILE_COUNT} files, past the mounted editor limit`,
  async run(harness) {
    await setupProject(harness);
    const opens = [];
    for (const name of firstServiceFiles(OPENED_FILE_COUNT)) {
      opens.push(await harness.openFileToText(`${SERVICE_DIRECTORY}/${name}`, classNameOf(name)));
      await harness.quiet(150);
    }
    const counters = await harness.counters();
    return {
      newEditorOpenP50Ms: percentile(opens.slice(1, MOUNTED_EDITOR_COUNT), 50),
      pastLimitOpenP50Ms: percentile(opens.slice(MOUNTED_EDITOR_COUNT), 50),
      pastLimitOpenP95Ms: percentile(opens.slice(MOUNTED_EDITOR_COUNT), 95),
      heapMb: counters.heapMb,
      domNodes: counters.domNodes,
    };
  },
};

const projectTree = {
  id: "projectTree",
  title: `Browse a folder of ${SERVICE_COUNT} files in the project tree`,
  async run(harness) {
    await setupProject(harness);
    await harness.revealRow(`${SERVICE_DIRECTORY}/Service0.java`).catch(() => {});
    await harness.quiet();
    const refresh = await harness.refreshMilliseconds();
    await harness.page.locator('[data-file-path]').last().hover();
    await harness.startFrames();
    for (let notch = 0; notch < 60; notch += 1) {
      await harness.page.mouse.wheel(0, 120);
      await delay(refresh);
    }
    const { frames, tasks } = await harness.stopFrames();
    return { ...frameSummary(frames, refresh), tbtMs: totalBlockingTime(tasks) };
  },
};

const quickOpen = {
  id: "quickOpen",
  title: `Find a file among ${SERVICE_COUNT} with quick open`,
  async run(harness) {
    await setupProject(harness);
    await harness.quiet(800);
    const openMs = await harness.inputToShown(() => harness.page.keyboard.press("Control+p"), QUICK_OPEN_INPUT);
    await harness.quiet(150);
    const queryMs = await harness.inputToShown(
      () => harness.page.keyboard.type("Service777"),
      '[role="dialog"], [cmdk-root]',
      "Service777.java",
    );
    return { openMs, queryMs };
  },
};

const commandPalette = {
  id: "commandPalette",
  title: "Open the command palette and filter it",
  async run(harness) {
    await setupProject(harness);
    await harness.quiet(800);
    const openMs = await harness.inputToShown(() => harness.page.keyboard.press("Control+Shift+p"), QUICK_OPEN_INPUT);
    await harness.quiet(150);
    await harness.page.keyboard.type("settings", { delay: 40 });
    await harness.quiet(150);
    return { openMs };
  },
};

const leaks = {
  id: "leaks",
  title: "Reopen a file repeatedly and compare memory",
  async run(harness) {
    await setupProject(harness);
    const collect = async () => {
      await harness.cdp.send("HeapProfiler.collectGarbage");
      await harness.quiet(150);
      return harness.counters();
    };
    const cycle = async () => {
      await harness.openFile(SMALL_FILE);
      await harness.quiet(150);
      await harness.focusEditor();
      await harness.page.keyboard.press("Control+w");
      await harness.quiet(150);
    };
    await cycle();
    await cycle();
    const before = await collect();
    for (let round = 0; round < 8; round += 1) await cycle();
    const after = await collect();
    return {
      heapGrowthMb: after.heapMb - before.heapMb,
      domNodeGrowth: after.domNodes - before.domNodes,
      listenerGrowth: after.listeners - before.listeners,
    };
  },
};

export const SCENARIOS = [
  startup,
  openProject,
  typing,
  typingLarge,
  typingBursts,
  textBlockRecolor,
  keyRepeat,
  scroll,
  tabs,
  fileOpen,
  projectTree,
  quickOpen,
  commandPalette,
  leaks,
];
