import { expect, spyOn, test } from "bun:test";
import * as native from "@/platform/tauri-core";
import { resolvePluginWebFilePath } from "./plugin-web-path";

test("open-file uses the native resolved target and propagates boundary rejection", async () => {
  const invoke = spyOn(native, "invoke").mockResolvedValue("C:/work/inside.txt");
  try {
    expect(await resolvePluginWebFilePath("C:/work/link.txt", "C:/work")).toBe("C:/work/inside.txt");
    expect(invoke).toHaveBeenCalledWith("declarative_plugins_web_resolve_file", {
      path: "C:/work/link.txt", workspacePath: "C:/work",
    });
    invoke.mockRejectedValue({ code: "plugin.web.forbidden" });
    await expect(resolvePluginWebFilePath("C:/work/escape.txt", "C:/work")).rejects.toEqual({ code: "plugin.web.forbidden" });
  } finally { invoke.mockRestore(); }
});
