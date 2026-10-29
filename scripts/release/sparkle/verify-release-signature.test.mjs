import assert from 'node:assert/strict';
import { createPrivateKey, createPublicKey, sign } from 'node:crypto';
import test from 'node:test';
import { verifyReleaseSignature } from './verify-release-signature.mjs';

function fixtureKey(seed) {
  const key = createPrivateKey({
    key: Buffer.concat([Buffer.from('302e020100300506032b657004220420', 'hex'), Buffer.alloc(32, seed)]),
    format: 'der', type: 'pkcs8',
  });
  return { key, publicKey: createPublicKey(key).export({ format: 'der', type: 'spki' }).subarray(-32).toString('base64') };
}

const { key, publicKey } = fixtureKey(1);
const data = Buffer.from('release verification fixture');
const signature = sign(null, data, key).toString('base64');

test('accepts an archive signed by the client trust key', () => {
  assert.doesNotThrow(() => verifyReleaseSignature(data, signature, publicKey));
});
test('rejects tampered archive bytes', () => {
  assert.throws(() => verifyReleaseSignature(Buffer.from('tampered'), signature, publicKey), /does not match/);
});
test('rejects a different client trust key', () => {
  assert.throws(() => verifyReleaseSignature(data, signature, fixtureKey(2).publicKey), /does not match/);
});
test('rejects truncated keys and signatures', () => {
  assert.throws(() => verifyReleaseSignature(data, 'AA==', publicKey), /length/);
  assert.throws(() => verifyReleaseSignature(data, signature, 'AA=='), /length/);
});
