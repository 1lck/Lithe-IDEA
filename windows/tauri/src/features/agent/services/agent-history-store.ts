/**
 * Persistence for Lithe's own history annotations.
 *
 * Annotations live in the platform store (`agent-history.json`), never in an
 * installed bundle and never in the Agent's files: the release baseline is
 * read-only at runtime, and the Agent's own session records must survive a
 * removal here. This is the only module that touches the store; the reduction
 * itself lives in `agent-history-annotations.ts`.
 */

import { load, type Store } from "@tauri-apps/plugin-store";
import { agentHistoryKey, parseAgentHistoryMetadata } from "./agent-history-annotations";
import type { AgentHistoryMetadataMap } from "../types/agent-history.types";

const STORE_FILE = "agent-history.json";

let storePromise: Promise<Store> | null = null;

export async function getAgentHistoryStore(): Promise<Store> {
  if (!storePromise) {
    storePromise = load(STORE_FILE, {
      autoSave: true,
    } as Parameters<typeof load>[1]).catch((error: unknown) => {
      storePromise = null;
      throw error;
    });
  }
  return storePromise;
}

export async function readAgentHistoryMetadata(
  workspacePath: string,
  agentID: string,
): Promise<AgentHistoryMetadataMap> {
  const store = await getAgentHistoryStore();
  return parseAgentHistoryMetadata(
    await store.get<unknown>(agentHistoryKey(workspacePath, agentID)),
  );
}

export async function writeAgentHistoryMetadata(
  workspacePath: string,
  agentID: string,
  metadata: AgentHistoryMetadataMap,
): Promise<void> {
  const store = await getAgentHistoryStore();
  await store.set(agentHistoryKey(workspacePath, agentID), metadata);
  await store.save();
}
