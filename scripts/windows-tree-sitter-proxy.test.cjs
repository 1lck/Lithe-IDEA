const assert = require('node:assert/strict');
const test = require('node:test');
const { configureProxy } = require('./windows-tree-sitter-proxy.cjs');

function fixture(overrides = {}) {
  const options = { argv: ['node', 'install.js'], env: { HTTPS_PROXY: 'http://proxy.invalid:8080',
    NO_PROXY: 'localhost', NODE_OPTIONS: '--trace-warnings' },
    agentModule: { globalAgent: 'original', Agent: class { constructor(config) { this.config = config; } } },
    version: '24.15.0', readPackage: () => ({ name: 'tree-sitter-cli' }), ...overrides };
  return options;
}

test('native Agent snapshots proxy while only the targeted lifecycle environment changes', { timeout: 1000 }, () => {
  const options = fixture();
  assert.equal(configureProxy(options), true);
  assert.equal(options.agentModule.globalAgent.config.proxyEnv.HTTPS_PROXY, 'http://proxy.invalid:8080');
  assert.deepEqual(options.env, { NO_PROXY: 'localhost', NODE_OPTIONS: '--trace-warnings' });
  assert.equal(options.agentModule.globalAgent.config.rejectUnauthorized, undefined);
});

test('lowercase proxy and no-proxy settings retain Node precedence', { timeout: 1000 }, () => {
  const options = fixture({ env: { https_proxy: 'http://proxy.invalid:8080', no_proxy: 'localhost' } });
  assert.equal(configureProxy(options), true);
  assert.equal(options.agentModule.globalAgent.config.proxyEnv.no_proxy, 'localhost');
  assert.equal(options.env.https_proxy, undefined);
});

test('unrelated scripts, other packages and direct installs keep upstream behavior', { timeout: 1000 }, () => {
  for (const override of [{ argv: ['node', 'other.js'] }, { readPackage: () => ({ name: 'other' }) },
    { readPackage: () => { throw new Error('unidentified script'); } }, { env: {} }]) {
    const options = fixture(override);
    const before = { ...options.env };
    assert.equal(configureProxy(options), false);
    assert.deepEqual(options.env, before);
    assert.equal(options.agentModule.globalAgent, 'original');
  }
});

test('unsupported Node fails before mutation; supported LTS versions use native capability', { timeout: 1000 }, () => {
  for (const version of ['20.19.0', '22.20.0', '24.4.0']) {
    const options = fixture({ version });
    assert.throws(() => configureProxy(options), /native proxyEnv support/);
    assert.equal(options.env.HTTPS_PROXY, 'http://proxy.invalid:8080');
    assert.equal(options.agentModule.globalAgent, 'original');
  }
  for (const version of ['22.21.0', '24.5.0', '25.0.0']) assert.equal(configureProxy(fixture({ version })), true);
});
