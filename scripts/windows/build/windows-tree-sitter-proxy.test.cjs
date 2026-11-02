const assert = require('node:assert/strict');
const test = require('node:test');
const https = require('node:https');
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

test('lowercase selection and empty fallback match native Agent precedence', { timeout: 1000 }, () => {
  for (const env of [
    { https_proxy: 'http://lower.invalid:8080', HTTPS_PROXY: 'socks5://ignored.invalid:1080' },
    { https_proxy: '', HTTPS_PROXY: 'https://upper.invalid:8443' },
  ]) {
    const options = fixture({ env: { ...env }, agentModule: { globalAgent: 'original', Agent: https.Agent } });
    try {
      assert.equal(configureProxy(options), true);
      assert.deepEqual(options.agentModule.globalAgent.options.proxyEnv, env);
      assert.equal(options.agentModule.globalAgent.options.rejectUnauthorized, undefined);
      assert.deepEqual(options.env, {});
    } finally {
      if (options.agentModule.globalAgent !== 'original') options.agentModule.globalAgent.destroy();
    }
  }
  const direct = fixture({ env: { https_proxy: '', HTTPS_PROXY: '' } });
  assert.equal(configureProxy(direct), false);
  assert.equal(direct.agentModule.globalAgent, 'original');
  assert.deepEqual(direct.env, { https_proxy: '', HTTPS_PROXY: '' });
});

test('unsupported or malformed selected proxies fail before route mutation', { timeout: 1000 }, () => {
  for (const proxy of [
    'socks5://proxy.invalid:1080', 'proxy.invalid:8080', 'HTTP://proxy.invalid:8080',
    'http://', 'http://proxy.invalid:99999', 'http://proxy.invalid\r\n', 'http://pro\txy.invalid',
  ]) {
    const options = fixture({ env: { https_proxy: proxy, HTTPS_PROXY: 'http://fallback.invalid:8080' },
      agentModule: { globalAgent: 'original', Agent: https.Agent } });
    const before = { ...options.env };
    assert.throws(() => configureProxy(options), { code: 'LITHE_INVALID_TREE_SITTER_PROXY' });
    assert.deepEqual(options.env, before);
    assert.equal(options.agentModule.globalAgent, 'original');
  }
});

test('credential and native configuration failures never expose their inputs', { timeout: 1000 }, () => {
  const secret = 'fixture-sensitive-password';
  const proxy = `http://user%ZZ:${secret}@proxy.invalid:8080`;
  for (const override of [
    { env: { HTTPS_PROXY: proxy } },
    { env: { HTTPS_PROXY: `http://user:${secret}%ZZ@proxy.invalid:8080` } },
    { env: { HTTPS_PROXY: `http://user:${secret}@proxy.invalid:99999` } },
    { agentModule: { globalAgent: 'original', Agent: class { constructor() { throw new Error(secret); } } } },
  ]) {
    const options = fixture(override);
    const before = { ...options.env };
    assert.throws(() => configureProxy(options), error => {
      assert.equal(error.code, 'LITHE_INVALID_TREE_SITTER_PROXY');
      assert.equal(error.cause, undefined);
      assert.ok(!error.stack.includes(secret));
      assert.ok(!error.stack.includes(proxy));
      return true;
    });
    assert.deepEqual(options.env, before);
    assert.equal(options.agentModule.globalAgent, 'original');
  }
});

test('native Agent accepts encoded credentials without changing TLS defaults', { timeout: 1000 }, () => {
  const env = { HTTPS_PROXY: 'https://fixture%40user:fixture%3Apassword@proxy.invalid:8443', NO_PROXY: 'localhost' };
  const options = fixture({ env: { ...env }, agentModule: { globalAgent: 'original', Agent: https.Agent } });
  try {
    assert.equal(configureProxy(options), true);
    assert.ok(options.agentModule.globalAgent instanceof https.Agent);
    assert.deepEqual(options.agentModule.globalAgent.options.proxyEnv, env);
    assert.equal(options.agentModule.globalAgent.options.rejectUnauthorized, undefined);
    assert.deepEqual(options.env, { NO_PROXY: 'localhost' });
  } finally {
    if (options.agentModule.globalAgent !== 'original') options.agentModule.globalAgent.destroy();
  }
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
