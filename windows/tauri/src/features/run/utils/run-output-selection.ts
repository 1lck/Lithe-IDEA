import { PRIMARY_SESSION_ID, type RunSession } from "../types/run.types";

/** The visible configuration owns the detail pane even when another launch changes store focus. */
export function selectRunOutput(
  configurationId: string | null,
  sessions: RunSession[],
  primary: {
    configurationId: string | null;
    output: string;
    isRunning: boolean;
    exitCode: number | null;
  },
) {
  const session = sessions.find((entry) => entry.configurationId === configurationId);
  const ownsPrimary = configurationId === null || primary.configurationId === configurationId;
  return {
    session,
    sessionId: session?.id ?? PRIMARY_SESSION_ID,
    hasOutputOwner: Boolean(session) || ownsPrimary,
    output: session ? session.output : ownsPrimary ? primary.output : "",
    isRunning: session ? session.isRunning : ownsPrimary && primary.isRunning,
    exitCode: session ? session.exitCode : ownsPrimary ? primary.exitCode : null,
  };
}
