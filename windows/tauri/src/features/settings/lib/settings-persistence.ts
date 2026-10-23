import { load, type Store } from "@tauri-apps/plugin-store";
import isEqual from "fast-deep-equal";
import { invoke } from "@/platform/tauri-core";
import { normalizeAgentPanelSettings, type AgentPanelSettings } from "@/features/agent/types/agent-settings.types";
import {
  defaultSettings,
  getDefaultSettingsSnapshot,
} from "@/features/settings/config/default-settings";
import type { Settings } from "@/features/settings/types/settings.types";
import {
  findRetiredSettingsKeys,
  migrateHiddenPatternDefaults,
  migrateProjectOpenDestination,
} from "./settings-migrations";

let storeInstance: Store | null = null;
let storePromise: Promise<Store> | null = null;
let initialStoreEntries: Map<string, unknown> | null = null;
let agentPanelRevision: unknown;
let agentPanelQueue: Promise<unknown> = Promise.resolve();
let agentPanelPending = 0;
let publishAgentPanel: ((settings: AgentPanelSettings) => void) | null = null;

export function observeAgentPanelSettings(publish: (settings: AgentPanelSettings) => void) {
  publishAgentPanel = publish;
}

export interface AgentCredentialChange {
  agentId: string;
  providerId?: string;
  value: string;
}

/** Serialize this window's edits; the host compares the persisted revision atomically. */
export function commitAgentPanelSettings(expected: AgentPanelSettings, next: AgentPanelSettings, credential?: AgentCredentialChange): Promise<AgentPanelSettings> {
  agentPanelPending += 1;
  const operation = agentPanelQueue.then(async () => {
    await getSettingsStore();
    if (!isEqual(normalizeAgentPanelSettings(agentPanelRevision), normalizeAgentPanelSettings(expected))) {
      throw new Error("agent.settings.conflict");
    }
    await invoke("commit_agent_panel_settings", { expected: agentPanelRevision ?? null, next, credential: credential ?? null });
    agentPanelRevision = JSON.parse(JSON.stringify(next));
    return normalizeAgentPanelSettings(agentPanelRevision);
  });
  const settled = operation.finally(async () => {
    try {
      const store = await getSettingsStore();
      agentPanelRevision = await store.get("agentPanel");
      if (agentPanelPending === 1) publishAgentPanel?.(normalizeAgentPanelSettings(agentPanelRevision));
    } finally {
      agentPanelPending -= 1;
    }
  });
  agentPanelQueue = settled.catch(() => undefined);
  return settled;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

async function initializeStoreDefaults(store: Store) {
  const migration = migrateHiddenPatternDefaults(new Map(await store.entries<unknown>()));
  const projectOpenMigration = migrateProjectOpenDestination(migration.entries);
  const entries = projectOpenMigration.entries;
  const changes = [...migration.changes, ...projectOpenMigration.changes];
  const retiredKeys = findRetiredSettingsKeys(entries);
  for (const key of retiredKeys) entries.delete(key);

  for (const [key, defaultValue] of Object.entries(defaultSettings)) {
    const currentValue = entries.get(key);
    let nextValue = currentValue;

    if (currentValue === null || currentValue === undefined) {
      nextValue = defaultValue;
    } else if (isRecord(defaultValue)) {
      nextValue = isRecord(currentValue) ? { ...defaultValue, ...currentValue } : defaultValue;
    }

    entries.set(key, nextValue);
    // Agent settings have a native compare-and-swap writer, including first use.
    if (key !== "agentPanel" && !isEqual(currentValue, nextValue)) changes.push([key, nextValue]);
  }

  if (changes.length > 0 || retiredKeys.length > 0) {
    await Promise.all([
      ...changes.map(([key, value]) => store.set(key, value)),
      ...retiredKeys.map((key) => store.delete(key)),
    ]);
    await store.save();
  }

  initialStoreEntries = entries;
}

export async function getSettingsStore() {
  if (storeInstance) return storeInstance;

  if (!storePromise) {
    storePromise = (async () => {
      const store = await load("settings.json", {
        autoSave: true,
      } as Parameters<typeof load>[1]);
      await initializeStoreDefaults(store);
      agentPanelRevision = await store.get("agentPanel");
      await store.onKeyChange("agentPanel", (value) => {
        if (agentPanelPending > 0) return;
        agentPanelRevision = value;
        publishAgentPanel?.(normalizeAgentPanelSettings(value));
      });
      storeInstance = store;
      return store;
    })();
  }

  try {
    return await storePromise;
  } catch (error) {
    storePromise = null;
    throw error;
  }
}

export async function loadSettingsFromStore(): Promise<Settings> {
  const store = await getSettingsStore();
  const loadedSettings = getDefaultSettingsSnapshot();
  const entries = initialStoreEntries ?? new Map(await store.entries<unknown>());
  initialStoreEntries = null;

  for (const key of Object.keys(defaultSettings) as Array<keyof Settings>) {
    const value = entries.get(key);
    if (value !== null && value !== undefined) {
      (loadedSettings as Record<keyof Settings, Settings[keyof Settings]>)[key] =
        value as Settings[typeof key];
    }
  }

  return loadedSettings;
}

export async function saveSettingsToStore(settings: Partial<Settings>) {
  try {
    const store = await getSettingsStore();

    if (settings.agentPanel) {
      await commitAgentPanelSettings(normalizeAgentPanelSettings(agentPanelRevision), settings.agentPanel);
    }
    await Promise.all(Object.entries(settings).filter(([key]) => key !== "agentPanel").map(([key, value]) => store.set(key, value)));

    await store.save();
  } catch (error) {
    console.error("Failed to save settings to store:", error);
  }
}

let saveTimeout: ReturnType<typeof setTimeout> | null = null;
let pendingSettings: Partial<Settings> = {};

export function debouncedSaveSettingsToStore(settings: Partial<Settings>) {
  pendingSettings = { ...pendingSettings, ...settings };

  if (saveTimeout) {
    clearTimeout(saveTimeout);
  }

  saveTimeout = setTimeout(() => {
    const settingsToSave = pendingSettings;
    pendingSettings = {};
    saveTimeout = null;
    void saveSettingsToStore(settingsToSave);
  }, 300);
}
