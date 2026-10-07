import { spyOn } from "bun:test";
import { CString, dlopen, FFIType, ptr, suffix } from "bun:ffi";
import { fileURLToPath } from "node:url";
import { pluginCore } from "../packages/plugin-core";

/** Exercise the shipped JSON ABI, without a parallel TypeScript state machine. */
export function useRealPluginCore() {
  const name = process.platform === "win32" ? `lithe_core.${suffix}` : `liblithe_core.${suffix}`;
  const libraryPath = process.env.LITHE_CORE_TEST_LIBRARY ?? fileURLToPath(
    new URL(`../../../../../rust/target/debug/${name}`, import.meta.url),
  );
  const library = dlopen(libraryPath, {
    lithe_core_execute_json: { args: [FFIType.ptr], returns: FFIType.ptr },
    lithe_core_free_string: { args: [FFIType.ptr], returns: FFIType.void },
  });
  const testOwner = crypto.randomUUID();
  const transport = spyOn(pluginCore, "execute").mockImplementation((async (command, payload) => {
    const fields = { ...payload };
    if (typeof fields.ownerId === "string") fields.ownerId = `${testOwner}:${fields.ownerId}`;
    const input = Buffer.from(JSON.stringify({ id: crypto.randomUUID(), command, payload: fields }) + "\0");
    const pointer = library.symbols.lithe_core_execute_json(ptr(input));
    if (!pointer) throw new Error("Core returned a null response");
    try {
      const response = JSON.parse(new CString(pointer).toString());
      if (!response.ok) throw new Error(response.error.message);
      return response.data;
    } finally { library.symbols.lithe_core_free_string(pointer); }
  }) as typeof pluginCore.execute);
  return () => {
    transport.mockRestore();
    library.close();
  };
}
