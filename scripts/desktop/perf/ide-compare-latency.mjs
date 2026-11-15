#!/usr/bin/env node
// Times how fast Lithe and other editors answer Go code navigation and typing on macOS, the way a
// user sees it: from the key press to the frame on the display. It goes with ide-compare.mjs, which
// compares the resources they use, and sets every editor up the same way (--go: Lithe with the Go
// plugin --lithe-plugin names, Zed with its built-in Go support, GoLand as it ships, each in a new
// profile).
//
// Usage:
//   node scripts/desktop/perf/ide-compare-latency.mjs run --go FILE [--ides lithe,zed,goland]
//        [--source DIR] [--name NAME] [--revision REV] [--reps N] [--ready-timeout SECONDS]
//        [--targets FILE] [--out DIR] [--work DIR] [--keep-work] [--lithe-plugin ID]
//   node scripts/desktop/perf/ide-compare-latency.mjs report RESULTS.json
//
// run     Clones the project for each editor in turn, opens it with FILE and waits until the editor
//         is ready: the processor has gone quiet as in ide-compare.mjs, or for GoLand 30 seconds
//         after it left indexing, or --ready-timeout (default 600) has passed. Then it brings the
//         editor's window to the front and, --reps times (default 5) each, presses Go to Definition
//         and Find References and rests the mouse pointer on a word for its hover, every time after
//         opening FILE through the editor's file search and moving the caret with its Go to Line;
//         then it types ten letters at the end of a comment, deletes them with Backspace and saves,
//         so the file is as it was. ide-compare-input-macos.swift presses the keys, moves the
//         pointer and records the window; each press is timed to the first frame that changed
//         ("first response") and to the last change before the window stayed still for a second
//         ("settled"; for typing a short pause is enough).
//
//         Hover is the pointer's in every editor, because Lithe has no other key for it than F1, and
//         F1 can belong to another application. To find the word on screen, the caret, put inside
//         it, is moved one character right and back with the arrow keys, which changes nothing in
//         the file: the character it crossed is where the window changed, above the status bar. The
//         pointer waits in the middle of the title bar between operations. For a hover it comes,
//         as a mouse does, along the line from the left: it rests VIA_MS (shorter than any editor's
//         hover delay) two characters before that one, on the same line and so always on text, and
//         then moves onto it; the time runs from the pointer reaching the character, so it
//         includes the delay each editor waits before it shows a hover (HOVER_DELAYS). When the
//         caret cannot be found three times running, that round is recorded as failed, with a
//         picture of the window, and the next round goes on.
//         Lithe and Zed start gopls through ide-compare-lsp-proxy.mjs, which logs every message,
//         so the time gopls itself took for each request is reported next to the screen time, with
//         the requests each editor sent over the session and the settings it gave gopls. The proxy
//         is a script in the profile: Zed is told its path in its settings, and Lithe finds it first
//         on PATH (with LITHE_SKIP_SHELL_ENV=1 and this script's PATH and Go variables, because
//         Lithe would otherwise put the login shell's PATH, with the real gopls, in front).
//
// The terminal running this script needs Accessibility (System Settings → Privacy & Security →
// Accessibility) to press keys and Screen Recording to record the window. The keyboard input
// source is switched to ABC for the run and back at the end. The caret is told not to blink in
// every editor, because a blinking caret would count as a change. Nothing may use the keyboard or
// the mouse while it runs: a key is only pressed, and the pointer only moved, while the editor owns
// the frontmost window, and the run waits and starts the operation over when it does not.
//
// --targets FILE is a JSON object like DEFAULT_TARGETS below, for another project than the two
// built in (this repository and Kubernetes).
import { spawn, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import readline from 'node:readline';
import { fileURLToPath } from 'node:url';
import {
  IDES,
  alive,
  buildSampler,
  bundleVersion,
  cloneProject,
  findApp,
  fmtMs,
  goInfo,
  log,
  machineInfo,
  median,
  removeTree,
  run1,
  runningCopies,
  sleep,
  summarize,
  sweep,
  table,
  terminate,
  writeJson,
} from './ide-compare.mjs';

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const ROOT_DIR = path.resolve(SCRIPT_DIR, '../../..');
const DRIVER_SOURCE = path.join(SCRIPT_DIR, 'ide-compare-input-macos.swift');
const PROXY_SOURCE = path.join(SCRIPT_DIR, 'ide-compare-lsp-proxy.mjs');
const ABC_INPUT_SOURCE = 'com.apple.keylayout.ABC';
const OPS = ['definition', 'hover', 'references'];
const TYPED = 'lithebench';

// Where each operation is pressed: the first line containing `find`, with the caret inside `word`
// (or at the end of the line for typing, which is in a comment so the code stays valid).
const DEFAULT_TARGETS = {
  'Lithe-IDEA': {
    file: 'desktop/internal/workbench/app.go',
    definition: { find: 'core.NewOperation()', word: 'NewOperation' },
    hover: { find: 'a.logSink.Emit(', word: 'Emit' },
    references: { find: 'func (a *App) performed(', word: 'performed' },
    typing: { find: "// emit writes one of the window's own events" },
  },
  kubernetes: {
    file: 'pkg/kubelet/kubelet.go',
    definition: { find: 'features.EventedPLEG)', word: 'EventedPLEG' },
    hover: { find: 'utilfeature.DefaultFeatureGate.Enabled(features.ReduceDefaultCrashLoopBackOffDecay)', word: 'DefaultFeatureGate' },
    references: { find: 'features.InPlacePodVerticalScaling)', word: 'InPlacePodVerticalScaling' },
    typing: { find: '// EventedPLEG only watches the CRI event stream' },
  },
};

// The default macOS key bindings of each editor. column says how Go to Line counts a tab: as one
// character, or as the columns up to the next multiple of the tab size. Hover has no key: see the
// header.
const KEYMAPS = {
  lithe: {
    quickOpen: [{ key: 'o', mods: ['cmd', 'shift'] }],
    goToLine: [{ key: 'l', mods: ['cmd'] }],
    definition: [{ key: 'f12' }],
    references: [{ key: 'f12', mods: ['shift'] }],
    column: 'characters',
  },
  zed: {
    quickOpen: [{ key: 'p', mods: ['cmd'] }],
    goToLine: [{ key: 'g', mods: ['ctrl'] }],
    definition: [{ key: 'f12' }],
    references: [{ key: 'f12', mods: ['alt', 'shift'] }],
    column: 'characters',
  },
  goland: {
    quickOpen: [{ key: 'o', mods: ['cmd', 'shift'] }],
    goToLine: [{ key: 'l', mods: ['cmd'] }],
    definition: [{ key: 'b', mods: ['cmd'] }],
    references: [{ key: 'f7', mods: ['alt'] }],
    column: 'tabs4',
  },
};
// The status bar, which shows the caret's column, is this tall or less in every editor.
const STATUS_BAR_POINTS = 40;
// How long the pointer rests two characters left of the word before it moves onto it: shorter
// than every editor's hover delay, so no hover shows there.
const VIA_MS = 150;
// How many times the caret is placed and looked for before a hover round counts as failed.
const LOCATE_TRIES = 3;

// How long each editor waits, by default, with the pointer resting on a word before it shows the
// hover; the measured hover time includes it.
const HOVER_DELAYS = {
  lithe: { ms: 500, source: 'semanticHoverDelay（desktop/internal/workbench/pluginsemantics.go）' },
  zed: { ms: 300, source: 'hover_popover_delay 默认值' },
  goland: { ms: 500, source: '编辑器提示延迟默认值（约）' },
};

// The LSP method each operation sends, to find its request in the proxy's log.
const METHODS = { definition: 'textDocument/definition', hover: 'textDocument/hover', references: 'textDocument/references' };

// How long an operation may take before it counts as timed out, and how still the window has to
// be to count as settled.
const TIMEOUT_MS = { definition: 15000, hover: 15000, references: 90000 };
const SETTLED_QUIET_MS = 1000;
const TYPING_QUIET_MS = 150;
const MIN_PIXELS = 30;
const TYPING_MIN_PIXELS = 4;

async function main() {
  const [command, ...rest] = process.argv.slice(2);
  if (command === 'run') return latency(parseOptions(rest));
  if (command === 'report' && rest.length === 1) {
    process.stdout.write(renderReport(JSON.parse(fs.readFileSync(rest[0], 'utf8'))));
    return undefined;
  }
  process.stderr.write(
    'usage:\n' +
      '  ide-compare-latency.mjs run --go FILE [--ides lithe,zed,goland] [--source DIR] [--name NAME] [--revision REV]\n' +
      '                          [--reps N] [--ready-timeout SECONDS] [--targets FILE] [--out DIR] [--work DIR] [--keep-work]\n' +
      '  ide-compare-latency.mjs report RESULTS.json\n',
  );
  process.exitCode = 2;
  return undefined;
}

function parseOptions(args) {
  const options = {
    ides: ['lithe', 'zed', 'goland'],
    source: ROOT_DIR,
    name: null,
    revision: 'HEAD',
    reps: 5,
    readyTimeout: 600,
    targets: null,
    goFile: null,
    plugin: null,
    out: null,
    work: null,
    keepWork: false,
  };
  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    const value = () => {
      if (i + 1 >= args.length) throw new Error(`${arg} needs a value`);
      return args[++i];
    };
    if (arg === '--ides') options.ides = value().split(',').filter(Boolean);
    else if (arg === '--source') options.source = path.resolve(value());
    else if (arg === '--name') options.name = value();
    else if (arg === '--revision') options.revision = value();
    else if (arg === '--reps') options.reps = Number(value());
    else if (arg === '--ready-timeout') options.readyTimeout = Number(value());
    else if (arg === '--targets') options.targets = JSON.parse(fs.readFileSync(value(), 'utf8'));
    else if (arg === '--go') options.goFile = value();
    else if (arg === '--lithe-plugin') options.plugin = value();
    else if (arg === '--out') options.out = path.resolve(value());
    else if (arg === '--work') options.work = path.resolve(value());
    else if (arg === '--keep-work') options.keepWork = true;
    else throw new Error(`unknown option ${arg}`);
  }
  const unknown = options.ides.filter((id) => !KEYMAPS[id]);
  if (unknown.length > 0) throw new Error(`no key bindings for ${unknown.join(', ')}; known: ${Object.keys(KEYMAPS).join(', ')}`);
  if (!options.goFile) throw new Error('--go FILE is required');
  if (options.ides.includes('lithe') && !options.plugin) throw new Error('--lithe-plugin ID is required with Lithe: the ID of the Go plugin installed in Lithe');
  options.name ??= options.source === ROOT_DIR ? 'Lithe-IDEA' : path.basename(options.source);
  options.targets ??= DEFAULT_TARGETS[options.name];
  if (!options.targets) throw new Error(`no targets for ${options.name}; give --targets FILE`);
  if (options.targets.file !== options.goFile) throw new Error(`the targets are in ${options.targets.file}, not ${options.goFile}`);
  if (!(options.reps >= 1) || !(options.readyTimeout > 0)) throw new Error('--reps and --ready-timeout must be positive');
  options.out ??= path.join(ROOT_DIR, '.artifacts', 'ide-compare', `latency-${new Date().toISOString().replace(/[:.]/g, '-')}`);
  return options;
}

async function latency(options) {
  if (process.platform !== 'darwin') throw new Error('ide-compare-latency runs on macOS only');
  const running = options.ides.flatMap((id) => runningCopies(findApp(id, IDES[id]), IDES[id]).map((pid) => `${IDES[id].label} (pid ${pid})`));
  if (running.length > 0) throw new Error(`quit these editors before measuring: ${running.join(', ')}`);

  fs.mkdirSync(path.join(options.out, 'raw'), { recursive: true });
  const sampler = buildSampler(options.out);
  const driver = new Driver(buildDriver(options.out));
  const permissions = await driver.send({ op: 'permissions' });
  if (!permissions.accessibility || !permissions.screenCapture) {
    driver.close();
    throw new Error(
      `the terminal running this needs ${[!permissions.accessibility && 'Accessibility', !permissions.screenCapture && 'Screen Recording'].filter(Boolean).join(' and ')} ` +
        '(System Settings → Privacy & Security), then a restart of the terminal',
    );
  }
  const work = options.work ?? fs.mkdtempSync('/tmp/idel-');
  fs.mkdirSync(work, { recursive: true });
  options.workPaths = [...new Set([work, fs.realpathSync(work)])];
  const revision = run1('git', ['-C', options.source, 'rev-parse', options.revision]).trim();
  const go = goInfo(options.goFile);
  if (!go.goplsPath) throw new Error('gopls is not on PATH');
  options.goplsPath = go.goplsPath;
  const text = run1('git', ['-C', options.source, 'show', `${revision}:${options.goFile}`]);
  const results = {
    schema: 1,
    kind: 'latency',
    startedAt: new Date().toISOString(),
    machine: machineInfo(),
    project: { repository: options.name, revision },
    go,
    settings: { reps: options.reps, readyTimeoutSeconds: options.readyTimeout, settledQuietMs: SETTLED_QUIET_MS, minPixels: MIN_PIXELS },
    targets: resolveTargets(options.targets, text),
    ides: {},
  };
  const save = () => writeJson(path.join(options.out, 'results.json'), results);
  save();

  const previousInput = (await driver.send({ op: 'input-source', id: ABC_INPUT_SOURCE })).previous;
  log(`input source ${ABC_INPUT_SOURCE} (was ${previousInput})`);
  try {
    for (const id of options.ides) {
      const entry = { label: IDES[id].label };
      results.ides[id] = entry;
      try {
        await session(id, options, revision, results.targets, sampler, driver, work, entry);
      } catch (error) {
        entry.error = String(error.message ?? error);
        log(`${entry.label}: ${entry.error}`);
      }
      save();
      await sleep(15000);
    }
  } finally {
    await driver
      .send({ op: 'input-source', id: previousInput })
      .then(() => log(`input source ${previousInput} again`))
      .catch((error) => log(`input source ${previousInput} could not be selected again (${error.message}); select it by hand`));
    driver.close();
    results.finishedAt = new Date().toISOString();
    save();
    await sweep(options.workPaths, []);
    if (options.keepWork) log(`work:    ${work}`);
    else removeTree(work);
  }
  fs.writeFileSync(path.join(options.out, 'report.md'), renderReport(results));
  log(`results: ${path.join(options.out, 'results.json')}`);
  log(`report:  ${path.join(options.out, 'report.md')}`);
}

// session runs one editor: setup, launch, wait until ready, the operations, quit.
async function session(id, options, revision, targets, samplerBinary, driver, work, entry) {
  const ide = IDES[id];
  const keymap = KEYMAPS[id];
  const app = findApp(id, ide);
  const profile = path.join(work, id, 'profile');
  const project = path.join(work, id, options.name);
  cloneProject(options.source, revision, project);
  fs.mkdirSync(profile, { recursive: true });
  const setup = { project, goFile: options.goFile, plugin: options.plugin };
  ide.prepare(profile, setup);
  const lspLogs = path.join(work, id, 'lsp');
  const extra = prepareForLatency(id, profile, lspLogs, options.goplsPath);
  Object.assign(entry, { app, version: bundleVersion(app), note: extra.note });

  const rawFile = path.join(options.out, 'raw', `${id}-latency-samples.jsonl`);
  const raw = fs.createWriteStream(rawFile);
  const after = Date.now() * 1000;
  const samplerProcess = spawn(
    samplerBinary,
    ['--exe', path.join(app, ide.executable), '--after', String(after), '--interval', '500', '--duration', String(options.readyTimeout + 1800), '--find-timeout', '60'],
    { stdio: ['ignore', 'pipe', 'inherit'] },
  );
  const lines = [];
  readline.createInterface({ input: samplerProcess.stdout }).on('line', (line) => {
    raw.write(`${line}\n`);
    lines.push(JSON.parse(line));
  });
  const samplerExit = new Promise((resolve) => samplerProcess.on('close', resolve));

  const { env, args } = ide.launch(profile, project, setup);
  const openArgs = ['-n', '-a', app];
  for (const [key, value] of Object.entries({ ...env, ...extra.env })) openArgs.push('--env', `${key}=${value}`);
  openArgs.push('--args', ...args);
  const opened = spawnSync('open', openArgs, { encoding: 'utf8' });
  if (opened.status !== 0) {
    samplerProcess.kill();
    throw new Error(`open ${ide.label} failed: ${opened.stderr}`);
  }

  let root = null;
  try {
    const ready = await waitReady(ide, profile, project, lines, options.readyTimeout);
    root = ready.root;
    entry.ready = { ms: ready.ms, reason: ready.reason };
    log(`${ide.label}: ready after ${fmtMs(ready.ms)} (${ready.reason})`);
    await front(driver, root.pid);
    entry.disturbances = [];
    entry.window = await driver.send({ op: 'attach', pid: root.pid, timeoutMs: 180000 });
    log(`${ide.label}: recording window "${entry.window.title}" ${entry.window.w}x${entry.window.h}`);
    const ctx = { driver, pid: root.pid, app, keymap, targets, out: options.out, id, label: ide.label, disturbances: entry.disturbances, window: entry.window };
    entry.ops = {};
    for (const op of OPS) {
      entry.ops[op] = [];
      for (let rep = 1; rep <= options.reps; rep++) {
        const result = await operation(ctx, op, rep);
        entry.ops[op].push(result);
        log(`${ide.label} ${op} #${rep}: ${result.error ? `failed (${result.error})` : `first ${fmtMs(result.firstMs)}, settled ${fmtMs(result.settledMs)}${result.timedOut ? ' (timed out)' : ''}`}`);
      }
    }
    entry.typing = await typing(ctx);
    log(`${ide.label} typing: median first ${fmtMs(median(entry.typing.typed.map((t) => t.firstMs).filter(Number.isFinite)))}`);
  } finally {
    const last = lines.filter((line) => line.type === 'sample').pop();
    const pids = last ? last.list.map((p) => p.pid) : [];
    if (root) entry.killedAfterTimeout = await terminate(root.pid, pids, ide.quitSeconds);
    samplerProcess.kill('SIGTERM');
    await samplerExit;
    raw.end();
    await sweep(options.workPaths, pids);
    ide.finish?.(profile);
  }
  const samples = lines.filter((line) => line.type === 'sample');
  if (root && samples.length > 0) {
    const summary = summarize(samples, root.pid, Math.max(31, samples[samples.length - 1].tMs / 1000), path.basename(project));
    entry.resources = { peakFootprint: summary.peakFootprint, cpuSecondsTotal: summary.cpuSecondsTotal, breakdown: summary.breakdown.slice(0, 6) };
  }
  entry.projectChanged = spawnSync('git', ['-C', project, 'diff', '--quiet'], { encoding: 'utf8' }).status !== 0;
  if (fs.existsSync(lspLogs)) {
    entry.lsp = readLsp(lspLogs);
    // In the order they were pressed; a request belongs to the press before the next one.
    const pressed = OPS.flatMap((op) => (entry.ops?.[op] ?? []).map((result) => ({ op, result }))).sort((a, b) => a.result.sentAt - b.result.sentAt);
    pressed.forEach(({ op, result }, i) => {
      // A hover is the one asked for the target's line: the pointer may ask on its way there.
      const line = op === 'hover' ? targets.hover.line - 1 : undefined;
      if (!result.error) matchRequest(result, entry.lsp.messages, METHODS[op], pressed[i + 1]?.result.sentAt ?? result.sentAt + 60000, line);
    });
    delete entry.lsp.messages;
  }
}

// prepareForLatency adds what the latency run needs to a prepared profile: the caret does not
// blink, and gopls starts through the proxy.
function prepareForLatency(id, profile, lspLogs, real) {
  if (id === 'goland') {
    fs.writeFileSync(
      path.join(profile, 'config', 'options', 'editor.xml'),
      ['<application>', '  <component name="EditorSettings">', '    <option name="IS_CARET_BLINKING" value="false" />', '  </component>', '</application>', ''].join('\n'),
    );
    return { env: {}, note: 'caret blinking off' };
  }
  fs.mkdirSync(lspLogs, { recursive: true });
  const bin = path.join(profile, 'lsp-bin');
  const wrapper = path.join(bin, 'gopls');
  const quote = (value) => {
    if (value.includes("'")) throw new Error(`cannot quote ${value}`);
    return `'${value}'`;
  };
  fs.mkdirSync(bin, { recursive: true });
  fs.writeFileSync(
    wrapper,
    `#!/bin/sh\nexec ${quote(process.execPath)} ${quote(PROXY_SOURCE)} --real ${quote(real)} --log ${quote(path.join(lspLogs, 'gopls-%p.jsonl'))} -- "$@"\n`,
    { mode: 0o755 },
  );
  if (id === 'zed') {
    const file = path.join(profile, 'data', 'config', 'settings.json');
    const settings = JSON.parse(fs.readFileSync(file, 'utf8'));
    settings.cursor_blink = false;
    settings.lsp = { gopls: { binary: { path: wrapper, arguments: ['-mode=stdio'] } } };
    writeJson(file, settings);
    return { env: {}, note: 'cursor_blink off; gopls through the proxy (lsp.gopls.binary)' };
  }
  const file = path.join(profile, 'Library', 'Application Support', 'Lithe Desktop', 'settings.json');
  const settings = JSON.parse(fs.readFileSync(file, 'utf8'));
  settings.editorPreferences = { ...(settings.editorPreferences ?? {}), cursorBlink: false };
  writeJson(file, settings);
  const env = { LITHE_SKIP_SHELL_ENV: '1', PATH: `${bin}:${process.env.PATH}` };
  for (const name of ['GOPATH', 'GOROOT', 'GOFLAGS', 'GOPROXY', 'GOPRIVATE', 'GONOSUMDB', 'GONOPROXY', 'GOTOOLCHAIN', 'GOENV']) {
    if (process.env[name]) env[name] = process.env[name];
  }
  return { env, note: `cursor blink off; gopls through the proxy (PATH, LITHE_SKIP_SHELL_ENV=1, ${Object.keys(env).filter((k) => k.startsWith('GO')).join(', ')})` };
}

// waitReady waits for the instance and then until it is ready (see the header).
async function waitReady(ide, profile, project, lines, readyTimeoutSeconds) {
  const started = Date.now();
  let smartSeenAt = null;
  for (;;) {
    await sleep(2000);
    const root = lines.find((line) => line.type === 'root');
    const samples = lines.filter((line) => line.type === 'sample');
    const elapsed = Date.now() - started;
    if (root && samples.length > 12) {
      const summary = summarize(samples, root.pid, 31, path.basename(project));
      if (summary.settleMs !== null) return { root, ms: summary.settleMs, reason: 'processor quiet' };
      const smart = ide.go?.smartMs?.(profile, path.basename(project));
      if (smart != null && smartSeenAt === null) smartSeenAt = Date.now();
      if (smartSeenAt !== null && Date.now() - smartSeenAt >= 30000) return { root, ms: samples[samples.length - 1].tMs, reason: 'out of indexing for 30 s' };
    }
    if (elapsed >= readyTimeoutSeconds * 1000) {
      if (!root) throw new Error('the sampler found no instance');
      return { root, ms: samples[samples.length - 1]?.tMs ?? elapsed, reason: 'ready timeout' };
    }
  }
}

// front brings the editor's window to the front by its process, as a click on the window would;
// `open -a` could bring another running copy of the same application instead (the user's own
// Lithe, when the measured one is a build of it).
async function front(driver, pid) {
  for (let attempt = 0; attempt < 3; attempt++) {
    const now = await driver.send({ op: 'frontmost' });
    if (now.pid === pid && now.application === pid) return;
    await driver.send({ op: 'activate', pid }).catch((error) => log(`activate ${pid}: ${error.message}`));
    await sleep(500);
  }
  throw new Error(`process ${pid} does not come to the front`);
}

// step presses keys and waits until the window is still.
async function step(ctx, keys, quietMs = 400) {
  await keysWithFront(ctx, keys);
  await ctx.driver.send({ op: 'quiet', minPixels: MIN_PIXELS, quietMs, timeoutMs: 8000 });
}

async function keysWithFront(ctx, keys) {
  await ctx.driver.send({ op: 'keys', pid: ctx.pid, keys });
}

// A step fails this way when the editor is not in front, Mission Control or App Exposé is open, or
// the window moved; "no key was pressed" says the editor received nothing.
function interrupted(error) {
  const message = String(error.message);
  return message.includes('not frontmost') || message.includes('disturbed:');
}

// recover waits until nothing covers or shrinks the editor, brings it to the front and records its
// window again, wherever the window now is.
async function recover(ctx, error) {
  ctx.disturbances.push({ at: new Date().toISOString(), error: String(error.message) });
  log(`${ctx.label}: interrupted (${error.message}); waiting and retrying`);
  if (ctx.disturbances.length > 40) throw new Error(`${ctx.label}: interrupted too often`);
  await ctx.driver.send({ op: 'calm', pid: ctx.pid, stableMs: 1000, timeoutMs: 180000 });
  await front(ctx.driver, ctx.pid);
  ctx.window = await ctx.driver.send({ op: 'attach', pid: ctx.pid, timeoutMs: 180000 });
}

// park moves the pointer to the middle of the title bar, where no editor shows anything for it.
async function park(ctx) {
  await ctx.driver.send({ op: 'point', pid: ctx.pid, x: ctx.window.x + ctx.window.w / 2, y: ctx.window.y + 14 });
}

// findCaret moves the caret one character right and back, and answers with the screen point in
// the middle of the character it crossed.
async function findCaret(ctx) {
  const spot = await ctx.driver.send({ op: 'locate', pid: ctx.pid, keys: [{ key: 'right' }], skipBottom: STATUS_BAR_POINTS, minPixels: TYPING_MIN_PIXELS, quietMs: 300, timeoutMs: 3000 });
  await step(ctx, [{ key: 'left' }], 300);
  return spot;
}

// place opens the target file through the editor's file search and puts the caret at line:column.
async function place(ctx, target) {
  await park(ctx);
  await step(ctx, [{ key: 'escape' }], 300);
  await step(ctx, ctx.keymap.quickOpen, 300);
  await step(ctx, [{ text: ctx.targets.file }], 800);
  await step(ctx, [{ key: 'return' }], 600);
  await step(ctx, ctx.keymap.goToLine, 300);
  const column = ctx.keymap.column === 'tabs4' ? target.tabColumn : target.column;
  await step(ctx, [{ key: 'a', mods: ['cmd'] }, { text: `${target.line}:${column}` }], 200);
  await step(ctx, [{ key: 'return' }], 600);
}

// operation places the caret and measures one operation; when something interrupts it, it starts
// over from placing the caret.
async function operation(ctx, op, rep) {
  const target = ctx.targets[op];
  let locateTries = 0;
  for (let attempt = 1; ; attempt++) {
    try {
      await place(ctx, target);
      const how = { keys: ctx.keymap[op] };
      let spot;
      if (op === 'hover') {
        locateTries += 1;
        spot = await findCaret(ctx);
        // The pointer comes along the line, as a mouse does, then rests on the character. The
        // caret's step right is about one character wide; the line above can be off the editor,
        // when the line is the first one shown.
        const character = Math.max(6, spot.line.right - spot.line.left);
        how.point = { x: spot.x, y: spot.y };
        how.via = { x: spot.x - 2 * character, y: spot.y };
        how.viaMs = VIA_MS;
        delete how.keys;
        // Nothing may still be changing when the pointer moves.
        await ctx.driver.send({ op: 'quiet', minPixels: MIN_PIXELS, quietMs: 1500, timeoutMs: 15000 });
      }
      const sentAt = Date.now();
      const result = await ctx.driver.send({ op: 'measure', pid: ctx.pid, ...how, minPixels: MIN_PIXELS, quietMs: SETTLED_QUIET_MS, timeoutMs: TIMEOUT_MS[op] });
      if (rep === 1) await ctx.driver.send({ op: 'snapshot', file: path.join(ctx.out, 'raw', `${ctx.id}-${op}.png`) }).catch(() => {});
      await park(ctx);
      await step(ctx, [{ key: 'escape' }], 400);
      return {
        rep,
        attempt,
        sentAt,
        point: spot ? { x: spot.x, y: spot.y, line: spot.line } : undefined,
        firstMs: result.firstMs ?? null,
        settledMs: result.settledMs ?? null,
        timedOut: result.timedOut,
        frames: result.frames,
        changedPixels: result.maxChangedPixels,
      };
    } catch (error) {
      if (String(error.message).includes('the caret was not found') && !interrupted(error)) {
        log(`${ctx.label} ${op} #${rep}: ${error.message} (try ${locateTries} of ${LOCATE_TRIES})`);
        if (locateTries < LOCATE_TRIES) continue;
        const picture = path.join(ctx.out, 'raw', `${ctx.id}-${op}-${rep}-not-found.png`);
        await ctx.driver.send({ op: 'snapshot', file: picture }).catch(() => {});
        await park(ctx).catch(() => {});
        return { rep, attempt, sentAt: Date.now(), error: String(error.message), picture: path.basename(picture), firstMs: null, settledMs: null, timedOut: false };
      }
      if (!interrupted(error) || attempt >= 5) throw error;
      await recover(ctx, error);
    }
  }
}

// keystroke measures one key while typing. A key that was refused is pressed again once the
// editor is back; a key that went in but whose measurement was interrupted counts as no sample, so
// the text always gets every key exactly once.
async function keystroke(ctx, key) {
  for (let attempt = 1; ; attempt++) {
    try {
      const result = await ctx.driver.send({ op: 'measure', pid: ctx.pid, keys: [key], minPixels: TYPING_MIN_PIXELS, quietMs: TYPING_QUIET_MS, timeoutMs: 3000 });
      return { firstMs: result.firstMs ?? null, timedOut: result.timedOut };
    } catch (error) {
      if (!interrupted(error) || attempt >= 5) throw error;
      const pressed = !String(error.message).includes('no key was pressed');
      await recover(ctx, error);
      if (pressed) return { firstMs: null, timedOut: false, interrupted: true };
    }
  }
}

// typing types TYPED at the end of the comment line, one letter at a time once the window is still,
// deletes it again with Backspace and saves.
async function typing(ctx) {
  const target = ctx.targets.typing;
  for (let attempt = 1; ; attempt++) {
    try {
      await place(ctx, { ...target, column: 1, tabColumn: 1 });
      await step(ctx, [{ key: 'right', mods: ['cmd'] }], 400);
      break;
    } catch (error) {
      if (!interrupted(error) || attempt >= 5) throw error;
      await recover(ctx, error);
    }
  }
  const typed = [];
  for (const letter of TYPED) typed.push(await keystroke(ctx, { text: letter }));
  await ctx.driver.send({ op: 'snapshot', file: path.join(ctx.out, 'raw', `${ctx.id}-typing.png`) }).catch(() => {});
  const deleted = [];
  for (let i = 0; i < TYPED.length; i++) deleted.push(await keystroke(ctx, { key: 'backspace' }));
  await ctx.driver.send({ op: 'quiet', minPixels: MIN_PIXELS, quietMs: 400, timeoutMs: 8000 });
  for (let attempt = 1; ; attempt++) {
    try {
      await step(ctx, [{ key: 's', mods: ['cmd'] }], 800);
      break;
    } catch (error) {
      if (!interrupted(error) || attempt >= 5) throw error;
      await recover(ctx, error);
    }
  }
  return { typed, deleted };
}

// resolveTargets finds each target's line and column in the file's text.
function resolveTargets(targets, text) {
  const lines = text.split('\n');
  const resolved = { file: targets.file };
  for (const [name, target] of Object.entries(targets)) {
    if (name === 'file') continue;
    const index = lines.findIndex((line) => line.includes(target.find));
    if (index < 0) throw new Error(`${targets.file} has no line containing ${target.find}`);
    const line = lines[index];
    const at = target.word ? line.indexOf(target.find) + target.find.indexOf(target.word) + 1 : line.length;
    let tabColumn = 0;
    for (const character of line.slice(0, at)) tabColumn = character === '\t' ? tabColumn + 4 - (tabColumn % 4) : tabColumn + 1;
    resolved[name] = { ...target, line: index + 1, column: at + 1, tabColumn: tabColumn + 1 };
  }
  return resolved;
}

// readLsp reads the proxy logs of a session: the messages, how many requests of each method went
// which way, and the settings the editor gave gopls.
function readLsp(dir) {
  const messages = [];
  const servers = [];
  for (const file of fs.readdirSync(dir).filter((name) => name.endsWith('.jsonl'))) {
    for (const line of fs.readFileSync(path.join(dir, file), 'utf8').split('\n').filter(Boolean)) {
      const record = JSON.parse(line);
      if (record.type === 'start') servers.push({ args: record.args, cwd: record.cwd });
      else if (record.type !== 'exit') messages.push(record);
    }
  }
  messages.sort((a, b) => a.t - b.t);
  const byMethod = {};
  let bytes = 0;
  for (const message of messages) {
    bytes += message.bytes;
    if (message.type !== 'response' || !message.method) continue;
    const key = `${message.dir === 's2c' ? '' : '← '}${message.method}`;
    const slot = (byMethod[key] ??= { count: 0, ms: [], errors: 0 });
    slot.count += 1;
    slot.ms.push(message.ms);
    if (message.error) slot.errors += 1;
  }
  const requests = Object.fromEntries(
    Object.entries(byMethod)
      .sort((a, b) => b[1].count - a[1].count)
      .map(([method, slot]) => [method, { count: slot.count, medianMs: median(slot.ms), errors: slot.errors }]),
  );
  const notifications = {};
  for (const message of messages.filter((m) => m.type === 'notification')) {
    const key = `${message.dir === 'c2s' ? '→' : '←'} ${message.method}`;
    notifications[key] = (notifications[key] ?? 0) + 1;
  }
  const initialize = messages.find((m) => m.type === 'request' && m.method === 'initialize');
  return {
    servers,
    bytes,
    messageCount: messages.length,
    requests,
    notifications,
    initializationOptions: initialize?.params?.initializationOptions ?? null,
    clientCapabilities: initialize?.params?.capabilities ?? null,
    configuration: messages.filter((m) => m.type === 'response' && m.method === 'workspace/configuration').map((m) => m.result),
    didChangeConfiguration: messages.filter((m) => m.method === 'workspace/didChangeConfiguration').map((m) => m.params),
    messages,
  };
}

// matchRequest finds the request an operation sent: the first of its method after the key press
// and before the next press.
function matchRequest(result, messages, method, untilMs, line) {
  const request = messages.find(
    (m) => m.dir === 'c2s' && m.type === 'request' && m.method === method && m.t >= result.sentAt - 50 && m.t < untilMs && (line === undefined || m.params?.position?.line === line),
  );
  if (!request) return;
  const response = messages.find((m) => m.dir === 's2c' && m.type === 'response' && m.id === request.id && m.t >= request.t);
  result.lsp = { sentAfterMs: request.t - result.sentAt, serverMs: response ? response.t - request.t : null, items: response?.items ?? null };
}

function buildDriver(outDir) {
  const binary = path.join(outDir, 'ide-compare-input');
  const built = spawnSync('xcrun', ['swiftc', '-O', '-swift-version', '5', '-o', binary, DRIVER_SOURCE], { stdio: 'inherit' });
  if (built.status !== 0) throw new Error('the input driver does not compile');
  return binary;
}

// Driver talks to ide-compare-input-macos.swift: one JSON line per command and per answer.
class Driver {
  constructor(binary) {
    this.process = spawn(binary, [], { stdio: ['pipe', 'pipe', 'inherit'] });
    this.waiting = [];
    readline.createInterface({ input: this.process.stdout }).on('line', (line) => {
      const next = this.waiting.shift();
      if (!next) return;
      const answer = JSON.parse(line);
      if (answer.ok) next.resolve(answer);
      else next.reject(new Error(answer.error));
    });
    this.process.on('close', (code) => {
      for (const next of this.waiting.splice(0)) next.reject(new Error(`the input driver exited (${code})`));
    });
  }

  send(command) {
    return new Promise((resolve, reject) => {
      this.waiting.push({ resolve, reject });
      this.process.stdin.write(`${JSON.stringify(command)}\n`);
    });
  }

  close() {
    this.process.stdin.end();
    setTimeout(() => {
      if (alive(this.process.pid)) this.process.kill();
    }, 2000).unref();
  }
}

// ---- report ----

function renderReport(results) {
  const ids = Object.keys(results.ides);
  const label = (id) => `${results.ides[id].label} ${results.ides[id].version?.short ?? ''}`.trim();
  const values = (list, key) => (list ?? []).map((r) => r[key]).filter(Number.isFinite);
  const ms = (value) => (value === null || value === undefined ? '—' : `${Math.round(value)} ms`);
  const lines = [
    `# Go 交互延迟对比：${results.project.repository}`,
    '',
    `- 机器：${results.machine.cpu}，${results.machine.cores} 核，${(results.machine.memoryBytes / 2 ** 30).toFixed(0)} GB，${results.machine.os}`,
    `- 项目：${results.project.repository} @ ${results.project.revision.slice(0, 12)}，文件 ${results.targets.file}`,
    `- Go：${results.go.go ?? '—'}；gopls：${results.go.gopls ?? '—'}`,
    `- 每个操作 ${results.settings.reps} 次，每次先用编辑器的文件搜索打开文件、用“跳到行”放好光标；时间从按键到屏幕上第一帧变化（首次响应），以及到画面静止 ${results.settings.settledQuietMs} ms 前的最后一次变化（稳定）`,
    `- 悬停：三个编辑器都用鼠标指针停在词上触发（Lithe 除 F1 外没有悬停快捷键，F1 可能被其他应用占用，所以都不按键）。为了找到词在屏幕上的位置，把放在词里的光标用方向键右移一格再移回（不改文件），光标经过的那个字符就是指针的落点（状态栏不算）；指针平时停在标题栏中间，悬停时像真实鼠标一样沿着这一行从左边过来：先在左边两个字符处停 ${VIA_MS} ms（短于所有编辑器的悬停等待），再落到这个字符上；时间从指针落到字符上算起，包含编辑器自己的悬停等待：${Object.keys(results.ides).map((id) => `${results.ides[id].label} ${HOVER_DELAYS[id]?.ms ?? '?'} ms（${HOVER_DELAYS[id]?.source ?? '—'}）`).join('，')}`,
    `- 目标：${OPS.map((op) => `${op} ${results.targets[op].word}（第 ${results.targets[op].line} 行）`).join('，')}；打字在第 ${results.targets.typing.line} 行注释末尾`,
    '',
  ];
  for (const id of ids) {
    const entry = results.ides[id];
    if (entry.error) lines.push(`> ${label(id)}：失败：${entry.error}`, '');
  }
  const ok = ids.filter((id) => !results.ides[id].error);
  lines.push('## 就绪', '');
  lines.push(table(['编辑器', '就绪时间', '依据', '设置', '被打断后重做'], ok.map((id) => [label(id), fmtMs(results.ides[id].ready?.ms), results.ides[id].ready?.reason ?? '—', results.ides[id].note ?? '—', String(results.ides[id].disturbances?.length ?? 0)])));
  lines.push('', '被打断：调度中心（Mission Control）或应用窗口（App Exposé）打开、编辑器不在最前或窗口移动。这时不按键；按下后才发生的，这次测量作废，等屏幕恢复后重新放光标再测；打字时这一键记为无样本。', '');
  const opNames = { definition: '跳到定义', hover: '悬停文档', references: '查找引用' };
  for (const op of OPS) {
    lines.push(`## ${opNames[op]}（${results.targets[op].word}）`, '');
    lines.push(
      table(
        ['编辑器', '首次响应（中位数）', ...(op === 'hover' ? ['扣除悬停等待'] : []), '稳定（中位数）', '第 1 次首次响应', '第 1 次稳定', 'gopls 自身耗时（中位数）', '结果数', '超时', '失败'],
        ok.map((id) => {
          const list = results.ides[id].ops?.[op] ?? [];
          const server = list.map((r) => r.lsp?.serverMs).filter(Number.isFinite);
          const items = list.map((r) => r.lsp?.items).filter(Number.isFinite);
          const first = median(values(list, 'firstMs'));
          return [
            label(id),
            ms(first),
            ...(op === 'hover' ? [first === null || first === undefined || !HOVER_DELAYS[id] ? '—' : ms(first - HOVER_DELAYS[id].ms)] : []),
            ms(median(values(list, 'settledMs'))),
            ms(list[0]?.firstMs),
            ms(list[0]?.settledMs),
            server.length ? ms(median(server)) : id === 'goland' ? '（不用 gopls）' : '—',
            items.length ? String(median(items)) : '—',
            String(list.filter((r) => r.timedOut).length),
            String(list.filter((r) => r.error).length),
          ];
        }),
      ),
    );
    lines.push('');
  }
  lines.push(`## 打字（${TYPED.length} 个字母，再逐个退格）`, '');
  const p90 = (list) => {
    const sorted = [...list].sort((a, b) => a - b);
    return sorted.length ? sorted[Math.min(sorted.length - 1, Math.ceil(sorted.length * 0.9) - 1)] : null;
  };
  lines.push(
    table(
      ['编辑器', '输入中位数', '输入 P90', '退格中位数', '退格 P90', '超时'],
      ok.map((id) => {
        const t = results.ides[id].typing ?? { typed: [], deleted: [] };
        const typed = values(t.typed, 'firstMs');
        const deleted = values(t.deleted, 'firstMs');
        return [label(id), ms(median(typed)), ms(p90(typed)), ms(median(deleted)), ms(p90(deleted)), String([...t.typed, ...t.deleted].filter((r) => r.timedOut).length)];
      }),
    ),
  );
  lines.push('');
  const lspIds = ok.filter((id) => results.ides[id].lsp);
  if (lspIds.length > 0) {
    lines.push('## 发给 gopls 的请求（整个会话）', '');
    const methods = [...new Set(lspIds.flatMap((id) => Object.keys(results.ides[id].lsp.requests)))];
    lines.push(
      table(
        ['方法', ...lspIds.map((id) => `${label(id)} 次数`), ...lspIds.map((id) => `${label(id)} 中位耗时`)],
        methods.map((method) => [
          method,
          ...lspIds.map((id) => String(results.ides[id].lsp.requests[method]?.count ?? 0)),
          ...lspIds.map((id) => ms(results.ides[id].lsp.requests[method]?.medianMs)),
        ]),
      ),
    );
    lines.push('');
    lines.push(table(['编辑器', '消息数', '字节数'], lspIds.map((id) => [label(id), String(results.ides[id].lsp.messageCount), `${(results.ides[id].lsp.bytes / 2 ** 20).toFixed(1)} MB`])));
    lines.push('', '### 编辑器给 gopls 的设置', '');
    for (const id of lspIds) {
      const lsp = results.ides[id].lsp;
      lines.push(`- ${label(id)}：initializationOptions \`${JSON.stringify(lsp.initializationOptions)}\`；workspace/configuration 回答 \`${JSON.stringify(lsp.configuration[0] ?? null)}\``);
    }
    lines.push('');
  }
  lines.push('## 会话期间的资源', '');
  lines.push(
    table(
      ['编辑器', '峰值内存', '累计 CPU 时间', '项目文件被改动'],
      ok.map((id) => [label(id), results.ides[id].resources ? `${(results.ides[id].resources.peakFootprint / 2 ** 20).toFixed(0)} MB` : '—', results.ides[id].resources ? `${results.ides[id].resources.cpuSecondsTotal.toFixed(1)} s` : '—', results.ides[id].projectChanged ? '是' : '否']),
    ),
  );
  lines.push('');
  return `${lines.join('\n')}\n`;
}

await main();
