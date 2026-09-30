import type { JavaServiceUpdateContext } from "../types/run.types";

export function supportsDevToolsUpdate(context: JavaServiceUpdateContext | undefined): boolean {
  return Boolean(
    context &&
    !context.debugPort &&
    context.target.classPaths.some((path) =>
      /^spring-boot-devtools-[^/\\]+\.jar$/.test(path.split(/[\\/]/).pop() ?? ""),
    ),
  );
}

/** Checks execution identity after each asynchronous boundary, before touching the JVM. */
export async function updateJavaService(workflow: {
  isCurrent(): boolean;
  save(): Promise<void>;
  build(): Promise<void>;
  apply?: () => Promise<string[]>;
  report(message: string, failed?: boolean): void;
}): Promise<void> {
  const current = () => {
    if (!workflow.isCurrent()) throw new Error("The service execution changed. Update cancelled.");
  };
  try {
    current();
    workflow.report("Saving and compiling service changes…");
    await workflow.save();
    current();
    await workflow.build();
    current();
    if (workflow.apply) {
      workflow.report("Applying code changes…");
      const classes = await workflow.apply();
      current();
      workflow.report(classes.length ? "Code changes applied." : "No code changes to apply.");
    } else {
      workflow.report(
        "Compilation finished. Check service logs for the DevTools restart. If a trigger file is configured, update it to restart.",
      );
    }
  } catch (error) {
    if (workflow.isCurrent())
      workflow.report(
        `Could not update service: ${error instanceof Error ? error.message : String(error)}`,
        true,
      );
  }
}
