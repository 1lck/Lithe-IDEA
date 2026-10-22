import { describe, expect, test } from "bun:test";
import { validatedAttachmentUris } from "./agent-file-attachments";
import { agentFileUri } from "../types/agent-file-uri";

describe("Agent attachment validation", () => {
  test("encodes local and UNC files without losing Unicode or separators", () => {
    expect(agentFileUri("C:\\sample\\文 档#1.txt")).toBe("file:///C:/sample/%E6%96%87%20%E6%A1%A3%231.txt");
    expect(agentFileUri("\\\\server\\share\\a b.txt")).toBe("file://server/share/a%20b.txt");
    expect(() => agentFileUri("relative.txt")).toThrow();
    expect(() => agentFileUri("C:/bad\u0000.txt")).toThrow();
  });
  test("rejects the entire batch when any file is unavailable", async () => {
    await expect(validatedAttachmentUris(["C:/a.txt", "C:/missing.txt"], async (path) => !path.includes("missing"), () => true)).rejects.toThrow("agent.context.unavailable");
  });
  test("rejects results after the workspace or target changes during metadata reads", async () => {
    let current = true;
    await expect(validatedAttachmentUris(["C:/a.txt"], async () => { current = false; return true; }, () => current)).rejects.toThrow("agent.context.stale");
  });
  test("rejects an oversized batch before querying the filesystem", async () => {
    let calls = 0;
    await expect(validatedAttachmentUris(Array.from({ length: 33 }, (_, i) => `C:/${i}.txt`), async () => { calls++; return true; }, () => true)).rejects.toThrow();
    expect(calls).toBe(0);
  });
});
