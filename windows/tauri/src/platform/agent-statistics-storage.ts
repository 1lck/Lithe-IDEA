import { parseSessionStatistics, type AgentSessionStatistics } from "@/features/agent/types/agent-session-statistics";

const STORAGE_KEY = "lithe:agent-statistics:v1";
const RECORD_LIMIT = 200;
interface Entry { key: string; statistics: AgentSessionStatistics }

/** WebView profile storage is writable user data, isolated from packaged resources. */
function entries(): Entry[] {
  const value: unknown = JSON.parse(localStorage.getItem(STORAGE_KEY) ?? "[]");
  if (!Array.isArray(value)) return [];
  return value.slice(-RECORD_LIMIT).flatMap((entry) => {
    const statistics = parseSessionStatistics(entry?.statistics);
    return typeof entry?.key === "string" && statistics ? [{ key: entry.key, statistics }] : [];
  });
}
function key(workspace: string, agentID: string, sessionID: string): string {
  return JSON.stringify([workspace.replace(/\\/g, "/").toLowerCase(), agentID, sessionID]);
}
export function readAgentStatistics(workspace: string, agentID: string, sessionID: string): AgentSessionStatistics | null {
  try { return entries().find((entry) => entry.key === key(workspace, agentID, sessionID))?.statistics ?? null; }
  catch (error) { console.warn("Agent statistics could not be read", error); return null; }
}
export function writeAgentStatistics(workspace: string, agentID: string, sessionID: string, statistics: AgentSessionStatistics): void {
  if (statistics.turnCount === 0 && statistics.calls.calls === 0 && statistics.contextUsage === null) return;
  try {
    const id = key(workspace, agentID, sessionID);
    const previous = entries();
    if (JSON.stringify(previous.find((entry) => entry.key === id)?.statistics) === JSON.stringify(statistics)) return;
    localStorage.setItem(STORAGE_KEY, JSON.stringify([...previous.filter((entry) => entry.key !== id), { key: id, statistics }].slice(-RECORD_LIMIT)));
  } catch (error) { console.warn("Agent statistics could not be saved", error); }
}
