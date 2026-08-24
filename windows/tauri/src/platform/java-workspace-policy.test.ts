import { expect, mock, test } from "bun:test";
import { resolveJavaWorkspacePolicy } from "./java-workspace-policy";

test("routes workspace-relative Java paths through the shared Core contract", async () => {
  const executor = mock(async (_request: unknown) => ({
    id: "policy",
    ok: true as const,
    data: {
      shouldStart: true,
      representativeJavaPath: "src/Main.java",
      changes: [{ path: "pom.xml", kind: "buildConfiguration" as const }],
    },
  }));

  const policy = await resolveJavaWorkspacePolicy(
    ["src/Main.java", "target/Fake.java"],
    ["pom.xml"],
    executor,
  );

  expect(policy.representativeJavaPath).toBe("src/Main.java");
  expect(executor.mock.calls[0][0]).toMatchObject({
    command: "java.workspacePolicy",
    payload: {
      workspacePaths: ["src/Main.java", "target/Fake.java"],
      changedPaths: ["pom.xml"],
    },
  });
});
