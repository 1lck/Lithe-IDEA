// Keep upstream install.js and TLS verification; Node owns CONNECT and redirects.
const path = require('node:path');
const fs = require('node:fs');
const https = require('node:https');

function configureProxy({ argv, env, agentModule, version, readPackage }) {
  if (!argv[1] || path.basename(argv[1]) !== 'install.js') return false;
  const proxy = env.HTTPS_PROXY || env.https_proxy;
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
  // Snapshot before removing the two variables consumed by upstream's manual
  // CONNECT branch. Only this lifecycle process changes; Bun/other packages keep
  // their environment. Node retains proxy credentials privately, with normal TLS.
  agentModule.globalAgent = new agentModule.Agent({ proxyEnv: { ...env } });
  delete env.HTTPS_PROXY;
  delete env.https_proxy;
  return true;
}

module.exports = { configureProxy };
configureProxy({ argv: process.argv, env: process.env, agentModule: https,
  version: process.versions.node,
  readPackage: file => JSON.parse(fs.readFileSync(file, 'utf8')) });
