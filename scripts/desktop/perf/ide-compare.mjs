#!/usr/bin/env node
// Compares the resources Lithe and other editors use on macOS when they open the same project
// with no plugins installed: time to the main window, time until the processor goes quiet, memory,
// idle processor use, processes and threads, install size and the disk their profile grows to.
//
// Usage:
//   node scripts/desktop/perf/ide-compare.mjs run [--ides lithe,goland,vscode,zed] [--repeats N]
//        [--first-duration SECONDS] [--duration SECONDS] [--revision REV] [--out DIR] [--work DIR]
//        [--keep-work] [--source DIR] [--name NAME] [--go FILE] [--lithe-plugin ID]
//   node scripts/desktop/perf/ide-compare.mjs report RESULTS.json
//
// --go FILE compares Go support instead: every editor opens FILE (relative to the project) as well
// as the project, Lithe with the Go plugin whose ID --lithe-plugin gives (required with Lithe; the
// scripts name no plugin of their own), copied as it is installed in Lithe on this machine, Zed
// with its built-in Go support and GoLand as it ships. Lithe and Zed start the same gopls from
// PATH; each launch of them gets a gopls cache of its own in the profile (GOPLSCACHE), which the
// first open starts empty, like GoLand's index. The quiet moment then means the language server
// has finished loading the project too, and gopls's memory and processor time are reported on
// their own.
// --source DIR is the Git checkout cloned for every editor (default this repository) and --name
// the folder name of the clones (default Lithe-IDEA for this repository, else DIR's name).
//
// run     Clones the Lithe repository at --revision (default HEAD) once per editor, so files an
//         editor writes into the project are not seen by another, and gives every editor a new,
//         isolated profile with nothing installed: the plugins and extensions a fresh install
//         ships with are left as they are, nothing else is added, and the automatic update check
//         is turned off so no editor downloads an update while it is measured. Each editor first
//         opens the project once in its new profile (the "first open": a JetBrains IDE builds its
//         indexes here), then reopens it --repeats times in rounds that rotate the order of the
//         editors. Every launch goes through `open -n`, like a launch from the Finder, and is
//         sampled by ide-compare-sampler-macos.c, which counts memory the way Lithe's status bar
//         does. After a launch the instance is terminated and every process of it is checked to be
//         gone before the next one starts. Results go to --out (default
//         .artifacts/ide-compare/<time>/). Profiles and project copies go to --work (default a new
//         /tmp/idec-XXXXXX), which is deleted at the end unless --keep-work is given. The work
//         directory has to be short: editors put Unix sockets in their profile, and macOS refuses
//         socket paths over 103 bytes (VS Code quits at start when its profile is deeper).
// report  Prints the Markdown report of a results file.
//
// The machine should be idle: nothing else compiling or running, and the same power state for the
// whole run. Load averages are recorded with every launch so a noisy run can be recognised.
//
// Editors are looked up in /Applications and ~/Applications; LITHE_IDE_COMPARE_<ID>_APP (for
// example LITHE_IDE_COMPARE_GOLAND_APP) points at another bundle. GoLand needs a license: the
// goland.key of the newest GoLand configuration in ~/Library/Application Support/JetBrains is
// copied into the isolated profile for the run and deleted from it at the end.
import { spawn, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import readline from 'node:readline';
import { fileURLToPath } from 'node:url';

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const ROOT_DIR = path.resolve(SCRIPT_DIR, '../../..');
const SAMPLER_SOURCE = path.join(SCRIPT_DIR, 'ide-compare-sampler-macos.c');
const HOME = os.homedir();

// Seconds of the end of a launch that steady memory and idle processor use are read from.
const TAIL_SECONDS = 30;
// A launch has settled at the first moment after its main window appeared from which the next
// SETTLE_WINDOW_SECONDS average below SETTLE_CPU_PERCENT of one core.
const SETTLE_WINDOW_SECONDS = 5;
const SETTLE_CPU_PERCENT = 10;
// Pause between launches, so the previous instance's exit does not land in the next one.
const COOLDOWN_SECONDS = 15;

// Library folders a shadow home gets empty instead of linked, so an editor configured through
// $HOME starts with nothing of its own.
const FRESH_LIBRARY_FOLDERS = new Set([
  'Application Support',
  'Caches',
  'HTTPStorages',
  'Logs',
  'Saved Application State',
  'WebKit',
]);

const IDES = {
  lithe: {
    label: 'Lithe',
    bundles: ['Lithe Desktop.app'],
    executable: 'Contents/MacOS/lithe',
    quitSeconds: 20,
    profileNote: 'shadow $HOME whose Library/Application Support and Caches are empty; no plugins',
    prepare(profile, setup) {
      // Lithe reads its configuration from os.UserConfigDir(), which follows $HOME, so the
      // profile is a home of its own. Everything else of the real home (shell start files, Git
      // configuration, toolchains) is linked, so the login environment Lithe reads at start is
      // the user's.
      makeShadowHome(profile);
      const config = path.join(profile, 'Library', 'Application Support', 'Lithe Desktop');
      fs.mkdirSync(config, { recursive: true });
      writeJson(path.join(config, 'settings.json'), { updatesManual: true });
      if (setup.goFile) {
        // The Go command keeps its settings (go env -w) and build cache under the folders the
        // shadow home empties; the other editors use the user's, so these are linked back.
        linkReal(profile, path.join('Library', 'Application Support', 'go'));
        linkReal(profile, path.join('Library', 'Caches', 'go-build'));
        return installLitheGoSupport(config, setup);
      }
      return null;
    },
    launch(profile, project, setup) {
      const env = { HOME: profile };
      if (setup.goFile) env.GOPLSCACHE = path.join(profile, 'gopls-cache');
      return { env, args: [project] };
    },
    profileDirs: (profile) => [path.join(profile, 'Library', 'Application Support'), path.join(profile, 'Library', 'Caches')],
    go: {
      note: 'the Go plugin --lithe-plugin names, as installed in Lithe on this machine (its gopls from PATH); the file opens through a saved editor session; gopls cache in the profile (GOPLSCACHE)',
      indexDirs: (profile) => [path.join(profile, 'gopls-cache')],
    },
  },
  goland: {
    label: 'GoLand',
    bundles: ['GoLand.app'],
    executable: 'Contents/MacOS/goland',
    quitSeconds: 60,
    profileNote: 'new config, system, plugins and log paths; bundled plugins only; license file and "What\'s New" record copied; new UI tour off',
    prepare(profile) {
      const dirs = ['config', 'system', 'plugins', 'log'].map((name) => path.join(profile, name));
      dirs.forEach((dir) => fs.mkdirSync(dir, { recursive: true }));
      const key = newestJetBrainsFile('GoLand', 'goland.key');
      if (!key) {
        throw new Error('no goland.key under ~/Library/Application Support/JetBrains; start GoLand once and activate it');
      }
      fs.copyFileSync(key, path.join(profile, 'config', 'goland.key'));
      const properties = [
        `idea.config.path=${dirs[0]}`,
        `idea.system.path=${dirs[1]}`,
        `idea.plugins.path=${dirs[2]}`,
        `idea.log.path=${dirs[3]}`,
        // Dialogs a new profile would otherwise stop at before the project opens; the other
        // editors open the project without asking. The new UI tour is a modal dialog that holds
        // back indexing until it is closed, so without the registry key the first open would
        // measure an IDE waiting for a click and the indexing would land in the first reopen.
        'idea.trust.all.projects=true',
        'ide.experimental.ui.onboarding=false',
        'idea.initially.ask.config=never',
        'jb.consents.confirmation.enabled=false',
        'ide.show.tips.on.startup.default.value=false',
        'ide.no.platform.update=true',
      ];
      fs.writeFileSync(path.join(profile, 'goland.properties'), `${properties.join('\n')}\n`);
      // Settings → System Settings → Updates: no update checks, like the other editors.
      fs.mkdirSync(path.join(dirs[0], 'options'), { recursive: true });
      // A new profile opens the "What's New" page in a browser tab on its second launch, which
      // a real user sees once per update, so not part of daily use. The Updates setting does
      // not stop it; GoLand skips it when the version it last showed is recorded, so that
      // record is copied from the user's GoLand configuration.
      const whatsNew = newestJetBrainsFile('GoLand', path.join('options', 'other.xml'));
      const shown = whatsNew && /"whats\.new\.last\.shown\.version": ("[^"]*")/.exec(fs.readFileSync(whatsNew, 'utf8'));
      if (shown) {
        fs.writeFileSync(
          path.join(dirs[0], 'options', 'other.xml'),
          [
            '<application>',
            `  <component name="PropertyService"><![CDATA[{ "keyToString": { "whats.new.last.shown.version": ${shown[1]} } }]]></component>`,
            '</application>',
            '',
          ].join('\n'),
        );
      } else {
        log('GoLand: no "What\'s New" record in ~/Library/Application Support/JetBrains; reopens may show the page');
      }
      fs.writeFileSync(
        path.join(dirs[0], 'options', 'updates.xml'),
        [
          '<application>',
          '  <component name="UpdatesConfigurable">',
          '    <option name="CHECK_NEEDED" value="false" />',
          '    <option name="PLUGINS_CHECK_NEEDED" value="false" />',
          '  </component>',
          '</application>',
          '',
        ].join('\n'),
      );
    },
    launch(profile, project, setup) {
      const args = setup.goFile ? [project, path.join(project, setup.goFile)] : [project];
      return { env: { GOLAND_PROPERTIES: path.join(profile, 'goland.properties') }, args };
    },
    finish(profile) {
      fs.rmSync(path.join(profile, 'config', 'goland.key'), { force: true });
    },
    profileDirs: (profile) => ['config', 'system', 'plugins', 'log'].map((name) => path.join(profile, name)),
    projectDirs: (project) => [path.join(project, '.idea')],
    go: {
      note: 'the Go plugin GoLand ships with; its indexes and caches in the new system path',
      indexDirs: (profile) => [path.join(profile, 'system')],
      // smartMs is when this launch last left dumb mode (indexing) in GoLand's log, which counts
      // milliseconds from the start of the IDE process.
      smartMs(profile, projectName) {
        const file = path.join(profile, 'log', 'idea.log');
        if (!fs.existsSync(file)) return null;
        const text = fs.readFileSync(file, 'utf8');
        const launch = text.slice(text.lastIndexOf('IDE STARTED'));
        const exits = [...launch.matchAll(/^\S+ \S+ \[\s*(\d+)\]\s+INFO - #c\.i\.o\.p\.DumbServiceImpl - exit dumb mode \[(.*)\]$/gm)];
        const last = exits.filter((m) => m[2] === projectName).pop();
        return last ? Number(last[1]) : null;
      },
    },
  },
  vscode: {
    label: 'VS Code',
    bundles: ['Visual Studio Code.app'],
    executable: 'Contents/MacOS/Code',
    quitSeconds: 20,
    profileNote: 'new --user-data-dir and empty --extensions-dir; built-in extensions only',
    prepare(profile) {
      const user = path.join(profile, 'data', 'User');
      fs.mkdirSync(user, { recursive: true });
      fs.mkdirSync(path.join(profile, 'extensions'), { recursive: true });
      // Workspace trust would stop at a dialog; the other editors open the project trusted.
      writeJson(path.join(user, 'settings.json'), {
        'security.workspace.trust.enabled': false,
        'update.mode': 'none',
      });
    },
    launch(profile, project) {
      return {
        env: {},
        args: ['--user-data-dir', path.join(profile, 'data'), '--extensions-dir', path.join(profile, 'extensions'), project],
      };
    },
    profileDirs: (profile) => [path.join(profile, 'data'), path.join(profile, 'extensions')],
  },
  zed: {
    label: 'Zed',
    bundles: ['Zed.app'],
    executable: 'Contents/MacOS/zed',
    quitSeconds: 20,
    profileNote: 'new --user-data-dir (database, extensions, settings); no extensions, HTML extension auto-install off, worktrees trusted',
    prepare(profile) {
      const config = path.join(profile, 'data', 'config');
      fs.mkdirSync(config, { recursive: true });
      // A new Zed profile downloads the HTML extension on its first launch
      // (auto_install_extensions defaults to { html: true }); it is not part of the install.
      // A new profile opens the project untrusted and starts no language server until the user
      // trusts it; the other editors open the project trusted.
      writeJson(path.join(config, 'settings.json'), {
        auto_update: false,
        auto_install_extensions: { html: false },
        session: { trust_all_worktrees: true },
      });
    },
    launch(profile, project, setup) {
      const args = ['--user-data-dir', path.join(profile, 'data'), project];
      if (!setup.goFile) return { env: {}, args };
      return { env: { GOPLSCACHE: path.join(profile, 'gopls-cache') }, args: [...args, path.join(project, setup.goFile)] };
    },
    profileDirs: (profile) => [path.join(profile, 'data')],
    go: {
      note: "Zed's built-in Go support (gopls from PATH, as Zed finds it in the project's shell environment); gopls cache in the profile (GOPLSCACHE)",
      indexDirs: (profile) => [path.join(profile, 'gopls-cache')],
    },
  },
};

// installLitheGoSupport puts the Go plugin --lithe-plugin names (setup.plugin), as installed in
// Lithe on this machine, into a new Lithe configuration: the installed files, the user's approval
// of exactly that version and nothing else, the plugin turned on, and an editor session that
// reopens the Go file, because Lithe opens only the project from its command line. Lithe checks
// the files against the approval on start, so they are copied unchanged.
function installLitheGoSupport(config, setup) {
  const id = setup.plugin;
  const real = path.join(HOME, 'Library', 'Application Support', 'Lithe Desktop');
  const installed = path.join(real, 'plugins', id);
  const versions = fs.existsSync(installed) ? fs.readdirSync(installed).sort((a, b) => b.localeCompare(a, 'en', { numeric: true })) : [];
  const approvals = JSON.parse(fs.readFileSync(path.join(real, 'plugin-approvals.json'), 'utf8'));
  const version = versions.find((v) => approvals.plugins?.[id]?.[v]);
  if (!version) throw new Error(`install and approve ${id} in Lithe first (none under ${installed})`);
  const target = path.join(config, 'plugins', id, version);
  fs.mkdirSync(path.dirname(target), { recursive: true });
  run1('ditto', [path.join(installed, version), target]);
  writeJson(path.join(config, 'plugin-approvals.json'), {
    schemaVersion: approvals.schemaVersion,
    plugins: { [id]: { [version]: approvals.plugins[id][version] } },
  });
  writeJson(path.join(config, 'plugin-state.json'), {
    schemaVersion: 1,
    plugins: { [id]: { pluginID: id, enabled: true } },
  });
  const session = {
    savedAt: new Date().toISOString(),
    layout: { group: 'editor:1' },
    groups: [{ id: 'editor:1', files: [{ path: setup.goFile, line: 0, column: 0 }], selected: setup.goFile }],
    focused: 'editor:1',
  };
  // Sessions are keyed by the project path, which the command line can name through /tmp or
  // through /private/tmp.
  const sessions = {};
  for (const key of new Set([setup.project, fs.realpathSync(setup.project)])) sessions[key] = session;
  writeJson(path.join(config, 'editor-sessions.json'), sessions);
  return target;
}

// linkReal replaces the shadow home's copy of a folder with a link to the real home's.
function linkReal(home, relative) {
  const real = path.join(HOME, relative);
  if (!fs.existsSync(real)) return;
  const shadow = path.join(home, relative);
  fs.rmSync(shadow, { recursive: true, force: true });
  fs.mkdirSync(path.dirname(shadow), { recursive: true });
  fs.symlinkSync(real, shadow);
}

function main() {
  const [command, ...rest] = process.argv.slice(2);
  if (command === 'run') {
    return run(parseOptions(rest));
  }
  if (command === 'report' && rest.length === 1) {
    process.stdout.write(renderReport(JSON.parse(fs.readFileSync(rest[0], 'utf8'))));
    return undefined;
  }
  usage();
  return undefined;
}

function usage() {
  process.stderr.write(
    'Usage:\n' +
      '  ide-compare.mjs run [--ides lithe,goland,vscode,zed] [--repeats N] [--first-duration SECONDS]\n' +
      '                      [--duration SECONDS] [--revision REV] [--out DIR] [--work DIR] [--keep-work]\n' +
      '                      [--source DIR] [--name NAME] [--go FILE] [--lithe-plugin ID]\n' +
      '  ide-compare.mjs report RESULTS.json\n',
  );
  process.exit(64);
}

function parseOptions(args) {
  const options = {
    ides: Object.keys(IDES),
    repeats: 3,
    firstDuration: 180,
    duration: 90,
    revision: 'HEAD',
    out: path.join(ROOT_DIR, '.artifacts', 'ide-compare', new Date().toISOString().replace(/[:.]/g, '-')),
    work: null,
    keepWork: false,
    source: ROOT_DIR,
    name: null,
    goFile: null,
    plugin: null,
  };
  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    const value = () => {
      if (i + 1 >= args.length) usage();
      return args[++i];
    };
    if (arg === '--ides') options.ides = value().split(',').filter(Boolean);
    else if (arg === '--repeats') options.repeats = Number(value());
    else if (arg === '--first-duration') options.firstDuration = Number(value());
    else if (arg === '--duration') options.duration = Number(value());
    else if (arg === '--revision') options.revision = value();
    else if (arg === '--out') options.out = path.resolve(value());
    else if (arg === '--work') options.work = path.resolve(value());
    else if (arg === '--keep-work') options.keepWork = true;
    else if (arg === '--source') options.source = path.resolve(value());
    else if (arg === '--name') options.name = value();
    else if (arg === '--go') options.goFile = value();
    else if (arg === '--lithe-plugin') options.plugin = value();
    else usage();
  }
  options.name ??= options.source === ROOT_DIR ? 'Lithe-IDEA' : path.basename(options.source);
  for (const id of options.ides) {
    if (!IDES[id]) throw new Error(`unknown editor ${id}; known: ${Object.keys(IDES).join(', ')}`);
  }
  if (options.goFile !== null) {
    if (path.isAbsolute(options.goFile) || !fs.existsSync(path.join(options.source, options.goFile))) {
      throw new Error(`--go ${options.goFile} is not a file of ${options.source}`);
    }
    for (const id of options.ides) {
      if (!IDES[id].go) throw new Error(`${IDES[id].label} has no Go comparison; leave it out of --ides`);
    }
    if (options.ides.includes('lithe') && !options.plugin) {
      throw new Error('--go with Lithe needs --lithe-plugin ID, the ID of the Go plugin installed in Lithe');
    }
  }
  if (!(options.duration > TAIL_SECONDS) || !(options.firstDuration > TAIL_SECONDS) || !(options.repeats >= 0)) {
    throw new Error(`durations must be over ${TAIL_SECONDS} seconds and repeats at least 0`);
  }
  return options;
}

async function run(options) {
  if (process.platform !== 'darwin') throw new Error('ide-compare runs on macOS only');
  // A copy of an editor that is already open would take the launch over (Zed keeps one instance
  // per user whatever its data directory) or share warm caches with it, so none may run.
  const running = options.ides.flatMap((id) => runningCopies(findApp(id, IDES[id]), IDES[id]).map((pid) => `${IDES[id].label} (pid ${pid})`));
  if (running.length > 0) throw new Error(`quit these editors before measuring: ${running.join(', ')}`);

  fs.mkdirSync(path.join(options.out, 'raw'), { recursive: true });
  const sampler = buildSampler(options.out);
  const work = options.work ?? fs.mkdtempSync('/tmp/idec-');
  fs.mkdirSync(work, { recursive: true });
  // Command lines can name the work directory through /tmp or through /private/tmp.
  options.workPaths = [...new Set([work, fs.realpathSync(work)])];
  const git = (args) => run1('git', ['-C', options.source, ...args]);
  const revision = git(['rev-parse', options.revision]).trim();
  const results = {
    schema: 1,
    startedAt: new Date().toISOString(),
    machine: machineInfo(),
    project: {
      repository: options.name,
      revision,
      files: Number(git(['ls-tree', '-r', '--name-only', revision]).split('\n').filter(Boolean).length),
    },
    go: options.goFile === null ? null : goInfo(options.goFile),
    settings: {
      repeats: options.repeats,
      firstDurationSeconds: options.firstDuration,
      durationSeconds: options.duration,
      tailSeconds: TAIL_SECONDS,
      settleWindowSeconds: SETTLE_WINDOW_SECONDS,
      settleCpuPercent: SETTLE_CPU_PERCENT,
    },
    ides: {},
  };

  const contexts = [];
  for (const id of options.ides) {
    const ide = IDES[id];
    const app = findApp(id, ide);
    const profile = path.join(work, id, 'profile');
    const project = path.join(work, id, options.name);
    cloneProject(options.source, revision, project);
    fs.mkdirSync(profile, { recursive: true });
    const setup = { project, goFile: options.goFile, plugin: options.plugin };
    const plugin = ide.prepare(profile, setup);
    results.ides[id] = {
      label: ide.label,
      app,
      version: bundleVersion(app),
      installBytes: diskBytes([app]),
      profileNote: options.goFile === null ? ide.profileNote : `${ide.profileNote}; Go: ${ide.go.note}`,
      pluginBytes: typeof plugin === 'string' ? diskBytes([plugin]) : null,
      runs: [],
    };
    contexts.push({ id, ide, app, profile, project, setup });
  }
  const save = () => writeJson(path.join(options.out, 'results.json'), results);
  save();

  const rounds = [{ kind: 'first', duration: options.firstDuration, order: contexts }];
  for (let round = 1; round <= options.repeats; round++) {
    const shift = (round - 1) % contexts.length;
    rounds.push({ kind: 'reopen', duration: options.duration, order: [...contexts.slice(shift), ...contexts.slice(0, shift)] });
  }
  try {
    for (const [index, round] of rounds.entries()) {
      for (const context of round.order) {
        const label = `${context.ide.label} ${round.kind} #${index}`;
        log(`${label}: launching for ${round.duration}s`);
        const runResult = await measure(context, round, index, options, sampler);
        results.ides[context.id].runs.push(runResult);
        save();
        const s = runResult.summary;
        log(
          `${label}: window ${fmtMs(s.windowMs)}, project window ${fmtMs(s.projectWindowMs)}, settled ${fmtMs(s.settleMs)}, steady ${fmtMiB(s.steadyFootprint)}, ` +
            `peak ${fmtMiB(s.peakFootprint)}, idle CPU ${s.idleCpuPercent?.toFixed(2)}%, ${s.processes} processes`,
        );
        log(`${label}: windows ${runResult.windowTitles.join(' | ') || '(none)'}`);
        await sleep(COOLDOWN_SECONDS * 1000);
      }
    }
  } finally {
    for (const context of contexts) {
      context.ide.finish?.(context.profile);
      const entry = results.ides[context.id];
      entry.profileBytes = diskBytes(context.ide.profileDirs(context.profile));
      entry.projectWrittenBytes = diskBytes(context.ide.projectDirs?.(context.project) ?? []);
      if (options.goFile !== null) entry.indexBytes = diskBytes(context.ide.go.indexDirs(context.profile));
    }
    results.finishedAt = new Date().toISOString();
    save();
    if (options.keepWork) {
      log(`work:    ${work}`);
    } else {
      await sweep(options.workPaths, []);
      removeTree(work);
    }
  }
  fs.writeFileSync(path.join(options.out, 'report.md'), renderReport(results));
  log(`results: ${path.join(options.out, 'results.json')}`);
  log(`report:  ${path.join(options.out, 'report.md')}`);
}

// measure launches one instance, samples it for the round's duration and terminates it.
async function measure(context, round, index, options, sampler) {
  const { id, ide, app, profile, project, setup } = context;
  const rawFile = path.join(options.out, 'raw', `${id}-${round.kind}-${index}.jsonl`);
  const raw = fs.createWriteStream(rawFile);
  const loadBefore = os.loadavg();
  const after = Date.now() * 1000;
  const samplerProcess = spawn(
    sampler,
    [
      '--exe', path.join(app, ide.executable),
      '--after', String(after),
      '--interval', '500',
      '--fast-interval', '100',
      '--fast-until', '20',
      '--duration', String(round.duration),
      '--find-timeout', '60',
    ],
    { stdio: ['ignore', 'pipe', 'inherit'] },
  );
  const lines = [];
  const reader = readline.createInterface({ input: samplerProcess.stdout });
  reader.on('line', (line) => {
    raw.write(`${line}\n`);
    lines.push(JSON.parse(line));
  });
  const samplerExit = new Promise((resolve) => samplerProcess.on('close', resolve));

  const { env, args } = ide.launch(profile, project, setup);
  const openArgs = ['-n', '-a', app];
  for (const [key, value] of Object.entries(env)) openArgs.push('--env', `${key}=${value}`);
  openArgs.push('--args', ...args);
  const opened = spawnSync('open', openArgs, { encoding: 'utf8' });
  if (opened.status !== 0) {
    samplerProcess.kill();
    throw new Error(`open ${ide.label} failed: ${opened.stderr}`);
  }

  const code = await samplerExit;
  raw.end();
  const root = lines.find((line) => line.type === 'root');
  const samples = lines.filter((line) => line.type === 'sample');
  if (code !== 0 || !root || samples.length === 0) {
    await sweep(options.workPaths, []);
    throw new Error(`${ide.label}: the sampler found no instance (exit ${code})`);
  }
  const last = samples[samples.length - 1];
  const leftovers = await terminate(root.pid, last.list.map((entry) => entry.pid), ide.quitSeconds);
  const swept = await sweep(options.workPaths, last.list.map((entry) => entry.pid));
  const summary = summarize(samples, root.pid, round.duration, path.basename(project));
  const smartMs = setup.goFile ? ide.go.smartMs?.(profile, path.basename(project)) : undefined;
  if (smartMs !== undefined) summary.smartMs = smartMs === null ? null : root.startMs + smartMs;
  return {
    kind: round.kind,
    round: index,
    raw: path.relative(options.out, rawFile),
    // Every window title seen, so a launch that stopped at a dialog can be recognised.
    windowTitles: [...new Set(samples.flatMap((s) => s.windowList.map((w) => `${w.title || '(untitled)'} ${w.w}x${w.h}`)))],
    loadBefore,
    rootPid: root.pid,
    killedAfterTimeout: leftovers,
    sweptProcesses: swept,
    summary,
  };
}

// summarize reduces one launch's samples to the compared numbers. windowMs is the first large
// window, which can still be an empty frame; projectWindowMs is the first window, of any size, whose
// title names the project, and settling is timed from it.
//
// Processor time is added per process between samples, so a process that exits does not take its
// time out of the total, and the time of children that started and exited unseen between two
// samples is taken from what their parent has waited for (childCpuUs). The time a seen process had
// when it was last sampled is already counted, so when it exits that much is not counted again in
// the waited-for time of its nearest ancestor still running.
//
// Memory and processor time are also split into groups: each child of the root counts with all of
// its descendants under the child's name (gopls with the go commands it runs, for example), the
// root with what else it waited for under its own name, and a process the root is only responsible
// for under its own name.
function summarize(samples, rootPid, durationSeconds, projectName) {
  const cumulative = [];
  const cpuByGroup = new Map();
  const firstSeenMs = new Map();
  let total = 0;
  let previous = new Map();
  let previousGroups = new Map();
  const timeOf = (entry) => entry.cpuUs + (entry.childCpuUs ?? 0);
  const groupFootprints = [];
  for (const sample of samples) {
    const current = new Map(sample.list.map((entry) => [entry.pid, entry]));
    const groups = groupsOf(sample.list, rootPid);
    const counted = new Map();
    for (const [pid, entry] of previous) {
      if (current.has(pid)) continue;
      let ancestor = entry.ppid;
      for (let hops = 0; ancestor > 1 && !current.has(ancestor) && previous.has(ancestor) && hops < 64; hops++) ancestor = previous.get(ancestor).ppid;
      if (current.has(ancestor)) counted.set(ancestor, (counted.get(ancestor) ?? 0) + timeOf(entry));
    }
    for (const [pid, entry] of current) {
      const before = previous.get(pid);
      let used;
      if (!before) {
        used = timeOf(entry);
      } else {
        const waited = (entry.childCpuUs ?? 0) - (before.childCpuUs ?? 0);
        used = Math.max(0, entry.cpuUs - before.cpuUs) + Math.max(0, waited - (counted.get(pid) ?? 0));
      }
      total += used;
      const group = groups.get(pid) ?? previousGroups.get(pid) ?? entry.name;
      cpuByGroup.set(group, (cpuByGroup.get(group) ?? 0) + used);
    }
    const footprints = new Map();
    for (const entry of sample.list) {
      const group = groups.get(entry.pid);
      footprints.set(group, (footprints.get(group) ?? 0) + entry.footprint);
      if (!firstSeenMs.has(group)) firstSeenMs.set(group, sample.tMs);
    }
    groupFootprints.push(footprints);
    previous = current;
    previousGroups = groups;
    cumulative.push(total);
  }
  const cpuBetween = (fromMs, toMs) => {
    const from = samples.findIndex((s) => s.tMs >= fromMs);
    let to = -1;
    for (let i = samples.length - 1; i >= 0; i--) {
      if (samples[i].tMs <= toMs) {
        to = i;
        break;
      }
    }
    if (from < 0 || to <= from) return null;
    return (cumulative[to] - cumulative[from]) / ((samples[to].tMs - samples[from].tMs) * 10);
  };

  const windowSample = samples.find((s) => s.windows > 0);
  const windowMs = windowSample ? windowSample.tMs : null;
  const projectSample = samples.find((s) => s.windowList.some((w) => w.title.includes(projectName)));
  const projectWindowMs = projectSample ? projectSample.tMs : null;
  const settleFrom = projectWindowMs ?? windowMs;
  const endMs = samples[samples.length - 1].tMs;
  let settleMs = null;
  if (settleFrom !== null) {
    for (const sample of samples) {
      if (sample.tMs < settleFrom || sample.tMs + SETTLE_WINDOW_SECONDS * 1000 > endMs) continue;
      const cpu = cpuBetween(sample.tMs, sample.tMs + SETTLE_WINDOW_SECONDS * 1000);
      if (cpu !== null && cpu < SETTLE_CPU_PERCENT) {
        settleMs = sample.tMs;
        break;
      }
    }
  }
  const tailStart = durationSeconds * 1000 - TAIL_SECONDS * 1000;
  const tailIndexes = samples.flatMap((s, i) => (s.tMs >= tailStart ? [i] : []));
  const tail = tailIndexes.map((i) => samples[i]);
  const last = samples[samples.length - 1];
  const lastGroups = groupsOf(last.list, rootPid);
  const groups = new Map();
  for (const name of new Set([...cpuByGroup.keys(), ...firstSeenMs.keys()])) {
    groups.set(name, {
      name,
      footprint: 0,
      resident: 0,
      processes: 0,
      steadyFootprint: median(tailIndexes.map((i) => groupFootprints[i].get(name) ?? 0)),
      peakFootprint: Math.max(...groupFootprints.map((f) => f.get(name) ?? 0)),
      cpuSeconds: (cpuByGroup.get(name) ?? 0) / 1e6,
      firstSeenMs: firstSeenMs.get(name) ?? null,
    });
  }
  for (const entry of last.list) {
    const group = groups.get(lastGroups.get(entry.pid));
    group.footprint += entry.footprint;
    group.resident += entry.resident;
    group.processes += 1;
  }
  return {
    samples: samples.length,
    endMs,
    windowMs,
    projectWindowMs,
    settleMs,
    steadyFootprint: median(tail.map((s) => s.footprint)),
    steadyResident: median(tail.map((s) => s.resident)),
    peakFootprint: Math.max(...samples.map((s) => s.footprint)),
    idleCpuPercent: cpuBetween(tailStart, endMs),
    cpuSecondsTotal: total / 1e6,
    processes: last.processes,
    threads: last.threads,
    // footprint, resident and processes are the last sample's; the others cover the launch.
    breakdown: [...groups.values()].sort((a, b) => b.footprint - a.footprint || b.cpuSeconds - a.cpuSeconds),
  };
}

// groupsOf names the group of every process of one sample (see summarize).
function groupsOf(list, rootPid) {
  const byPid = new Map(list.map((entry) => [entry.pid, entry]));
  const groups = new Map();
  for (const entry of list) {
    let current = entry;
    let group = entry.name;
    for (let hops = 0; current && hops < 64; hops++) {
      if (current.pid === rootPid) break;
      if (current.ppid === rootPid) {
        group = current.name;
        break;
      }
      current = byPid.get(current.ppid);
    }
    groups.set(entry.pid, group);
  }
  return groups;
}

// terminate asks the root to quit with SIGTERM, waits for every process of the instance to exit
// and kills those still running after quitSeconds. It returns the processes it had to kill.
async function terminate(rootPid, pids, quitSeconds) {
  signal(rootPid, 'SIGTERM');
  const deadline = Date.now() + quitSeconds * 1000;
  while (Date.now() < deadline && pids.some(alive)) {
    await sleep(250);
  }
  const remaining = pids.filter(alive);
  remaining.forEach((pid) => signal(pid, 'SIGKILL'));
  return remaining.length;
}

// sweep kills any process still running whose command line names the work directory (the project
// or profile of a launch), and fails when one survives. This script and the shells that started it
// can name the directory too (--work) and are left alone.
async function sweep(workPaths, extraPids) {
  const find = () => {
    const listing = spawnSync('ps', ['-Ao', 'pid=,ppid=,command='], { encoding: 'utf8' }).stdout;
    const rows = listing
      .split('\n')
      .filter(Boolean)
      .map((line) => {
        const [pid, ppid] = line.trim().split(/\s+/, 2).map(Number);
        return { pid, ppid, line };
      });
    const parents = new Map(rows.map((row) => [row.pid, row.ppid]));
    const ancestors = new Set();
    for (let pid = process.pid; pid > 1 && !ancestors.has(pid); pid = parents.get(pid) ?? 0) ancestors.add(pid);
    const pids = rows.filter((row) => workPaths.some((dir) => row.line.includes(dir)) && !ancestors.has(row.pid)).map((row) => row.pid);
    return [...new Set([...pids, ...extraPids.filter(alive)])];
  };
  const found = find();
  found.forEach((pid) => signal(pid, 'SIGKILL'));
  await sleep(500);
  const survivors = find();
  if (survivors.length > 0) {
    throw new Error(`processes of the run still running: ${survivors.join(', ')}`);
  }
  return found.length;
}

function buildSampler(outDir) {
  const binary = path.join(outDir, 'ide-compare-sampler');
  const built = spawnSync(
    'xcrun',
    ['clang', '-O2', '-Wall', '-Wextra', '-o', binary, SAMPLER_SOURCE, '-framework', 'CoreFoundation', '-framework', 'CoreGraphics'],
    { stdio: 'inherit' },
  );
  if (built.status !== 0) throw new Error('the sampler does not compile');
  return binary;
}

function cloneProject(source, revision, target) {
  fs.mkdirSync(path.dirname(target), { recursive: true });
  run1('git', ['clone', '--quiet', '--no-checkout', source, target]);
  run1('git', ['-C', target, 'checkout', '--quiet', '--detach', revision]);
}

function makeShadowHome(home) {
  fs.mkdirSync(home, { recursive: true });
  for (const entry of fs.readdirSync(HOME)) {
    if (entry !== 'Library') fs.symlinkSync(path.join(HOME, entry), path.join(home, entry));
  }
  const library = path.join(home, 'Library');
  fs.mkdirSync(library);
  for (const entry of fs.readdirSync(path.join(HOME, 'Library'))) {
    if (FRESH_LIBRARY_FOLDERS.has(entry)) fs.mkdirSync(path.join(library, entry));
    else fs.symlinkSync(path.join(HOME, 'Library', entry), path.join(library, entry));
  }
  for (const entry of FRESH_LIBRARY_FOLDERS) fs.mkdirSync(path.join(library, entry), { recursive: true });
}

// removeTree deletes a work directory. A shadow home in it links to the real home, so every
// symbolic link is unlinked first and only real directories are entered.
function removeTree(dir) {
  const unlinkLinks = (current) => {
    for (const entry of fs.readdirSync(current, { withFileTypes: true })) {
      const target = path.join(current, entry.name);
      if (entry.isSymbolicLink()) fs.unlinkSync(target);
      else if (entry.isDirectory()) unlinkLinks(target);
    }
  };
  unlinkLinks(dir);
  fs.rmSync(dir, { recursive: true, force: true });
}

function newestJetBrainsFile(product, file) {
  const base = path.join(HOME, 'Library', 'Application Support', 'JetBrains');
  if (!fs.existsSync(base)) return null;
  const candidates = fs
    .readdirSync(base)
    .filter((name) => name.startsWith(product) && fs.existsSync(path.join(base, name, file)))
    .sort((a, b) => b.localeCompare(a, 'en', { numeric: true }));
  return candidates.length > 0 ? path.join(base, candidates[0], file) : null;
}

function findApp(id, ide) {
  const override = process.env[`LITHE_IDE_COMPARE_${id.toUpperCase()}_APP`];
  const candidates = override ? [override] : ide.bundles.flatMap((bundle) => ['/Applications', path.join(HOME, 'Applications')].map((dir) => path.join(dir, bundle)));
  const app = candidates.find((candidate) => fs.existsSync(path.join(candidate, ide.executable)));
  if (!app) throw new Error(`${ide.label} not found in ${candidates.join(', ')}`);
  return app;
}

// runningCopies returns the processes running the editor's main executable.
function runningCopies(app, ide) {
  const executable = fs.realpathSync(path.join(app, ide.executable));
  return spawnSync('ps', ['-Axo', 'pid=,comm='], { encoding: 'utf8' })
    .stdout.split('\n')
    .map((line) => line.trim().match(/^(\d+)\s+(.*)$/))
    .filter((match) => match && match[2] === executable)
    .map((match) => Number(match[1]));
}

function bundleVersion(app) {
  const plist = path.join(app, 'Contents', 'Info.plist');
  const read = (key) => spawnSync('plutil', ['-extract', key, 'raw', '-o', '-', plist], { encoding: 'utf8' }).stdout.trim();
  return { short: read('CFBundleShortVersionString'), build: read('CFBundleVersion') };
}

function machineInfo() {
  const sysctl = (name) => spawnSync('sysctl', ['-n', name], { encoding: 'utf8' }).stdout.trim();
  const sw = (flag) => spawnSync('sw_vers', [flag], { encoding: 'utf8' }).stdout.trim();
  return {
    model: sysctl('hw.model'),
    cpu: sysctl('machdep.cpu.brand_string'),
    cores: Number(sysctl('hw.ncpu')),
    memoryBytes: Number(sysctl('hw.memsize')),
    os: `macOS ${sw('-productVersion')} (${sw('-buildVersion')})`,
  };
}

function diskBytes(paths) {
  const existing = paths.filter((p) => fs.existsSync(p));
  if (existing.length === 0) return 0;
  const out = spawnSync('du', ['-sk', ...existing], { encoding: 'utf8' }).stdout;
  return out
    .split('\n')
    .filter(Boolean)
    .reduce((sum, line) => sum + Number(line.split('\t')[0]) * 1024, 0);
}

// ---- report ----

function renderReport(results) {
  if (results.go) return renderGoReport(results);
  const ids = Object.keys(results.ides);
  const stat = (id, kind, pick) => {
    const values = results.ides[id].runs.filter((r) => r.kind === kind).map((r) => pick(r.summary)).filter((v) => v !== null && v !== undefined);
    return values.length > 0 ? median(values) : null;
  };
  const rows = (kind) =>
    ids.map((id) => {
      const e = results.ides[id];
      return [
        `${e.label} ${e.version.short}`,
        fmtMs(stat(id, kind, (s) => s.projectWindowMs)),
        fmtMs(stat(id, kind, (s) => s.settleMs)),
        fmtMiB(stat(id, kind, (s) => s.steadyFootprint)),
        fmtMiB(stat(id, kind, (s) => s.peakFootprint)),
        fmtPercent(stat(id, kind, (s) => s.idleCpuPercent)),
        fmtSeconds(stat(id, kind, (s) => s.cpuSecondsTotal)),
        String(stat(id, kind, (s) => s.processes) ?? '—'),
        String(stat(id, kind, (s) => s.threads) ?? '—'),
      ];
    });
  const header = ['编辑器', '项目窗口出现', '启动到空闲', '稳定内存', '峰值内存', '空闲 CPU', '累计 CPU 时间', '进程数', '线程数'];
  const m = results.machine;
  const lines = [];
  lines.push('# Lithe 与其他编辑器的资源对比（0 插件）', '');
  lines.push(`- 机器：${m.cpu}，${m.cores} 核，${(m.memoryBytes / 2 ** 30).toFixed(0)} GiB，${m.os}`);
  lines.push(`- 项目：${results.project.repository} @ ${results.project.revision.slice(0, 9)}（${results.project.files} 个文件）`);
  lines.push(
    `- 每个编辑器：全新配置首次打开 1 次（${results.settings.firstDurationSeconds} 秒），再重开 ${results.settings.repeats} 次（每次 ${results.settings.durationSeconds} 秒），表中为重开的中位数`,
  );
  lines.push(`- 稳定内存、空闲 CPU 取每次最后 ${results.settings.tailSeconds} 秒；内存是物理占用（phys_footprint，活动监视器“内存”列），按进程树和 macOS 归属汇总`, '');
  lines.push('## 日常重开', '', table(header, rows('reopen')), '');
  lines.push('## 全新配置首次打开', '', table(header, rows('first')), '');
  lines.push('## 安装与磁盘', '');
  lines.push(
    table(
      ['编辑器', '安装包', '配置与缓存', '写进项目'],
      ids.map((id) => {
        const e = results.ides[id];
        return [`${e.label} ${e.version.short}`, fmtBytes(e.installBytes), fmtBytes(e.profileBytes), fmtBytes(e.projectWrittenBytes)];
      }),
    ),
    '',
  );
  lines.push('## 每次运行', '');
  lines.push(
    table(
      ['编辑器', '类型', '项目窗口', '启动到空闲', '稳定内存', '峰值内存', '空闲 CPU', '负载（1 分钟）'],
      ids.flatMap((id) =>
        results.ides[id].runs.map((r) => [
          results.ides[id].label,
          r.kind === 'first' ? '首次打开' : `重开 #${r.round}`,
          fmtMs(r.summary.projectWindowMs),
          fmtMs(r.summary.settleMs),
          fmtMiB(r.summary.steadyFootprint),
          fmtMiB(r.summary.peakFootprint),
          fmtPercent(r.summary.idleCpuPercent),
          r.loadBefore[0].toFixed(2),
        ]),
      ),
    ),
    '',
  );
  lines.push('## 稳定时的进程构成（最后一次重开）', '');
  for (const id of ids) {
    const runs = results.ides[id].runs;
    const lastRun = runs[runs.length - 1];
    if (!lastRun) continue;
    lines.push(`### ${results.ides[id].label}`, '');
    lines.push(
      table(
        ['进程', '数量', '物理占用'],
        lastRun.summary.breakdown.slice(0, 12).map((g) => [g.name, String(g.processes), fmtMiB(g.footprint)]),
      ),
      '',
    );
  }
  return `${lines.join('\n')}\n`;
}

// renderGoReport is the report of a --go run: the same launches, read as the time and resources an
// editor needs until its Go support has loaded the project, with the language server's share.
function renderGoReport(results) {
  const ids = Object.keys(results.ides);
  const group = (summary, name) => summary.breakdown.find((g) => g.name === name) ?? null;
  const stat = (id, kind, pick) => {
    const values = results.ides[id].runs.filter((r) => r.kind === kind).map((r) => pick(r.summary)).filter((v) => v !== null && v !== undefined);
    return values.length > 0 ? median(values) : null;
  };
  const header = ['编辑器', '项目窗口出现', 'Go 就绪（CPU 静下来）', '索引完成（GoLand 日志）', '稳定内存', '其中 gopls', '峰值内存', '累计 CPU 时间', '其中 gopls', '空闲 CPU', '进程数'];
  const rows = (kind) =>
    ids.map((id) => {
      const e = results.ides[id];
      return [
        `${e.label} ${e.version.short}`,
        fmtMs(stat(id, kind, (s) => s.projectWindowMs)),
        fmtMs(stat(id, kind, (s) => s.settleMs)),
        fmtMs(stat(id, kind, (s) => s.smartMs)),
        fmtMiB(stat(id, kind, (s) => s.steadyFootprint)),
        fmtMiB(stat(id, kind, (s) => group(s, 'gopls')?.steadyFootprint)),
        fmtMiB(stat(id, kind, (s) => s.peakFootprint)),
        fmtSeconds(stat(id, kind, (s) => s.cpuSecondsTotal)),
        fmtSeconds(stat(id, kind, (s) => group(s, 'gopls')?.cpuSeconds)),
        fmtPercent(stat(id, kind, (s) => s.idleCpuPercent)),
        String(stat(id, kind, (s) => s.processes) ?? '—'),
      ];
    });
  const m = results.machine;
  const go = results.go;
  const lines = [];
  lines.push(`# Go 支持对比：${ids.map((id) => results.ides[id].label).join('、')}`, '');
  lines.push(`- 机器：${m.cpu}，${m.cores} 核，${(m.memoryBytes / 2 ** 30).toFixed(0)} GiB，${m.os}`);
  lines.push(`- 项目：${results.project.repository} @ ${results.project.revision.slice(0, 9)}（${results.project.files} 个文件），打开 \`${go.file}\``);
  lines.push(`- Go：${go.go ?? '—'}；gopls：${go.gopls ?? '—'}（${go.goplsPath ?? '不在 PATH 中'}）`);
  lines.push(
    `- 每个编辑器：全新配置首次打开 1 次（${results.settings.firstDurationSeconds} 秒），再重开 ${results.settings.repeats} 次（每次 ${results.settings.durationSeconds} 秒），表中为重开的中位数`,
  );
  lines.push(
    `- Go 就绪：项目窗口出现后，整个进程树（含 gopls 和它运行的 go 命令）的 CPU 第一次在 ${results.settings.settleWindowSeconds} 秒内平均低于单核 ${results.settings.settleCpuPercent}%，即加载、索引完成`,
  );
  lines.push(
    `- 稳定内存、空闲 CPU 取每次最后 ${results.settings.tailSeconds} 秒；内存是物理占用（phys_footprint），按进程树和 macOS 归属汇总；CPU 时间含已退出的子进程（go list、cgo、编译器）`,
  );
  lines.push('- 索引完成：GoLand 日志里本次启动最后一次退出 dumb mode 的时间，此后 Go 功能可用，但 GoLand 可能仍在后台分析');
  lines.push('- “其中 gopls”是 gopls 及其子进程；GoLand 不用 gopls，它的 Go 支持在 IDE 进程里', '');
  lines.push('## 日常重开', '', table(header, rows('reopen')), '');
  lines.push('## 全新配置首次打开（冷索引）', '', table(header, rows('first')), '');
  lines.push('## 安装与磁盘', '');
  lines.push(
    table(
      ['编辑器', '安装包', 'Go 插件', '索引与缓存', '配置与缓存合计', '写进项目'],
      ids.map((id) => {
        const e = results.ides[id];
        return [
          `${e.label} ${e.version.short}`,
          fmtBytes(e.installBytes),
          e.pluginBytes === null || e.pluginBytes === undefined ? '内置' : fmtBytes(e.pluginBytes),
          fmtBytes(e.indexBytes),
          fmtBytes(e.profileBytes),
          fmtBytes(e.projectWrittenBytes),
        ];
      }),
    ),
    '',
  );
  lines.push('## 每次运行', '');
  lines.push(
    table(
      ['编辑器', '类型', '项目窗口', 'gopls 启动', 'Go 就绪', '索引完成', '稳定内存', '峰值内存', '累计 CPU 时间', '空闲 CPU', '负载（1 分钟）'],
      ids.flatMap((id) =>
        results.ides[id].runs.map((r) => [
          results.ides[id].label,
          r.kind === 'first' ? '首次打开' : `重开 #${r.round}`,
          fmtMs(r.summary.projectWindowMs),
          fmtMs(group(r.summary, 'gopls')?.firstSeenMs),
          fmtMs(r.summary.settleMs),
          fmtMs(r.summary.smartMs),
          fmtMiB(r.summary.steadyFootprint),
          fmtMiB(r.summary.peakFootprint),
          fmtSeconds(r.summary.cpuSecondsTotal),
          fmtPercent(r.summary.idleCpuPercent),
          r.loadBefore[0].toFixed(2),
        ]),
      ),
    ),
    '',
  );
  lines.push('## 进程构成', '');
  for (const id of ids) {
    const runs = results.ides[id].runs;
    for (const run of new Set([runs.find((r) => r.kind === 'first'), runs[runs.length - 1]].filter(Boolean))) {
      lines.push(`### ${results.ides[id].label}：${run.kind === 'first' ? '首次打开' : `重开 #${run.round}`}`, '');
      lines.push(
        table(
          ['进程组', '进程数（结束时）', '稳定内存', '峰值内存', 'CPU 时间'],
          run.summary.breakdown
            .filter((g) => g.cpuSeconds >= 0.05 || g.peakFootprint >= 2 ** 20)
            .slice(0, 12)
            .map((g) => [g.name, String(g.processes), fmtMiB(g.steadyFootprint), fmtMiB(g.peakFootprint), fmtSeconds(g.cpuSeconds)]),
        ),
        '',
      );
    }
  }
  return `${lines.join('\n')}\n`;
}

function goInfo(file) {
  const first = (command, args) => {
    const result = spawnSync(command, args, { encoding: 'utf8' });
    return result.status === 0 ? result.stdout.trim().split('\n')[0] : null;
  };
  return {
    file,
    go: first('go', ['version']),
    goPath: first('/usr/bin/which', ['go']),
    gopls: first('gopls', ['version']),
    goplsPath: first('/usr/bin/which', ['gopls']),
  };
}

function table(header, rows) {
  return [`| ${header.join(' | ')} |`, `| ${header.map(() => '---').join(' | ')} |`, ...rows.map((row) => `| ${row.join(' | ')} |`)].join('\n');
}

// ---- helpers ----

function median(values) {
  if (values.length === 0) return null;
  const sorted = [...values].sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  return sorted.length % 2 === 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
}

function fmtMs(ms) {
  if (ms === null || ms === undefined) return '—';
  return ms < 10000 ? `${(ms / 1000).toFixed(2)} s` : `${(ms / 1000).toFixed(1)} s`;
}
function fmtMiB(bytes) {
  return bytes === null || bytes === undefined ? '—' : `${(bytes / 2 ** 20).toFixed(0)} MB`;
}
function fmtBytes(bytes) {
  if (bytes === null || bytes === undefined) return '—';
  if (bytes >= 2 ** 30) return `${(bytes / 2 ** 30).toFixed(2)} GB`;
  if (bytes > 0 && bytes < 2 ** 20) return `${Math.max(1, Math.round(bytes / 2 ** 10))} KB`;
  return `${(bytes / 2 ** 20).toFixed(bytes >= 100 * 2 ** 20 ? 0 : 1)} MB`;
}
function fmtPercent(value) {
  return value === null || value === undefined ? '—' : `${value.toFixed(2)}%`;
}
function fmtSeconds(value) {
  return value === null || value === undefined ? '—' : `${value.toFixed(1)} s`;
}

function alive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}
function signal(pid, name) {
  try {
    process.kill(pid, name);
  } catch {
    // Already gone.
  }
}
function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
function run1(command, args) {
  const result = spawnSync(command, args, { encoding: 'utf8', maxBuffer: 64 * 2 ** 20 });
  if (result.status !== 0) throw new Error(`${command} ${args.join(' ')} failed: ${result.stderr}`);
  return result.stdout;
}
function writeJson(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`);
}
function log(message) {
  process.stderr.write(`[ide-compare ${new Date().toISOString().slice(11, 19)}] ${message}\n`);
}

// ide-compare-latency.mjs launches and stops the editors the same way.
export {
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
};

if (process.argv[1] && fs.realpathSync(process.argv[1]) === fileURLToPath(import.meta.url)) await main();
