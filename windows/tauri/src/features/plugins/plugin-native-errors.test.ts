import { expect, test } from "bun:test";
import { HostCommandError } from "@/platform/tauri-core";
import { translatePluginHostFailure } from "./plugin-native-errors";

test("plugin failures translate normalized host errors without hiding unknown failures", () => {
  for (const cause of ["toolchain.native.unavailable", new HostCommandError("build_tool", "toolchain.native.changed"),
    { code: "toolchain.native.limit", message: "native detail" }]) {
    const failure = translatePluginHostFailure(cause, key => `translated:${key}`) as Error & { cause: unknown };
    expect(failure.message).toBe("translated:native.selectedToolchainUnavailable");
    expect(failure.cause).toBe(cause);
  }
  const signature = translatePluginHostFailure(new HostCommandError("prepare_install", "plugin.packageSignature.invalid"), key => key) as Error;
  expect(signature.message).toBe("native.thePluginPackageSignatureIsInvalid");
  const unknown = new Error("provider diagnostic");
  expect(translatePluginHostFailure(unknown, () => "unused")).toBe(unknown);
});

test("Registry Debug failures use localized stable codes",()=>{
  for(const code of ["plugin.debug.unavailable","plugin.debug.ambiguous","plugin.debug.unsupportedTransport"]){
    expect((translatePluginHostFailure(code,key=>key) as Error).message).toBe("build.debug.unavailable");
  }
  expect((translatePluginHostFailure("plugin.debug.stale",key=>key) as Error).message).toBe("build.errors.inputsChanged");
});
