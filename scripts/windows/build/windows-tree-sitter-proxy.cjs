// Keep upstream install.js and TLS verification; Node owns CONNECT and redirects.
const path = require('node:path');
const fs = require('node:fs');
const https = require('node:https');

function configureProxy({ argv, env, agentModule, version, readPackage }) {
  if (!argv[1] || path.basename(argv[1]) !== 'install.js') return false;
  // Match native proxyEnv precedence, including an empty lowercase fallback.
  const proxy = env.https_proxy || env.HTTPS_PROXY;
  if (!proxy) return false;
  let manifest;
  try {
    manifest = readPackage(path.join(path.dirname(path.resolve(argv[1])), 'package.json'));
  } catch {
    // An unidentified script keeps its original behavior and diagnostics.
    return false;
  }
  if (manifest.name !== 'tree-sitter-cli') return false;
  const [major, minor] = version.split('.').map(Number);
  if (!(major > 24 || (major === 24 && minor >= 5) || (major === 22 && minor >= 21))) {
    throw new Error('Proxied tree-sitter installation requires Node 22.21+ or 24.5+ with native proxyEnv support.');
  }
  let agent;
  try {
    // Native Agent ignores unsupported schemes instead of throwing. Reject
    // them before deleting upstream's route, which would otherwise go direct.
    if (typeof proxy !== 'string' || !/^https?:\/\//.test(proxy) || /[\r\n\t]/.test(proxy)) {
      throw new Error('Unsupported proxy URL');
    }
    const parsed = new URL(proxy);
    if (!parsed.hostname) throw new Error('Missing proxy host');
    decodeURIComponent(parsed.username);
    decodeURIComponent(parsed.password);
    agent = new agentModule.Agent({ proxyEnv: { ...env } });
  } catch {
    // URL and native Agent errors may embed credentials. Do not attach a cause.
    const error = new Error('Proxied tree-sitter installation requires a valid http:// or https:// proxy URL with valid encoded credentials.');
    error.code = 'LITHE_INVALID_TREE_SITTER_PROXY';
    throw error;
  }
  // Snapshot before removing the two variables consumed by upstream's manual
  // CONNECT branch. Only this lifecycle process changes; Bun/other packages keep
  // their environment. Node retains proxy credentials privately, with normal TLS.
  agentModule.globalAgent = agent;
  delete env.HTTPS_PROXY;
  delete env.https_proxy;
  return true;
}

module.exports = { configureProxy };
configureProxy({ argv: process.argv, env: process.env, agentModule: https,
  version: process.versions.node,
  readPackage: file => JSON.parse(fs.readFileSync(file, 'utf8')) });
