import { expect, test } from "bun:test";
import { fileURLToPath } from "node:url";

test("run service menu interaction regression", async () => {
  // Base UI detects DOM availability at module load. Isolate the real menu from
  // store tests that import UI dependencies before installing their DOM.
  const child = Bun.spawn([
    process.execPath,
    "test",
    fileURLToPath(new URL("./run-services-menu.scenario.tsx", import.meta.url)),
    "--timeout", "5000",
  ], { stdout: "pipe", stderr: "pipe", timeout: 10000 });
  try {
    const [code, stdout, stderr] = await Promise.all([
      child.exited,
      new Response(child.stdout).text(),
      new Response(child.stderr).text(),
    ]);
    expect({ code, output: code === 0 ? "" : stdout + stderr }).toEqual({ code: 0, output: "" });
  } finally {
    if (child.exitCode === null) child.kill();
    await child.exited;
  }
}, 15000);
