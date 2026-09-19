import { expect, test } from "bun:test";
import { bootstrapWorkspaceGit, runGitBeforeJava } from "./workspace-startup-priority";

type Deferred = {
  promise: Promise<void>;
  resolve: () => void;
};

function deferred(): Deferred {
  let resolve!: () => void;
  const promise = new Promise<void>((resolver) => {
    resolve = resolver;
  });
  return { promise, resolve };
}

test("starts Java only after the initial Git bootstrap completes", async () => {
  const gitBootstrap = deferred();
  const events: string[] = [];
  const startup = runGitBeforeJava({
    bootstrapGit: async () => {
      events.push("git-started");
      await gitBootstrap.promise;
      events.push("git-finished");
    },
    isCurrent: () => true,
    startJava: () => events.push("java-started"),
  });

  expect(events).toEqual(["git-started"]);
  gitBootstrap.resolve();

  expect(await startup).toBe("started");
  expect(events).toEqual(["git-started", "git-finished", "java-started"]);
});

test("does not start Java when the workspace changes during Git bootstrap", async () => {
  const gitBootstrap = deferred();
  let current = true;
  let javaStarts = 0;
  const startup = runGitBeforeJava({
    bootstrapGit: () => gitBootstrap.promise,
    isCurrent: () => current,
    startJava: () => {
      javaStarts += 1;
    },
  });

  current = false;
  gitBootstrap.resolve();

  expect(await startup).toBe("superseded");
  expect(javaStarts).toBe(0);
});

test("loads every discovered repository before publishing workspace Git status", async () => {
  const events: string[] = [];
  const result = await bootstrapWorkspaceGit({
    workspaceRootPaths: ["C:/workspace"],
    discoverRepositories: async (roots) => {
      events.push(`discover:${roots.join(",")}`);
      return ["C:/workspace/api", "C:/workspace/web"];
    },
    loadStatus: async (repoPaths, activeRepoPath) => {
      events.push(`status:${repoPaths.join(",")}:${activeRepoPath}`);
      return "snapshot";
    },
    isCurrent: () => true,
    publishStatus: (status) => events.push(`publish:${status}`),
  });

  expect(result).toBe("published");
  expect(events).toEqual([
    "discover:C:/workspace",
    "status:C:/workspace/api,C:/workspace/web:C:/workspace/api",
    "publish:snapshot",
  ]);
});

test("starts Java after a failed Git attempt without hiding the failure", async () => {
  const failure = new Error("Git status timed out");
  const errors: unknown[] = [];
  let javaStarts = 0;

  const result = await runGitBeforeJava({
    bootstrapGit: async () => {
      throw failure;
    },
    isCurrent: () => true,
    onGitBootstrapError: (error) => errors.push(error),
    startJava: () => {
      javaStarts += 1;
    },
  });

  expect(result).toBe("started");
  expect(errors).toEqual([failure]);
  expect(javaStarts).toBe(1);
});
