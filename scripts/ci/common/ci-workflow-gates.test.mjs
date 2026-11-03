import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const repository = fileURLToPath(new URL('../../../', import.meta.url));
const childDeadlineMs = 5_000;
const testOptions = { timeout: 15_000 };
const verifierCondition = "needs.changes.result == 'success' && needs.changes.outputs.reuse != '{}' && needs.changes.outputs.reuse != ''";
const commonBindings = {
  CHANGES_RESULT: 'needs.changes.result',
  REUSE: 'needs.changes.outputs.reuse',
};
const workflows = [
  {
    id: 'macos',
    selected: ['validation', 'plugins', 'swift', 'rust_core', 'macos_release'],
    lanes: [
      { lane: 'tooling', job: 'tooling' },
      { lane: 'swift', job: 'swift-tests', run: 'run_swift' },
      { lane: 'rust', job: 'rust-core-tests', run: 'run_rust' },
      { lane: 'release', job: 'release-build', run: 'run_release' },
    ],
    bindings: {
      ...commonBindings,
      TOOLING_RESULT: 'needs.tooling.result',
      TOOLING_SELECTED: 'needs.changes.outputs.validation',
      SWIFT_RESULT: 'needs.swift-tests.result',
      RUST_CORE_RESULT: 'needs.rust-core-tests.result',
      RELEASE_RESULT: 'needs.release-build.result',
      RUN_SWIFT: 'needs.changes.outputs.run_swift',
      RUN_RUST: 'needs.changes.outputs.run_rust',
      RUN_RELEASE: 'needs.changes.outputs.run_release',
      SWIFT_SELECTED: "needs.changes.outputs.swift == 'true' || needs.changes.outputs.rust_core == 'true' || needs.changes.outputs.plugins == 'true'",
      RUST_CORE_SELECTED: 'needs.changes.outputs.rust_core',
      RELEASE_SELECTED: 'needs.changes.outputs.macos_release',
    },
  },
  {
    id: 'windows',
    selected: ['windows', 'rust_core', 'windows_rust', 'java_jdt'],
    lanes: [
      { lane: 'frontend', job: 'frontend', run: 'run_frontend' },
      { lane: 'rust', job: 'rust-tests', run: 'run_rust' },
      { lane: 'jdt', job: 'real-jdt', run: 'run_jdt' },
    ],
    bindings: {
      ...commonBindings,
      WINDOWS_SELECTED: 'needs.changes.outputs.windows',
      RUST_CORE_SELECTED: 'needs.changes.outputs.rust_core',
      WINDOWS_RUST_SELECTED: 'needs.changes.outputs.windows_rust',
      FRONTEND_RESULT: 'needs.frontend.result',
      RUST_TESTS_RESULT: 'needs.rust-tests.result',
      JAVA_JDT_SELECTED: 'needs.changes.outputs.java_jdt',
      REAL_JDT_RESULT: 'needs.real-jdt.result',
      RUST_SELECTED: "needs.changes.outputs.rust_core == 'true' || needs.changes.outputs.windows_rust == 'true'",
      RUN_FRONTEND: 'needs.changes.outputs.run_frontend',
      RUN_RUST: 'needs.changes.outputs.run_rust',
      RUN_JDT: 'needs.changes.outputs.run_jdt',
    },
  },
  {
    id: 'plugins',
    selected: ['plugins'],
    lanes: [{ lane: 'plugins', job: 'plugin-tests', run: 'run_plugins' }],
    bindings: {
      ...commonBindings,
      PLUGIN_SELECTED: 'needs.changes.outputs.plugins',
      PLUGIN_RESULT: 'needs.plugin-tests.result',
      RUN_PLUGINS: 'needs.changes.outputs.run_plugins',
    },
  },
  {
    id: 'remote',
    selected: ['rust_remote'],
    lanes: [{ lane: 'remote', job: 'rust-remote-tests' }],
    bindings: {
      CHANGES_RESULT: 'needs.changes.result',
      RUST_REMOTE_SELECTED: 'needs.changes.outputs.rust_remote',
      RUST_REMOTE_RESULT: 'needs.rust-remote-tests.result',
    },
  },
];

// Read the indentation-delimited blocks in the checked-in workflows, without a
// YAML dependency. An unexpected layout fails extraction instead of skipping it.
function block(source, header, indent) {
  const lines = source.split('\n');
  const starts = lines.flatMap((line, index) => line === `${' '.repeat(indent)}${header}` ? [index] : []);
  assert.equal(starts.length, 1, `expected one ${header}`);
  const start = starts[0];
  let end = start + 1;
  while (end < lines.length && (lines[end].trim() === '' || lines[end].search(/\S/) > indent)) end++;
  return lines.slice(start + 1, end).join('\n');
}

function scalar(source, key, indent) {
  const matches = [...source.matchAll(new RegExp(`^${' '.repeat(indent)}${key}: (.+)$`, 'gm'))];
  assert.equal(matches.length, 1, `expected one ${key}`);
  return matches[0][1];
}

function expression(value) {
  return value.replace(/^\$\{\{\s*([\s\S]*?)\s*\}\}$/, '$1').trim();
}

function bindings(step) {
  return Object.fromEntries(block(step, 'env:', 8).split('\n').filter((line) => line.trim()).map((line) => {
    const match = line.match(/^          ([A-Z_]+): (.+)$/);
    assert.ok(match, `unexpected environment binding: ${line}`);
    return [match[1], expression(match[2])];
  }));
}

function bash(step) {
  assert.equal(scalar(step, 'shell', 8), 'bash');
  return block(step, 'run: |', 8).split('\n').map((line) => {
    assert.ok(line.trim() === '' || line.startsWith('          '), `unexpected Bash indentation: ${line}`);
    return line.slice(10);
  }).join('\n');
}

// Only the needs/steps/github references, comparisons and boolean operators used
// by these steps are supported. Unknown expressions fail rather than being eval'd.
function evaluate(value, context) {
  const source = expression(value);
  if (source.includes(' || ')) return source.split(' || ').some((part) => evaluate(part, context));
  if (source.includes(' && ')) return source.split(' && ').every((part) => evaluate(part, context));
  const comparison = source.match(/^(.+?) (==|!=) '([^']*)'$/);
  if (comparison) {
    const equal = evaluate(comparison[1], context) === comparison[3];
    return comparison[2] === '==' ? equal : !equal;
  }
  assert.match(source, /^(needs|steps|github)\.[\w.-]+$/);
  return source.split('.').reduce((value, key) => {
    assert.ok(Object.hasOwn(value, key), `missing fixture value for ${source}`);
    return value[key];
  }, context);
}

function environment(step, context) {
  return Object.fromEntries(Object.entries(bindings(step)).map(([key, value]) => [key, String(evaluate(value, context))]));
}

// The Linux gate uses Bash and jq. Own the entire process group and kill it on
// deadline, excessive output, spawn failure, and normal exit (including strays).
function runBash(source, env) {
  return new Promise((resolve, reject) => {
    const child = spawn('bash', ['--noprofile', '--norc', '-e', '-o', 'pipefail', '-c', source], {
      cwd: repository, env: { PATH: process.env.PATH, ...env }, detached: true, stdio: ['ignore', 'pipe', 'pipe'],
    });
    let stdout = '';
    let stderr = '';
    let failure;
    const stop = () => {
      if (!child.pid) return;
      try { process.kill(-child.pid, 'SIGKILL'); } catch (error) { if (error.code !== 'ESRCH') failure ??= error; }
    };
    const timer = setTimeout(() => {
      failure = new Error(`gate subprocess exceeded ${childDeadlineMs} ms\n${stdout}\n${stderr}`);
      stop();
    }, childDeadlineMs);
    const collect = (stream) => (data) => {
      if (stream === 'stdout') stdout += data;
      else stderr += data;
      if (stdout.length + stderr.length > 1024 * 1024) {
        failure = new Error('gate subprocess exceeded its output limit');
        stop();
      }
    };
    child.stdout.on('data', collect('stdout'));
    child.stderr.on('data', collect('stderr'));
    child.on('error', (error) => { failure = error; stop(); });
    child.on('close', (status, signal) => {
      clearTimeout(timer);
      stop();
      if (failure) reject(failure);
      else if (signal) reject(new Error(`gate subprocess terminated by ${signal}\n${stdout}\n${stderr}`));
      else resolve({ status, stdout, stderr });
    });
  });
}

function fixture(workflow, selected = true) {
  const outputs = Object.fromEntries(workflow.selected.map((key) => [key, String(selected)]));
  outputs.reuse = '{}';
  const needs = { changes: { result: 'success', outputs } };
  for (const lane of workflow.lanes) {
    if (lane.run) outputs[lane.run] = String(selected);
    needs[lane.job] = { result: selected ? 'success' : 'skipped' };
  }
  return { needs, github: { token: 'fixture-token' } };
}

function expectStatus(result, success) {
  assert.equal(result.status === 0, success, `exit ${result.status}\n${result.stdout}\n${result.stderr}`);
}

for (const workflow of workflows) {
  workflow.source = readFileSync(new URL(`../../../.github/workflows/ci-${workflow.id}.yml`, import.meta.url), 'utf8');
  workflow.gate = block(workflow.source, 'gate:', 2);
  workflow.required = block(workflow.gate, '- name: Verify required jobs', 6);
  const verify = (context) => runBash(bash(workflow.required), environment(workflow.required, context));

  test(`${workflow.id}: gate skips cancellation and retains needs/environment wiring`, testOptions, () => {
    assert.equal(expression(scalar(workflow.gate, 'if', 4)), 'always() && !cancelled()');
    const needs = block(workflow.gate, 'needs:', 4).split('\n').filter((line) => line.trim()).map((line) => {
      assert.match(line, /^      - [\w-]+$/);
      return line.trim().slice(2);
    });
    assert.deepEqual(needs, ['changes', ...workflow.lanes.map((lane) => lane.job)]);
    assert.deepEqual(bindings(workflow.required), workflow.bindings);
  });

  for (const classification of ['failure', 'cancelled', 'skipped', '']) {
    test(`${workflow.id}: classification ${classification || 'missing'} fails even when no lane runs`, testOptions, async () => {
      const context = fixture(workflow, false);
      context.needs.changes.result = classification;
      expectStatus(await verify(context), false);
    });
  }

  test(`${workflow.id}: selected successful lanes pass`, testOptions, async () => {
    expectStatus(await verify(fixture(workflow)), true);
  });

  test(`${workflow.id}: unselected skipped lanes pass`, testOptions, async () => {
    expectStatus(await verify(fixture(workflow, false)), true);
  });

  for (const lane of workflow.lanes) {
    for (const conclusion of ['failure', 'cancelled', 'skipped']) {
      test(`${workflow.id}/${lane.lane}: a selected ${conclusion} job fails`, testOptions, async () => {
        const context = fixture(workflow);
        context.needs[lane.job].result = conclusion;
        expectStatus(await verify(context), false);
      });
    }
    test(`${workflow.id}/${lane.lane}: an unselected job must be skipped`, testOptions, async () => {
      const context = fixture(workflow, false);
      context.needs[lane.job].result = 'success';
      expectStatus(await verify(context), false);
    });
    if (!lane.run) continue;

    for (const reuse of ['', '{}', '{"other":{"job_id":41}}']) {
      test(`${workflow.id}/${lane.lane}: a selected skipped lane without its reuse entry fails (${reuse || 'empty'})`, testOptions, async () => {
        const context = fixture(workflow);
        context.needs.changes.outputs[lane.run] = 'false';
        context.needs[lane.job].result = 'skipped';
        context.needs.changes.outputs.reuse = reuse;
        const result = await verify(context);
        expectStatus(result, false);
        assert.match(result.stdout, new RegExp(`Lane ${lane.lane} is selected but neither ran nor reused`));
      });
    }

    for (const conclusion of ['success', 'failure', 'cancelled']) {
      test(`${workflow.id}/${lane.lane}: a reused job is delegated to the real verifier (${conclusion})`, testOptions, async () => {
        const context = fixture(workflow);
        context.needs.changes.outputs[lane.run] = 'false';
        context.needs[lane.job].result = 'skipped';
        context.needs.changes.outputs.reuse = JSON.stringify({ [lane.lane]: { job_id: 42 } });
        expectStatus(await verify(context), true);
        const step = block(workflow.gate, '- name: Verify reused lane results', 6);
        assert.equal(evaluate(scalar(step, 'if', 8), context), true);
        // Preload only the API boundary. The checked-in CLI and its actual Bash
        // command still decide whether the reused job satisfies the gate.
        const preload = `globalThis.fetch = async (url, options) => {
          if (url !== 'https://api.invalid/repos/owner/repo/actions/jobs/42' || options.headers.Authorization !== 'Bearer fixture-token') throw new Error('unexpected verifier API request');
          console.log('fixture: read reused job 42');
          return { ok: true, status: 200, json: async () => ({ status: 'completed', conclusion: process.env.FIXTURE_CONCLUSION }) };
        };`;
        const result = await runBash(scalar(step, 'run', 8), {
          ...environment(step, context),
          GITHUB_API_URL: 'https://api.invalid', GITHUB_REPOSITORY: 'owner/repo', FIXTURE_CONCLUSION: conclusion,
          NODE_OPTIONS: `--import=data:text/javascript,${encodeURIComponent(preload)}`,
        });
        expectStatus(result, conclusion === 'success');
        assert.match(result.stdout, /fixture: read reused job 42/);
        assert.match(result.stdout, conclusion === 'success' ? /reused result passed/ : new RegExp(`concluded ${conclusion}`));
      });
    }
  }

  // Lanes without a run output cannot be reused from an earlier revision.
  if (!workflow.lanes.some((lane) => lane.run)) continue;
  test(`${workflow.id}: reuse checkout and verifier preserve their conditions, credentials and deadline`, testOptions, () => {
    const checkout = block(workflow.gate, '- name: Check out the reused-result verifier', 6);
    const verifier = block(workflow.gate, '- name: Verify reused lane results', 6);
    assert.match(scalar(checkout, 'uses', 8), /^actions\/checkout@/);
    assert.equal(scalar(block(checkout, 'with:', 8), 'sparse-checkout', 10), 'scripts/ci/common/verify-reused-ci-jobs.mjs');
    assert.equal(scalar(block(checkout, 'with:', 8), 'sparse-checkout-cone-mode', 10), 'false');
    assert.equal(expression(scalar(checkout, 'if', 8)), verifierCondition);
    assert.equal(expression(scalar(verifier, 'if', 8)), verifierCondition);
    assert.deepEqual(bindings(verifier), { GITHUB_TOKEN: 'github.token', LITHE_CI_REUSE: 'needs.changes.outputs.reuse' });
    assert.equal(scalar(verifier, 'timeout-minutes', 8), '95');
    assert.equal(scalar(verifier, 'run', 8), 'node scripts/ci/common/verify-reused-ci-jobs.mjs');
    for (const step of [checkout, verifier]) {
      for (const reuse of ['', '{}']) {
        const context = fixture(workflow, false);
        context.needs.changes.outputs.reuse = reuse;
        assert.equal(evaluate(scalar(step, 'if', 8), context), false);
      }
      const failed = fixture(workflow);
      failed.needs.changes.result = 'failure';
      failed.needs.changes.outputs.reuse = '{"swift":{"job_id":42}}';
      assert.equal(evaluate(scalar(step, 'if', 8), failed), false);
    }
  });
}

const macos = workflows.find((workflow) => workflow.id === 'macos');
const changes = block(macos.source, 'changes:', 2);
const promotion = block(changes, '- name: Require the preview verification of this commit', 6);

test('macos: release promotion is checked in classification and runs no gate lane', testOptions, () => {
  assert.equal(expression(scalar(promotion, 'if', 8)), "steps.classify.outputs.ci_scope == 'release_promotion'");
  assert.deepEqual(bindings(promotion), { GH_TOKEN: 'github.token', HEAD_SHA: 'github.event.pull_request.head.sha' });
  for (const scope of ['pull_request', 'post_merge', 'release_promotion']) {
    assert.equal(evaluate(scalar(promotion, 'if', 8), { steps: { classify: { outputs: { ci_scope: scope } } } }), scope === 'release_promotion');
  }
  const nodeTests = block(block(macos.source, 'tooling:', 2), '- name: Test release scripts and Markdown preview', 6);
  assert.match(nodeTests, /node --test[\s\S]*scripts\/ci\/common\/ci-workflow-gates\.test\.mjs(?:\s|$)/);
});

for (const conclusions of ['completed:success', 'completed:failure completed:success', '', 'in_progress:', 'completed:failure', 'completed:cancelled', 'completed:skipped']) {
  test(`macos: actual release promotion check with preview results ${conclusions || 'missing'}`, testOptions, async () => {
    const context = fixture(macos, false);
    context.github.event = { pull_request: { head: { sha: 'fixture-head' } } };
    // gh is the sole test double; reject a query for another SHA, event or branch.
    const fakeGh = `gh() {
      [[ "$#" == 4 && "$1" == api && "$2" == "repos/$GITHUB_REPOSITORY/actions/workflows/ci-macos.yml/runs?head_sha=$HEAD_SHA&event=push&branch=preview" && "$3" == --jq ]] || return 64
      printf '%s\\n' "$FIXTURE_PREVIEW_CONCLUSIONS"
    }`;
    const result = await runBash(`${fakeGh}\n${bash(promotion)}`, {
      ...environment(promotion, context), GITHUB_REPOSITORY: 'owner/repo', FIXTURE_PREVIEW_CONCLUSIONS: conclusions,
    });
    const success = conclusions.split(' ').includes('completed:success');
    expectStatus(result, success);
    context.needs.changes.result = success ? 'success' : 'failure';
    expectStatus(await runBash(bash(macos.required), environment(macos.required, context)), success);
  });
}

// Preserve the scheduling contract: main needs unique groups even for pending
// runs; the required gate must exist when every changed path is documentation.
for (const id of ['macos', 'windows', 'remote']) {
  test(`${id}: PR supersession and main preservation are declared at workflow scope`, testOptions, () => {
    const source = readFileSync(new URL(`../../../.github/workflows/ci-${id}.yml`, import.meta.url), 'utf8');
    const concurrency = block(source, 'concurrency:', 0);
    assert.equal(expression(scalar(concurrency, 'group', 2)), "github.workflow }}-${{ github.ref == 'refs/heads/main' && github.run_id || github.event.pull_request.number || github.ref");
    assert.equal(expression(scalar(concurrency, 'cancel-in-progress', 2)), "github.ref != 'refs/heads/main'");
    const events = block(source, 'on:', 0);
    assert.match(block(events, 'push:', 2), /main/);
    if (id === 'macos') assert.doesNotMatch(block(events, 'pull_request:', 2), /paths(?:-ignore)?:/);
    else assert.match(block(events, 'pull_request:', 2), /paths-ignore:/);
    assert.match(source, /\$GITHUB_REF.*refs\/heads\/main/);
  });
}

test('plugin-only changes require the shared Swift lane and keep every native plugin check', testOptions, async () => {
  const context = fixture(macos, false);
  context.needs.changes.outputs.plugins = 'true';
  expectStatus(await runBash(bash(macos.required), environment(macos.required, context)), false);
  context.needs.changes.outputs.run_swift = 'true';
  context.needs['swift-tests'].result = 'success';
  expectStatus(await runBash(bash(macos.required), environment(macos.required, context)), true);
  const swift = block(macos.source, 'swift-tests:', 2);
  for (const name of ['Run plugin-focused Swift tests', 'Build and verify official plugin packages']) {
    const step = block(swift, `- name: ${name}`, 6);
    assert.equal(expression(scalar(step, 'if', 8)), "needs.changes.outputs.plugins == 'true'");
  }
  assert.match(block(swift, '- name: Run plugin-focused Swift tests', 6), /--skip-build --filter/);
  const standalone = readFileSync(new URL('../../../.github/workflows/ci-plugins.yml', import.meta.url), 'utf8');
  assert.equal(block(standalone, 'on:', 0).trim(), 'workflow_dispatch:');
});

test('shared Swift test selection preserves coverage and removes the language-suite overlap', testOptions, () => {
  const ordinary = block(block(macos.source, 'swift-tests:', 2), '- name: Run Swift unit tests', 6);
  const plugin = block(block(macos.source, 'swift-tests:', 2), '- name: Run plugin-focused Swift tests', 6);
  const filter = scalar(plugin, 'run', 8).match(/--filter '([^']+)'/)[1];
  const binding = scalar(block(ordinary, 'env:', 8), 'PLUGIN_TEST_SKIP', 10);
  const choices = binding.match(/&& '([^']+)' \|\| '([^']+)'/);
  assert.equal(choices[1], filter);
  assert.equal(choices[2], '([Pp]lugin|LinuxDo)');
  assert.match(ordinary, /--skip "\$PLUGIN_TEST_SKIP"/);
  for (const name of ['PluginManagerTests', 'LinuxDoTests', 'LanguageExtensionProcessLifecycleTests', 'LanguageServerToolServiceTests', 'EditorTests']) {
    const prior = !new RegExp(choices[2]).test(name) || new RegExp(filter).test(name);
    const selected = Number(!new RegExp(choices[1]).test(name)) + Number(new RegExp(filter).test(name));
    assert.equal(selected, Number(prior), name);
  }
});

// checkout can replace an uninitialized workspace even with clean: false.
// Reports must be downloaded after source setup, or the gate loses its evidence.
test('Windows shard evidence survives checkout and remains isolated per artifact', testOptions, () => {
  const windows = workflows.find((workflow) => workflow.id === 'windows');
  const gate = block(windows.source, 'gate:', 2);
  const checkout = gate.indexOf('- name: Check out shard coverage verifier');
  const download = gate.indexOf('- name: Download Core shard reports');
  const verify = gate.indexOf('- name: Verify exhaustive Core shard coverage');
  assert.ok(checkout >= 0 && checkout < download && download < verify);
  assert.doesNotMatch(gate.slice(download, verify), /uses: actions\/checkout/);
  assert.doesNotMatch(block(gate, '- name: Download Core shard reports', 6), /merge-multiple: true/);
});

test('Windows Rust matrices preserve every package and give host adapters their own lane', testOptions, () => {
  const windows = workflows.find((workflow) => workflow.id === 'windows');
  const rust = block(windows.source, 'rust-tests:', 2);
  const matrices = [...rust.matchAll(/'(\[[^']+\])'/g)].map(match => JSON.parse(match[1]));
  assert.equal(matrices.length, 3);
  for (const matrix of matrices) {
    const core = matrix.filter(lane => lane.scope === 'SharedRustCore');
    const hosts = matrix.filter(lane => lane.scope === 'SharedRustHosts');
    assert.deepEqual(core.map(lane => lane.shard), core.length ? [1, 2] : []);
    assert.equal(hosts.length, core.length ? 1 : 0);
    assert.equal(new Set(matrix.map(lane => lane.lane)).size, matrix.length);
  }
  const harness = readFileSync(new URL('../../../.agents/skills/write-stable-tests/scripts/test-stability-windows.ps1', import.meta.url), 'utf8');
  for (const packageName of ['lithe-core', 'lithe-git-host', 'lithe-agent-host', 'lithe-ide-host']) {
    assert.match(harness, new RegExp('-Package "' + packageName + '"'));
  }
  assert.match(block(rust, '- name: Test shared Rust host adapters', 6), /-Scope SharedRustHosts/);
  assert.match(block(rust, '- name: Verify Windows MCP stdio protocol', 6), /matrix.lane == 'shared-hosts'/);
});
