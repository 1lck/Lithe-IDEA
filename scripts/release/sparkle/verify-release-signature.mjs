import { createPublicKey, verify } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

export function verifyReleaseSignature(data, signatureBase64, publicKeyBase64) {
  const publicKey = Buffer.from(publicKeyBase64.trim(), 'base64');
  const signature = Buffer.from(signatureBase64.trim(), 'base64');
  if (publicKey.length !== 32 || signature.length !== 64) {
    throw new Error('Invalid Ed25519 public key or signature length');
  }
  const key = createPublicKey({
    key: Buffer.concat([Buffer.from('302a300506032b6570032100', 'hex'), publicKey]),
    format: 'der',
    type: 'spki',
  });
  if (!verify(null, data, key, signature)) {
    throw new Error('Release signature does not match the client public key');
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const [asset, signature, publicKey, mode] = process.argv.slice(2);
  if (!asset || !signature || !publicKey) throw new Error('Expected asset, signature file, and public key');
  verifyReleaseSignature(readFileSync(asset), mode === '--inline' ? signature : readFileSync(signature, 'utf8'), publicKey);
  console.log(`Ed25519 release signature verified: ${asset}`);
}
