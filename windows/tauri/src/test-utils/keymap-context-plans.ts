import { spyOn } from "bun:test";
import * as native from "@/platform/tauri-core";
import fixture from "../../../../shared/fixtures/keymap/context-v1.json";
import type { ParsedContext } from "@/features/keymaps/utils/context";

/** Fixed Core-verified plans for routing tests; this helper never parses expressions. */
export function installKeymapContextPlans() {
  const original = native.invoke;
  const plans: Record<string, ParsedContext> = fixture.bundledPlans;
  return spyOn(native, "invoke").mockImplementation(async <T>(command: string, payload?: unknown): Promise<T> => {
    if (command !== "keymap.parseContext") return original<T>(command, payload as Record<string, unknown>);
    const expression = (payload as { expression: string }).expression;
    return {
      parsed: plans[expression] ?? null,
      error: plans[expression] ? null : { code: "invalid_character", byteOffset: 0 },
    } as T;
  });
}
