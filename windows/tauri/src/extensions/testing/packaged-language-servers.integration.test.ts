import { expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { mkdtemp, mkdir, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { pluginCore } from "../packages/plugin-core";
import { useRealPluginCore } from "./plugin-core-backend";

const root = fileURLToPath(new URL("../../../../../", import.meta.url));
const requested = process.env.LITHE_RUN_PLUGIN_INTEGRATION === "1";
interface RuntimeEvent { state?: string; error?: { message: string } }

async function stopAndConfirm(sessionId: string) {
  await pluginCore.execute("lsp.stopServer", { sessionId });
  const deadline = performance.now() + 6000;
  let failure: unknown;
  while (performance.now() < deadline) {
    try { await pluginCore.execute("lsp.destroyServer", { sessionId }); return; }
    catch (error) { failure = error; }
    // Wait on Core's bounded event channel instead of sleeping between retries.
    await pluginCore.execute("lsp.waitEvents", { sessionId, timeoutMilliseconds: 250 }).catch(() => undefined);
  }
  throw failure;
}

// Explicit integration lane: missing artifacts/tools must fail, never silently skip.
for (const language of ["php", "go"]) {
  test.skipIf(!requested)(`packaged ${language} initializes, restarts and keeps resources unchanged`, async () => {
    const restore = useRealPluginCore();
    const temporary = await mkdtemp(path.join(tmpdir(), "lithe-plugin-integration-"));
    let sessionId: string | undefined;
    try {
      const output = path.join(root, ".artifacts/windows-plugins");
      const filename = (await readdir(output)).find((file) => file.startsWith(`lithe.${language}-`) && file.endsWith("windows-x86_64.test-signed.lithe-extension"));
      if (!filename) throw new Error(`Build the ${language} integration package first`);
      const bundle: { files: Record<string, string>; signature: { files: Record<string, string> } } =
        JSON.parse(await readFile(path.join(output, filename), "utf8"));
      const manifest = JSON.parse(Buffer.from(bundle.files["plugin.json"], "base64").toString());
      const payload = path.join(temporary, "payload");
      for (const [relative, encoded] of Object.entries(bundle.files)) {
        if (relative.includes("..") || path.isAbsolute(relative)) throw new Error("Unsafe fixture path");
        const bytes = Buffer.from(encoded, "base64");
        expect(createHash("sha256").update(bytes).digest("hex")).toBe(bundle.signature.files[relative]);
        const destination = path.join(payload, relative);
        await mkdir(path.dirname(destination), { recursive: true });
        await writeFile(destination, bytes);
      }
      const workspace = path.join(temporary, "workspace");
      await mkdir(workspace);
      const document = path.join(workspace, language === "go" ? "main.go" : "index.php");
      const text = language === "go" ? 'package main\nfunc main() {}\n' : '<?php\nfunction greet(): string { return "hello"; }\n';
      await writeFile(document, text);
      if (language === "go") await writeFile(path.join(workspace, "go.mod"), "module example.com/lithefixture\n\ngo 1.26.0\n");
      const entry = path.join(payload, manifest.lsp.server.default);
      const executable = language === "php" ? (Bun.which("node") ?? "node")
        : process.platform === "win32" ? entry : process.env.LITHE_GOPLS_TEST_EXECUTABLE;
      if (!executable) throw new Error("Configure LITHE_GOPLS_TEST_EXECUTABLE on non-Windows hosts");
      for (let iteration = 0; iteration < 2; iteration++) {
        const started = await pluginCore.execute<{ sessionId: string }>("lsp.startServer", {
          providerId: language, executablePath: executable,
          arguments: language === "php" ? [entry, ...manifest.lsp.args] : manifest.lsp.args,
          environment: { ...process.env, GOTELEMETRY: "off", GOCACHE: path.join(temporary, "go-cache") },
          rootUri: pathToFileURL(workspace).href, workingDirectory: workspace,
          initializationOptions: language === "php" ? { storagePath: path.join(temporary, "php-cache") } : null,
          initializeTimeoutMilliseconds: 15000, requestTimeoutMilliseconds: 10000, shutdownTimeoutMilliseconds: 2000,
        });
        sessionId = started.sessionId;
        const deadline = performance.now() + 16000;
        let ready = false;
        while (!ready && performance.now() < deadline) {
          const { events } = await pluginCore.execute<{ events: RuntimeEvent[] }>("lsp.waitEvents", { sessionId, timeoutMilliseconds: 250 });
          for (const event of events) {
            if (event.error) throw new Error(event.error.message);
            if (event.state === "ready") ready = true;
          }
        }
        expect(ready).toBe(true);
        await pluginCore.execute("lsp.syncDocument", { sessionId, uri: pathToFileURL(document).href, languageId: language, text });
        await pluginCore.execute("lsp.closeDocument", { sessionId, uri: pathToFileURL(document).href });
        await stopAndConfirm(sessionId);
        sessionId = undefined;
      }
      for (const [relative, expected] of Object.entries(bundle.signature.files)) {
        expect(createHash("sha256").update(await readFile(path.join(payload, relative))).digest("hex")).toBe(expected);
      }
    } finally {
      try {
        if (sessionId) {
          await stopAndConfirm(sessionId);
        }
      } finally {
        await rm(temporary, { recursive: true, force: true });
        restore();
      }
    }
  }, 45000);
}
