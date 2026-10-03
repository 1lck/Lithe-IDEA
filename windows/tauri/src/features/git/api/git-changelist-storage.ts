import { createJSONStorageFrom } from "@/utils/zustand-storage";

/** Protection metadata cannot fall back to temporary memory when preferences are inaccessible. */
export function createChangelistStorage<State>() {
  const storage = () => {
    const value = globalThis.localStorage;
    if (!value) throw new Error("Changelist storage is unavailable");
    return value;
  };
  return createJSONStorageFrom<State>({
    getItem: (name) => {
      const raw = storage().getItem(name);
      // Zustand otherwise conflates a stored JSON null with an absent preference.
      if (raw?.trim() === "null") throw new Error("Invalid changelist storage data");
      return raw;
    },
    setItem: (name, value) => storage().setItem(name, value),
    removeItem: (name) => storage().removeItem(name),
  });
}
