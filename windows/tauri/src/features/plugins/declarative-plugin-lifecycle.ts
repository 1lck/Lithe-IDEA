/** Per-window revocation, set synchronously before draining owned processes. */
const blocked = new Set<string>();
const revisions = new Map<string, number>();
const activityListeners = new Set<(pluginId: string) => void>();

export function setPluginActive(pluginId: string, active: boolean): void {
  revisions.set(pluginId, (revisions.get(pluginId) ?? 0) + 1);
  if (active) blocked.delete(pluginId);
  else blocked.add(pluginId);
  for (const listener of activityListeners) listener(pluginId);
}

/** Observe the same synchronous revocation used by launch-plan guards. */
export function subscribePluginActivity(listener: (pluginId: string) => void): () => void {
  activityListeners.add(listener);
  return () => activityListeners.delete(listener);
}

export function assertPluginActive(pluginId: string): void {
  if (blocked.has(pluginId)) throw new Error(`Plugin ${pluginId} is inactive or changing version.`);
}

/** Discard native plans resolved across any plugin catalog mutation. */
export function pluginPlanGuard(): (pluginId: string) => void {
  const startedAt = new Map(revisions);
  return (pluginId) => {
    assertPluginActive(pluginId);
    if ((startedAt.get(pluginId) ?? 0) !== (revisions.get(pluginId) ?? 0))
      throw new Error("Plugin launch plan was superseded.");
  };
}
