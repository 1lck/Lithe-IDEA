import { createReadStream } from "node:fs";
import { createHash } from "node:crypto";

async function sha256(file) {
  const digest = createHash("sha256");
  for await (const chunk of createReadStream(file)) digest.update(chunk);
  return digest.digest("hex");
}

/** Bound open streams while retaining input order. All started reads settle
 * before failure returns, so callers can safely remove their staging tree. */
export async function hashFileSet(files, { concurrency = 8, hash = sha256 } = {}) {
  if (!Number.isSafeInteger(concurrency) || concurrency < 1 || concurrency > 8)
    throw new Error("Hash concurrency must be an integer from 1 to 8");
  const hashes = new Array(files.length);
  let next = 0, failed = false, failure;
  await Promise.all(Array.from({ length: Math.min(concurrency, files.length) }, async () => {
    while (!failed) {
      const index = next++;
      if (index >= files.length) return;
      try { hashes[index] = await hash(files[index]); }
      catch (error) { if (!failed) { failed = true; failure = error; } }
    }
  }));
  if (failed) throw failure;
  return hashes;
}
