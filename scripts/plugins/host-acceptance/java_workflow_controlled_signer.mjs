// Explicit diagnostic signer. A fresh in-memory key signs all packages in one
// invocation; no private key leaves this process and no official identity is used.
import { createHash, generateKeyPairSync, sign, verify } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';

const [input, output] = process.argv.slice(2);
if (!input || !output) throw new Error('Expected input and absent output JSON paths');
const packages = JSON.parse(readFileSync(input, 'utf8'));
if (!Array.isArray(packages) || packages.length !== 3) throw new Error('Expected complete Java/Maven/Gradle packages');
const { privateKey, publicKey } = generateKeyPairSync('ed25519');
const raw = publicKey.export({ format: 'jwk' }).x;
const publicKeyBytes = Buffer.from(raw, 'base64url');
const keyId = `lithe-controlled-java-${createHash('sha256').update(publicKeyBytes).digest('hex').slice(0, 16)}`;
const token = text => Buffer.from(text, 'utf8').toString('base64url');
const signatures = packages.map(({ pluginId, pluginVersion, files }) => {
  if (!pluginId || !pluginVersion || !files || Object.keys(files).length > 100000)
    throw new Error('Invalid bounded package inventory');
  const paths = Object.keys(files).sort((a, b) => Buffer.compare(Buffer.from(a), Buffer.from(b)));
  let payload = `schemaVersion=1\nalgorithm=ed25519\nkeyID=${keyId}\npluginID=${token(pluginId)}\npluginVersion=${token(pluginVersion)}\n`;
  for (const path of paths) {
    if (!/^[0-9a-f]{64}$/.test(files[path])) throw new Error('Invalid file digest');
    payload += `file=${token(path)}=${files[path]}\n`;
  }
  const signature = sign(null, Buffer.from(payload), privateKey);
  if (!verify(null, Buffer.from(payload), publicKey, signature)) throw new Error('Signature self-check failed');
  return { schemaVersion: 1, algorithm: 'ed25519', keyId, pluginId, pluginVersion, files, signature: signature.toString('base64') };
});
writeFileSync(output, JSON.stringify({ productionTrusted: false, keyId, publicKeyBase64: publicKeyBytes.toString('base64'), signatures }, null, 2) + '\n', { flag: 'wx' });
