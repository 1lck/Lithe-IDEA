import type { toast as sonnerToast } from "sonner";

interface MavenProfileTaskEffects {
  toast: Pick<typeof sonnerToast, "loading" | "success" | "warning" | "error" | "dismiss">;
  clearProjects: (sessionId: string) => void;
  retry: (sessionId: string) => Promise<unknown>;
}

export function presentMavenProfileTask(
  task: { sessionId: string; status: string },
  effects: MavenProfileTaskEffects,
): void {
  const id = `java-maven-profiles:${task.sessionId}`;
  if (task.status === "running") {
    effects.clearProjects(task.sessionId);
    effects.toast.loading("Applying Maven configuration", { id, action: undefined });
  } else if (["succeeded", "cancelled", "idle"].includes(task.status)) {
    // Profile commands returning says nothing about dependency resolution, so
    // success is not announced. Resolution failures surface as Maven problems
    // read from pom.xml diagnostics instead (#970).
    effects.toast.dismiss(id);
  } else if (["failed", "timedOut", "partiallySucceeded"].includes(task.status)) {
    effects.toast.warning("Some Maven modules failed to update; the language service remains available", {
      id,
      duration: Infinity,
      action: {
        label: "Retry",
        onClick: (event) => {
          event.preventDefault();
          void effects.retry(task.sessionId).catch((error: unknown) => {
            // Keep the recoverable warning and its action until a task event
            // replaces it. Rejection must not dismiss the only retry entry.
            effects.toast.error(error instanceof Error ? error.message : String(error), {
              id: `${id}:retry-error`, duration: 8000,
            });
          });
        },
      },
    });
  }
}
