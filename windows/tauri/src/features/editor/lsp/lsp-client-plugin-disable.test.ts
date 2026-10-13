import { describe, expect, test } from "bun:test";
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

  test("reports a server that remains active after all attachments stop", async () => {
    const serverKey = "C:/work:go";
    const client = Object.create(LspClient.prototype) as LspClient;
    Object.assign(client, {
      activeLanguageServers: new Set([serverKey]),
      activeServerFiles: new Map([[serverKey, new Set(["C:/work/main.go"])]]),
      fileStartTasks: new Map(),
      workspaceStartTasks: new Map(),
    });
    client.stopForFile = async () => {};

    await expect(client.stopLanguageServers(["go"])).rejects.toThrow(
      "Language server remained active",
    );
  });
});
