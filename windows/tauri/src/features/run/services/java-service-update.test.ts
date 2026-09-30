import { describe, expect, test } from "bun:test";
import { supportsDevToolsUpdate, updateJavaService } from "./java-service-update";

function harness() {
  const calls: string[] = [];
  let current = true;
  return {
    calls,
    stop: () => {
      current = false;
    },
    workflow: {
      isCurrent: () => current,
      save: async () => {
        calls.push("save");
      },
      build: async () => {
        calls.push("build");
      },
      apply: async () => {
        calls.push("apply");
        return ["example.Service"];
      },
      report: (message: string) => calls.push(message),
    },
  };
}

describe("running Java service updates", () => {
  test("saves and builds before applying to the JVM", async () => {
    const { calls, workflow } = harness();
    await updateJavaService(workflow);
    expect(calls).toEqual([
      "Saving and compiling service changes…",
      "save",
      "build",
      "Applying code changes…",
      "apply",
      "Code changes applied.",
    ]);
  });
  test("compile failure cannot reach hot replacement", async () => {
    const { calls, workflow } = harness();
    workflow.build = async () => {
      throw new Error("Compilation errors");
    };
    await updateJavaService(workflow);
    expect(calls).not.toContain("apply");
    expect(calls[calls.length - 1]).toContain("Compilation errors");
  });
  test("stopping during save prevents compilation", async () => {
    const h = harness();
    h.workflow.save = async () => h.stop();
    await updateJavaService(h.workflow);
    expect(h.calls).not.toContain("build");
    expect(h.calls).not.toContain("apply");
  });
  test("replacement execution during build cannot receive old update", async () => {
    const h = harness();
    h.workflow.build = async () => h.stop();
    await updateJavaService(h.workflow);
    expect(h.calls).not.toContain("apply");
    expect(h.calls).not.toContain("Code changes applied.");
  });
  test("late application success is ignored after session end", async () => {
    const h = harness();
    h.workflow.apply = async () => {
      h.stop();
      return ["example.Service"];
    };
    await updateJavaService(h.workflow);
    expect(h.calls).not.toContain("Code changes applied.");
  });
  test("empty replacement is not reported as changed code", async () => {
    const h = harness();
    h.workflow.apply = async () => [];
    await updateJavaService(h.workflow);
    expect(h.calls[h.calls.length - 1]).toBe("No code changes to apply.");
  });
  test("DevTools compilation does not claim service readiness", async () => {
    const {
      calls,
      workflow: { apply: _, ...workflow },
    } = harness();
    await updateJavaService(workflow);
    expect(calls[calls.length - 1]).toContain("Check service logs");
  });
  test("requires the runtime DevTools jar and excludes debug launches", () => {
    const context = {
      sourcePath: "src/Main.java",
      target: {
        mainClass: "Main",
        modulePaths: [],
        classPaths: ["C:\\repo\\spring-boot-devtools-3.5.0.jar"],
      },
    };
    expect(supportsDevToolsUpdate(context)).toBe(true);
    expect(supportsDevToolsUpdate({ ...context, debugPort: 5005 })).toBe(false);
    expect(supportsDevToolsUpdate(undefined)).toBe(false);
    expect(
      supportsDevToolsUpdate({
        ...context,
        target: {
          ...context.target,
          classPaths: ["/spring-boot-devtools-3.5.0.jar/unrelated.jar"],
        },
      }),
    ).toBe(false);
  });
});
