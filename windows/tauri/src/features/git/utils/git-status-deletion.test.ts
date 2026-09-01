import { describe, expect, mock, test } from "bun:test";
import { deleteGitStatusPaths } from "./git-status-deletion";

describe("Git status physical deletion", () => {
  test("attempts every selected file and refreshes after partial failure", async () => {
    const deletedPaths: string[] = [];
    const refresh = mock(async () => {});

    const result = await deleteGitStatusPaths(
      ["src/first.ts", "src/failing.ts", "src/last.ts"],
      async (path) => {
        deletedPaths.push(path);
        if (path === "src/failing.ts") throw new Error("locked");
      },
      refresh,
    );

    expect(deletedPaths).toEqual(["src/first.ts", "src/failing.ts", "src/last.ts"]);
    expect(result.failures.map((failure) => failure.path)).toEqual(["src/failing.ts"]);
    expect(refresh).toHaveBeenCalledTimes(1);
  });

  test("reports refresh failure separately from delete failures", async () => {
    const refreshError = new Error("refresh failed");
    const result = await deleteGitStatusPaths(
      ["src/file.ts"],
      async () => {},
      async () => {
        throw refreshError;
      },
    );

    expect(result).toEqual({ failures: [], refreshError });
  });
});
