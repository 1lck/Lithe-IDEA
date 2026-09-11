export interface LifecycleEventIdentity {
  sessionId?: string;
  providerId?: string;
}

export function ownedLifecycleHandler<T extends LifecycleEventIdentity>(
  ownsSession: (sessionId: string) => boolean,
  handle: (payload: T & { sessionId: string }) => void,
): (event: { payload: T }) => void {
  return ({ payload }) => {
    if (!payload.sessionId || !ownsSession(payload.sessionId)) return;
    handle(payload as T & { sessionId: string });
  };
}

export function isJavaLifecycle(payload: LifecycleEventIdentity): boolean {
  return payload.providerId === "java";
}
