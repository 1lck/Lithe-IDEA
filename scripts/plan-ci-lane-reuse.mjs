#!/usr/bin/env node
// Decides, per CI lane of a pull request run, whether to run the lane again or
// to reuse the result of an earlier run of the same pull request.
//
// A lane is reused when it already passed (or is still running) on an earlier
// revision and none of the pull request's own changes since then can affect
// it. Changes that only arrived from the base branch are ignored unless they
// touch CI infrastructure this workflow reads, in which case every lane of
// this workflow runs again; infrastructure of other workflows only (such as a
// Windows workflow edit seen by macOS CI) keeps reuse intact. Earlier runs
// that no lane reuses are cancelled, because GitHub cannot cancel single jobs.
// Any planning error runs every selected lane, so a check is never skipped
// because of the planner itself.
//
// Decision record:
// .agents/notes/implemented/process/2026-09-13-ci-build-cache-and-artifact-strategy.md
import { execFileSync } from 'node:child_process';
import { appendFileSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

// Lane definitions per workflow: the job a lane runs and the classifier
// outputs that select it. Keep in sync with the workflows' job `if:` lines.
export const WORKFLOW_LANES = Object.freeze({
  macos: [
    { lane: 'swift', job: 'Swift tests', selected: (o) => o.swift || o.swift_database || o.rust_core },
    { lane: 'rust', job: 'Rust Core tests', selected: (o) => o.rust_core },
    { lane: 'release', job: 'Release package verification', prefix: true, selected: (o) => o.macos_release },
  ],
  plugins: [
    { lane: 'plugins', job: 'Plugin tests and package verification', selected: (o) => o.plugins },
  ],
  windows: [
    { lane: 'frontend', job: 'Test Windows frontend', selected: (o) => o.windows },
    { lane: 'rust', job: 'Test Windows Rust implementation', selected: (o) => o.rust_core || o.windows_rust },
    { lane: 'jdt', job: 'Test real JDT on Windows', selected: (o) => o.java_jdt },
  ],
});

const ALL_WORKFLOWS = Object.freeze(Object.keys(WORKFLOW_LANES));
// The plugin workflow builds through the macOS toolchain actions and
// `scripts/test-macos.sh`, so macOS build infrastructure reaches it too.
const MACOS_FAMILY = Object.freeze(['macos', 'plugins']);
// Workflow files and local actions are scoped by what the planned workflow
// actually references; see `workflowReferences`.
const REFERENCED = 'referenced';

// Base-branch changes to these paths can change how lanes behave. A pull
// request that picks one up from the base reruns every lane of the workflows
// the matching rule names; other workflows keep reusing their results. The
// first matching rule wins, so narrower rules come before broader ones.
export const CI_INFRA_RULES = Object.freeze([
  { pattern: /^\.github\/(workflows|actions)\//, workflows: REFERENCED },
  { pattern: /^\.agents\/skills\/write-stable-tests\/scripts\/test-stability-windows\.ps1$/, workflows: ['windows'] },
  { pattern: /^\.agents\/skills\/write-stable-tests\/scripts\/test-stability-macos\.sh$/, workflows: MACOS_FAMILY },
  { pattern: /^\.agents\/skills\/write-stable-tests\/scripts\//, workflows: ALL_WORKFLOWS },
  { pattern: /^scripts\/(test-)?classify-ci-changes\.sh$/, workflows: ALL_WORKFLOWS },
  { pattern: /^scripts\/(plan-ci-lane-reuse|verify-reused-ci-jobs)(\.test)?\.mjs$/, workflows: ALL_WORKFLOWS },
  { pattern: /^scripts\/(test-macos|build-rust-core|prepare-macos-dependencies|validate-macos-dependency-caches|verify-rust-core[a-z-]*)\.sh$/, workflows: MACOS_FAMILY },
  { pattern: /^scripts\/[^/]*windows[^/]*\.(ps1|mjs|ts)$/i, workflows: ['windows'] },
  { pattern: /^(Package\.swift|Package\.resolved|\.swift-version)$/, workflows: MACOS_FAMILY },
  { pattern: /^(package\.json|bun\.lock|bunfig\.toml)$/, workflows: ALL_WORKFLOWS },
  // The shared Monaco editor feeds the macOS package and the Windows frontend,
  // matching the classifier's routing of `frontend/editor/*`.
  { pattern: /^frontend\/editor\/package\.json$/, workflows: ['macos', 'windows'] },
  // The Windows product links Rust Core through path dependencies, but nothing
  // outside `windows/` reads the Windows crates, toolchain or frontend manifest.
  { pattern: /^windows\/(.*\/)?(Cargo\.(toml|lock)|rust-toolchain(\.toml)?|package\.json)$/, workflows: ['windows'] },
  // Every other Cargo manifest, not only the workspace roots: a member crate's
  // features or dependencies change the build without touching the lock file.
  { pattern: /(^|\/)Cargo\.(toml|lock)$/, workflows: ALL_WORKFLOWS },
  { pattern: /(^|\/)rust-toolchain(\.toml)?$/, workflows: ALL_WORKFLOWS },
  { pattern: /^rust\/\.cargo\//, workflows: ALL_WORKFLOWS },
]);

const infrastructureRule = (path) => CI_INFRA_RULES.find((rule) => rule.pattern.test(path));

export const isCiInfrastructure = (path) => Boolean(infrastructureRule(path));

// Whether a CI infrastructure path can change the planned workflow's lanes.
// `references` lists the `.github/` files and action directories that workflow
// reads; a path no rule matches is not infrastructure at all.
export function infrastructureAffects(path, workflow, references) {
  const rule = infrastructureRule(path);
  if (!rule) return false;
  if (rule.workflows !== REFERENCED) return rule.workflows.includes(workflow);
  return references.files.has(path) || [...references.directories].some((directory) => path.startsWith(`${directory}/`));
}

const LOCAL_REFERENCE = /\.\/(\.github\/(?:actions|workflows)\/[^\s"'@#]+)/g;

// The planned workflow file plus every local action and reusable workflow it
// reaches, directly or through a composite action, at the given revisions.
// Both the base and the head count: a pull_request run executes their merge.
export function workflowReferences(git, revisions, workflowFile) {
  const files = new Set();
  const directories = new Set();
  const pending = [`.github/workflows/${workflowFile}`];
  const read = (path) => revisions.map((revision) => git.attempt(['show', `${revision}:${path}`]) ?? '').join('\n');
  while (pending.length) {
    const target = pending.pop().replace(/\/+$/, '');
    let text;
    if (/\.ya?ml$/.test(target) && target.startsWith('.github/workflows/')) {
      if (files.has(target)) continue;
      files.add(target);
      text = read(target);
    } else {
      if (directories.has(target)) continue;
      directories.add(target);
      text = read(`${target}/action.yml`) + read(`${target}/action.yaml`);
    }
    for (const match of text.matchAll(LOCAL_REFERENCE)) pending.push(match[1]);
  }
  return { files, directories };
}

export function parseClassification(text) {
  const outputs = {};
  for (const line of String(text).split('\n')) {
    const match = line.match(/^([a-z_]+)=(.*)$/);
    if (match) outputs[match[1]] = match[2] === 'true' ? true : match[2] === 'false' ? false : match[2];
  }
  return outputs;
}

export function selectedLanes(workflow, outputs) {
  return WORKFLOW_LANES[workflow].filter((definition) => definition.selected(outputs)).map((definition) => definition.lane);
}

// ---- git -------------------------------------------------------------------

function makeGit(cwd) {
  const run = (args) => execFileSync('git', args, { cwd, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim();
  const attempt = (args) => { try { return run(args); } catch { return null; } };
  return {
    run,
    attempt,
    // Earlier pull request heads may be absent from the checkout; GitHub serves
    // them by SHA while they are reachable from refs/pull/<n>/head history.
    ensureCommit(sha) {
      if (attempt(['cat-file', '-e', `${sha}^{commit}`]) !== null) return true;
      attempt(['fetch', '--no-tags', '--quiet', 'origin', sha]);
      return attempt(['cat-file', '-e', `${sha}^{commit}`]) !== null;
    },
  };
}

// Raw diff entries between two revisions as [path, "mode object"] pairs.
// NUL-separated output keeps paths unquoted (Chinese names included), and the
// mode is part of a file's identity because an executable bit change alone can
// break a lane. Paths are later handed to the classifier one per line, so a
// path containing a newline aborts planning, which runs every lane.
export function diffEntries(git, from, to) {
  const fields = git.run(['diff', '-z', '--raw', '--no-abbrev', '--no-renames', from, to]).split('\0');
  const entries = [];
  for (let index = 0; index + 1 < fields.length; index += 2) {
    const [, mode, , object] = fields[index].split(' ');
    const path = fields[index + 1];
    if (!mode || !object || !path) throw new Error(`unexpected git diff entry: ${JSON.stringify(fields[index])}`);
    if (path.includes('\n')) throw new Error(`path contains a newline: ${JSON.stringify(path)}`);
    entries.push([path, `${mode} ${object}`]);
  }
  return entries;
}

// The pull request's own version of each file it changes relative to the base.
function ownChanges(git, base, revision) {
  const mergeBase = git.run(['merge-base', base, revision]);
  return { mergeBase, files: new Map(diffEntries(git, mergeBase, revision)) };
}

// Files whose pull-request version differs between two revisions, and the CI
// infrastructure changes the base branch brought in between: both those the
// author merged in and those GitHub's merge commit picks up from a base that
// moved since the earlier run (previousBase is the base tip at that run).
export function compareRevisions(git, base, previous, current, previousBase = null) {
  const before = ownChanges(git, base, previous);
  const after = ownChanges(git, base, current);
  const changed = [];
  for (const path of new Set([...before.files.keys(), ...after.files.keys()])) {
    if ((before.files.get(path) ?? 'base') !== (after.files.get(path) ?? 'base')) changed.push(path);
  }
  const infrastructure = new Set();
  const collect = (from, to) => {
    if (!from || from === to) return;
    for (const [path] of diffEntries(git, from, to)) if (isCiInfrastructure(path)) infrastructure.add(path);
  };
  collect(before.mergeBase, after.mergeBase);
  collect(previousBase, base);
  return { changed: changed.sort(), infrastructure: [...infrastructure].sort() };
}

function classifyPaths({ repoRoot, previous, current, paths }) {
  if (paths.length === 0) return {};
  const directory = mkdtempSync(join(tmpdir(), 'lithe-lane-reuse-'));
  try {
    const list = join(directory, 'paths.txt');
    writeFileSync(list, `${paths.join('\n')}\n`);
    const env = { ...process.env, LITHE_CI_ONLY_PATHS: list, LITHE_CI_SCOPE: 'pull_request' };
    delete env.LITHE_CI_DRAFT_PULL_REQUEST;
    return parseClassification(execFileSync('bash', [join(repoRoot, 'scripts/classify-ci-changes.sh'), previous, current],
      { cwd: repoRoot, encoding: 'utf8', env, stdio: ['ignore', 'pipe', 'pipe'] }));
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
}

// ---- GitHub ----------------------------------------------------------------

function makeApi({ apiURL, token, fetchImpl }) {
  return async (path, { method = 'GET' } = {}) => {
    const response = await fetchImpl(`${apiURL}${path}`, {
      method,
      headers: { Accept: 'application/vnd.github+json', Authorization: `Bearer ${token}`, 'X-GitHub-Api-Version': '2022-11-28' },
      signal: AbortSignal.timeout(20000),
    });
    if (!response.ok) throw new Error(`GitHub API ${response.status} for ${method} ${path}`);
    return response.status === 202 || response.status === 204 ? null : response.json();
  };
}

const matchesJob = (definition, job) => (definition.prefix ? job.name.startsWith(definition.job) : job.name === definition.job);

// ---- plan ------------------------------------------------------------------

export async function planLaneReuse({ env, outputs, repoRoot, fetchImpl = fetch, log = console }) {
  const workflow = env.LITHE_CI_WORKFLOW;
  if (!WORKFLOW_LANES[workflow]) throw new Error(`Unknown CI workflow: ${workflow}`);
  const lanes = selectedLanes(workflow, outputs);
  // `infrastructure` records base-branch CI changes per decision: `rerun`
  // reached this workflow, `ignored` only reaches other workflows.
  const plan = {
    run: Object.fromEntries(lanes.map((lane) => [lane, true])),
    reuse: {},
    cancelled: [],
    reason: '',
    infrastructure: { rerun: new Set(), ignored: new Set() },
  };
  if (env.GITHUB_EVENT_NAME !== 'pull_request' || outputs.ci_scope !== 'pull_request' || lanes.length === 0) {
    plan.reason = 'every selected lane runs (not a pull request run, or nothing selected)';
    return plan;
  }

  try {
    const api = makeApi({ apiURL: env.GITHUB_API_URL || 'https://api.github.com', token: env.GITHUB_TOKEN, fetchImpl });
    const git = makeGit(repoRoot);
    const base = env.PR_BASE_SHA;
    const current = env.PR_HEAD_SHA;
    if (!git.ensureCommit(base) || !git.ensureCommit(current)) throw new Error('pull request base or head is unavailable');

    const listing = await api(`/repos/${env.GITHUB_REPOSITORY}/actions/workflows/${env.LITHE_CI_WORKFLOW_FILE}/runs?event=pull_request&branch=${encodeURIComponent(env.PR_HEAD_REF)}&per_page=30`);
    // Only runs strictly older than this one: a planner that starts late must
    // neither cancel nor reuse a run created for a newer revision. Run numbers
    // increase per workflow in creation order and survive re-run attempts.
    const runNumber = Number(env.GITHUB_RUN_NUMBER);
    if (!Number.isInteger(runNumber) || runNumber <= 0) throw new Error('GITHUB_RUN_NUMBER is unavailable');
    const runs = (listing.workflow_runs ?? [])
      .filter((run) => Number(run.run_number) < runNumber && run.head_repository?.full_name === env.PR_HEAD_REPOSITORY)
      .sort((left, right) => new Date(right.created_at) - new Date(left.created_at));

    let executed = false;
    const jobsByRun = new Map();
    const jobsOf = async (run) => {
      if (!jobsByRun.has(run.id)) jobsByRun.set(run.id, (await api(`/repos/${env.GITHUB_REPOSITORY}/actions/runs/${run.id}/jobs?filter=latest&per_page=100`)).jobs ?? []);
      return jobsByRun.get(run.id);
    };
    // Base tip when an earlier run started, so base changes since then count.
    const baseTipAt = async (time) => {
      const commits = await api(`/repos/${env.GITHUB_REPOSITORY}/commits?sha=${encodeURIComponent(env.PR_BASE_REF)}&until=${encodeURIComponent(time)}&per_page=1`);
      const sha = commits?.[0]?.sha;
      return sha && git.ensureCommit(sha) ? sha : null;
    };
    let references;
    const affectedByRun = new Map();
    const affectedSince = async (run) => {
      const previous = run.head_sha;
      if (!affectedByRun.has(run.id)) {
        let affected;
        const previousBase = await baseTipAt(run.created_at).catch(() => null);
        if (!git.ensureCommit(previous) || !previousBase) {
          affected = 'all';
        } else {
          const comparison = compareRevisions(git, base, previous, current, previousBase);
          references ??= workflowReferences(git, [base, current], env.LITHE_CI_WORKFLOW_FILE);
          const relevant = comparison.infrastructure.filter((path) => infrastructureAffects(path, workflow, references));
          for (const path of comparison.infrastructure) {
            (relevant.includes(path) ? plan.infrastructure.rerun : plan.infrastructure.ignored).add(path);
          }
          affected = relevant.length > 0
            ? 'all'
            : new Set(selectedLanes(workflow, classifyPaths({ repoRoot, previous, current, paths: comparison.changed })));
        }
        affectedByRun.set(run.id, affected);
      }
      return affectedByRun.get(run.id);
    };

    for (const definition of WORKFLOW_LANES[workflow].filter((item) => lanes.includes(item.lane))) {
      for (const run of runs) {
        const job = (await jobsOf(run)).find((candidate) => matchesJob(definition, candidate));
        // A lane skipped in a run was itself reused or not selected there; keep
        // looking for the run that actually executed it.
        if (!job || job.conclusion === 'skipped') continue;
        executed = true;
        // Jobs assigned to the retired self-hosted pool cannot migrate to
        // hosted runners. Keep hosted queues reusable: other lanes can still
        // need that run, so replacing its queued jobs would duplicate builds.
        const usable = job.conclusion === 'success'
          || (job.status !== 'completed'
            && !(job.labels ?? []).some((label) => label.toLowerCase() === 'self-hosted'));
        if (usable) {
          const affected = await affectedSince(run);
          if (affected !== 'all' && !affected.has(definition.lane)) {
            plan.run[definition.lane] = false;
            plan.reuse[definition.lane] = { run_id: run.id, job_id: job.id, head_sha: run.head_sha, status: job.status, url: job.html_url };
          }
        }
        break;
      }
    }

    // Earlier runs still in progress are obsolete unless a lane reuses them.
    const kept = new Set(Object.values(plan.reuse).map((source) => source.run_id));
    for (const run of runs.filter((item) => item.status !== 'completed' && !kept.has(item.id))) {
      try {
        await api(`/repos/${env.GITHUB_REPOSITORY}/actions/runs/${run.id}/cancel`, { method: 'POST' });
        plan.cancelled.push(run.id);
      } catch (error) {
        log.warn?.(`Could not cancel obsolete run ${run.id}: ${error.message}`);
      }
    }
    if (Object.keys(plan.reuse).length) plan.reason = 'unaffected lanes reuse earlier results';
    else if (plan.infrastructure.rerun.size) plan.reason = 'every selected lane runs (the base branch changed CI infrastructure this workflow reads)';
    else if (executed) plan.reason = 'every selected lane runs (earlier results failed, were cancelled, or are affected by new changes)';
    else plan.reason = 'every selected lane runs (no earlier run of this pull request executed them)';
  } catch (error) {
    plan.run = Object.fromEntries(lanes.map((lane) => [lane, true]));
    plan.reuse = {};
    plan.infrastructure = { rerun: new Set(), ignored: new Set() };
    plan.reason = `every selected lane runs (planning failed: ${error.message})`;
  }
  return plan;
}

export function planOutputs(workflow, plan) {
  const lines = WORKFLOW_LANES[workflow].map(({ lane }) => `run_${lane}=${plan.run[lane] === true}`);
  lines.push(`reuse=${JSON.stringify(plan.reuse)}`);
  return `${lines.join('\n')}\n`;
}

function summary(workflow, plan) {
  const rows = WORKFLOW_LANES[workflow].map(({ lane }) => {
    if (plan.reuse[lane]) return `| ${lane} | reuse ${plan.reuse[lane].status === 'completed' ? 'passed' : 'running'} job from [${plan.reuse[lane].head_sha.slice(0, 8)}](${plan.reuse[lane].url}) |`;
    return `| ${lane} | ${plan.run[lane] ? 'run' : 'not selected'} |`;
  });
  const cancelled = plan.cancelled.length ? `\n\nCancelled obsolete runs: ${plan.cancelled.join(', ')}` : '';
  const paths = (set) => [...set].sort().map((path) => `\`${path}\``).join(', ');
  const infrastructure = [
    plan.infrastructure?.rerun.size ? `\n\nBase CI infrastructure changes read by this workflow: ${paths(plan.infrastructure.rerun)}` : '',
    plan.infrastructure?.ignored.size ? `\n\nBase CI infrastructure changes for other workflows only (ignored): ${paths(plan.infrastructure.ignored)}` : '',
  ].join('');
  return `### Lane reuse\n\n${plan.reason}\n\n| Lane | Decision |\n| --- | --- |\n${rows.join('\n')}${cancelled}${infrastructure}\n`;
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  const workflow = process.env.LITHE_CI_WORKFLOW;
  const outputs = parseClassification(process.env.LITHE_CI_CLASSIFICATION ?? '');
  const plan = await planLaneReuse({ env: process.env, outputs, repoRoot: process.cwd() });
  const text = planOutputs(workflow, plan);
  if (process.env.GITHUB_OUTPUT) appendFileSync(process.env.GITHUB_OUTPUT, text);
  else process.stdout.write(text);
  if (process.env.GITHUB_STEP_SUMMARY) appendFileSync(process.env.GITHUB_STEP_SUMMARY, summary(workflow, plan));
  if (plan.reason.includes('planning failed')) console.log(`::warning title=Lane reuse::${plan.reason}`);
  console.error(summary(workflow, plan));
}
