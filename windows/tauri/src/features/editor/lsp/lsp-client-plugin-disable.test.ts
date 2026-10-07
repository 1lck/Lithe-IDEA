import { describe, expect, test, spyOn } from "bun:test";
import * as adapter from "@/platform/lsp-core-adapter";
import { LspClient } from "./lsp-client";

describe("language extension shutdown", () => {
  test("stops every attached file for the disabled language and leaves other languages running", async () => {
    const goServer = "C:/work:go";
    const rustServer = "C:/work:rust";
    const activeLanguageServers = new Set([goServer, rustServer]);
    const activeServerFiles = new Map([
      [goServer, new Set(["C:/work/main.go", "C:/work/util.go"])],
      [rustServer, new Set(["C:/work/main.rs"])],
    ]);
    const stoppedFiles: string[] = [];
    const client = Object.create(LspClient.prototype) as LspClient;
    Object.assign(client, {
      activeLanguageServers,
      activeServerFiles,
      fileStartTasks: new Map(),
      workspaceStartTasks: new Map(),
      serverScopes: new Map(),
      activeLanguages: new Set(),
      failedLanguageServers: new Map(),
      updateLspStatus: () => {},
    });
    client.stopForFile = async (filePath) => {
      stoppedFiles.push(filePath);
      const paths = activeServerFiles.get(goServer);
      paths?.delete(filePath);
      if (paths?.size === 0) activeLanguageServers.delete(goServer);
    };

    await client.stopLanguageServers(["go"]);

    expect(stoppedFiles).toEqual(["C:/work/main.go", "C:/work/util.go"]);
    expect(activeLanguageServers.has(goServer)).toBe(false);
    expect(activeLanguageServers.has(rustServer)).toBe(true);
  });

  test("retains tracking when the native owner cannot confirm shutdown", async () => {
    const serverKey = "C:/work:go";
    const client = Object.create(LspClient.prototype) as LspClient;
    const activeLanguageServers = new Set([serverKey]);
    Object.assign(client, {
      activeLanguageServers, fileStartTasks: new Map(), workspaceStartTasks: new Map(),
    });
    const stop = spyOn(adapter, "invokeLsp").mockRejectedValue(new Error("Native cleanup failed"));
    try {
      await expect(client.stopLanguageServers(["go"])).rejects.toThrow("Native cleanup failed");
      expect(activeLanguageServers.has(serverKey)).toBe(true);
    } finally { stop.mockRestore(); }
  });

  test("clears a workspace-only plugin after native shutdown confirms absence", async () => {
    const serverKey = "C:/work:go";
    const client = Object.create(LspClient.prototype) as LspClient;
    const activeLanguageServers = new Set([serverKey]);
    Object.assign(client, {
      activeLanguageServers, activeServerFiles: new Map(),
      fileStartTasks: new Map(), workspaceStartTasks: new Map(),
      serverScopes: new Map(), activeLanguages: new Set(), failedLanguageServers: new Map(),
      updateLspStatus: () => {},
    });
    await client.stopLanguageServers(["go"]);
    expect(activeLanguageServers.has(serverKey)).toBe(false);
  });
});
