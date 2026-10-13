// Observe npm's own HTTP downloads without changing stream consumption, cache,
// registry, proxy, retries, or package installation. Only numbers reach Lithe.
import { subscribe } from "node:diagnostics_channel";

const originalOptions = process.env.LITHE_NPM_ORIGINAL_NODE_OPTIONS;
if (originalOptions) process.env.NODE_OPTIONS = originalOptions;
else delete process.env.NODE_OPTIONS;
delete process.env.LITHE_NPM_ORIGINAL_NODE_OPTIONS;

const started = performance.now();
let downloadedBytes = 0;
let activeDownloads = 0;
let previousBytes = 0;
let previousTime = started;
let lastReceived = started;
const prefix = "LITHE_NPM_PROGRESS ";
function report() {
  const now = performance.now();
  const seconds = (now - previousTime) / 1000;
  const bytesPerSecond = seconds > 0 ? (downloadedBytes - previousBytes) / seconds : 0;
  previousBytes = downloadedBytes;
  previousTime = now;
  process.stderr.write(prefix + JSON.stringify({
    stage: activeDownloads > 0 ? "downloading" : downloadedBytes > 0 ? "installing" : "preparing",
    downloadedBytes,
    bytesPerSecond: Math.round(bytesPerSecond),
    elapsedMilliseconds: Math.round(now - started),
    idleMilliseconds: Math.round(now - lastReceived),
  }) + "\n");
}
subscribe("http.client.response.finish", ({ request, response }) => {
  // Registry metadata, redirects, and errors are not package downloads.
  if (response.statusCode < 200 || response.statusCode >= 300 ||
      !request.path.split("?")[0].endsWith(".tgz")) return;
  activeDownloads += 1;
  let finished = false;
  const finish = () => {
    if (!finished) { finished = true; activeDownloads -= 1; report(); }
  };
  report();
  response.once("close", finish);
  const push = response.push;
  response.push = function (chunk, encoding) {
    if (chunk !== null) {
      downloadedBytes += Buffer.isBuffer(chunk) ? chunk.length : Buffer.byteLength(chunk, encoding);
      lastReceived = performance.now();
    } else finish();
    // Preserve npm's own backpressure and EOF handling; never add a data listener.
    return push.call(this, chunk, encoding);
  };
});
report();
const timer = setInterval(report, 500);
timer.unref();
process.once("exit", () => clearInterval(timer));
