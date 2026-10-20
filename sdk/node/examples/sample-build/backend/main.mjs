// Sample Lithe plugin backend built on the official Node.js SDK.
//
// It is the build provider of the fictional "sample" build system, whose
// workspace file `lithe-sample.json` lists projects:
//
//   { "projects": [{ "name": "app", "path": "app",
//                    "build": ["node", "build.mjs"],
//                    "dependencies": [{ "name": "left-pad", "version": "1.3.0" }] }] }
//
// It shows the three things a backend does:
//   - answers Lithe's typed build requests (`lithe/build/model`,
//     `lithe/build/dependencies`), whose results Lithe itself understands;
//   - offers plugin functions for its own UI: `workspace.build` runs a
//     multi-step build (prepare, run each project's tool, record a snapshot),
//     and `snapshot.read` returns the last snapshot, also after a restart;
//   - registers `snapshot.clear` at runtime once there is a snapshot to clear.
//
// A packaged plugin vendors the SDK inside its package, for example as
// `backend/vendor/lithe-plugin-sdk/`, and imports it from there.

import { readFile } from 'node:fs/promises';
import { isAbsolute, join, normalize, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createBackend, openStateStore, PluginError } from '../../../src/index.mjs';

const backend = createBackend({ name: 'sample-build', version: '0.1.0' });
let workspaceRoot;
let store;

backend.onInitialize(async ({ params }) => {
  // Hosts may send a directory URI with a trailing slash (macOS does);
  // `resolve` drops it so `inside` compares like paths.
  workspaceRoot = resolve(fileURLToPath(params.rootUri));
  // `--state ${workspaceStateDir}` in plugin.json: the host's writable
  // directory for this workspace. The package itself is read-only.
  store = openStateStore(argument('--state'));
  if (store.read('snapshot', null)) offerClear();
});

backend.build.model(async ({ root }) => {
  const config = await readConfig(root);
  return {
    projects: config.projects.map(({ name, path }) => ({ name, path })),
  };
});

backend.build.dependencies(async ({ root, project }) => {
  const config = await readConfig(root);
  const projects = project ? config.projects.filter(({ path }) => path === project.path) : config.projects;
  return {
    dependencies: projects.flatMap(({ dependencies = [] }) =>
      dependencies.map(({ name, version }) => ({ name, version, children: [] })),
    ),
  };
});

backend.function('workspace.build', async ({ projects: selected }, context) => {
  // Step 1: prepare. Read the workspace file and resolve the selection.
  context.progress({ message: 'Preparing', percentage: 0 });
  const config = await readConfig('.');
  const projects = selectProjects(config, selected);

  // Step 2: run each project's tool. `context.run` ends the whole process
  // tree when Lithe cancels the call, so a cancelled build leaves nothing behind.
  const results = [];
  for (const [index, project] of projects.entries()) {
    context.progress({ message: `Building ${project.name}`, percentage: (100 * index) / projects.length });
    const [tool, ...args] = project.build;
    const { exitCode } = await context.run(tool === 'node' ? process.execPath : tool, args, {
      cwd: inside(workspaceRoot, project.path),
      onStdout: (text) => context.log(`[${project.name}] ${text.trimEnd()}`),
    });
    results.push({ name: project.name, exitCode });
    if (exitCode !== 0) {
      record(results, 'failed');
      throw new PluginError('sample.buildFailed', `${project.name} failed with exit code ${exitCode}.`);
    }
  }

  // Step 3: record the outcome, so `snapshot.read` returns it after a restart.
  const snapshot = record(results, 'succeeded');
  context.progress({ message: 'Done', percentage: 100 });
  return snapshot;
});

backend.function('snapshot.read', () => store.read('snapshot', null));

// Reads the latest snapshot when the build ends, not when it starts: two
// overlapping builds then get consecutive generations instead of the same one.
// The read and the write run without an `await` between them.
function record(projects, status) {
  const previous = store.read('snapshot', null);
  const snapshot = { generation: (previous?.generation ?? 0) + 1, status, projects };
  store.write('snapshot', snapshot);
  offerClear();
  return snapshot;
}

function offerClear() {
  if (backend.functionIDs.includes('snapshot.clear')) return;
  backend
    .registerFunction('snapshot.clear', () => {
      store.delete('snapshot');
      return null;
    })
    .catch((error) => backend.log('snapshot.clear stays unavailable:', error.message));
}

/** Every project, or exactly the named ones; an unknown name is an error, not an empty build. */
function selectProjects(config, selected) {
  if (selected === undefined || selected === null) return config.projects;
  if (!Array.isArray(selected) || selected.length === 0 || !selected.every((name) => typeof name === 'string')) {
    throw new PluginError('sample.selection', '"projects" must be a non-empty list of project names.');
  }
  const unknown = selected.filter((name) => !config.projects.some((project) => project.name === name));
  if (unknown.length > 0) {
    throw new PluginError('sample.unknownProject', `Unknown project: ${unknown.join(', ')}.`);
  }
  return config.projects.filter(({ name }) => selected.includes(name));
}

async function readConfig(root) {
  let config;
  try {
    config = JSON.parse(await readFile(join(inside(workspaceRoot, root), 'lithe-sample.json'), 'utf8'));
  } catch {
    throw new PluginError('sample.config', 'lithe-sample.json is missing or is not valid JSON.');
  }
  if (!Array.isArray(config.projects)) {
    throw new PluginError('sample.config', 'lithe-sample.json needs a "projects" list.');
  }
  return config;
}

/** `relative` resolved inside `base`; workspace files never name paths outside it. */
function inside(base, relative) {
  const path = normalize(join(base, relative));
  if (isAbsolute(relative) || (path !== base && !path.startsWith(base + sep))) {
    throw new PluginError('sample.path', `${relative} is outside the workspace.`);
  }
  return path;
}

function argument(name) {
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1] : undefined;
}

await backend.listen();
