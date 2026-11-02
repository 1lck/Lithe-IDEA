import { describe, expect, test } from "bun:test";
import { isWorkspaceRelativePath, resolveWorkspaceSourcePath } from "./build-output-path";

/**
 * Guard tests for the navigation boundary: only a plain workspace-relative
 * path may become a clickable source location. Virtual schemes, absolute
 * drives and UNC roots, and traversal segments stay plain text, mirroring
 * the macOS BuildOutputSourcePath rule at the Windows view boundary.
 */

const ROOT = "C:/work/output-path-fixture";

describe("build output source path guard", () => {
  test("a plain workspace-relative path resolves under the workspace root", () => {
    const resolved = resolveWorkspaceSourcePath(ROOT, "src/main.rs");
    expect(resolved).not.toBeNull();
    expect(resolved!.replace(/\\/g, "/")).toBe(`${ROOT}/src/main.rs`);
    expect(resolveWorkspaceSourcePath("C:/work/x", "a/b/Cargo.toml")!.replace(/\\/g, "/")).toBe(
      "C:/work/x/a/b/Cargo.toml",
    );
  });

  test("virtual schemes are never links", () => {
    for (const path of [
      "remote://host/share/file.rs",
      "wsl://Ubuntu/home/x/a.rs",
      "file:///C:/work/x/a.rs",
    ]) {
      expect(isWorkspaceRelativePath(path)).toBe(false);
      expect(resolveWorkspaceSourcePath(ROOT, path)).toBeNull();
    }
  });

  test("absolute and UNC paths are never links", () => {
    for (const path of [
      "C:/work/other/a.rs",
      "C:\\src\\a.rs",
      "/etc/hosts",
      "\\\\server\\share\\a.rs",
      "//server/share/a.rs",
    ]) {
      expect(isWorkspaceRelativePath(path)).toBe(false);
      expect(resolveWorkspaceSourcePath(ROOT, path)).toBeNull();
    }
  });

  test("traversal and empty segments are refused", () => {
    for (const path of ["..", "../a.rs", "a/../b.rs", "a//b.rs", "/a.rs", "./a.rs", ""]) {
      expect(isWorkspaceRelativePath(path)).toBe(false);
      expect(resolveWorkspaceSourcePath(ROOT, path)).toBeNull();
    }
  });

  test("Windows-reserved characters are refused", () => {
    for (const path of ["a<b.rs", "a>b.rs", "a:b.rs", 'a"b.rs', "a|b.rs", "a?b.rs", "a*b.rs"]) {
      expect(isWorkspaceRelativePath(path)).toBe(false);
    }
  });

  test("backslash escapes, device names, trailing aliases and control characters cannot become files", () => {
    for (const path of [
      "src\\..\\outside.rs",
      "a/..\\outside.rs",
      "CON",
      "nul.txt",
      "dir/COM1.rs",
      "dir/LPT2",
      "a. /main.rs",
      "dir./a.rs",
      "dir/a.rs ",
      "a\u0001.rs",
    ]) {
      expect(resolveWorkspaceSourcePath(ROOT, path)).toBeNull();
    }
  });

  test("roots must be native absolute directories without virtual schemes or lexical escapes", () => {
    for (const root of [
      "relative/path",
      "C:relative",
      "remote://host/work",
      "wsl://distro/work",
      "file:///C:/work",
      "C:/work/../outside",
      "//./pipe",
      "//server",
      "C:/work/./app",
      "C:/work//app",
    ]) {
      expect(resolveWorkspaceSourcePath(root, "src/main.rs")).toBeNull();
    }
    expect(
      resolveWorkspaceSourcePath("C:\\work\\with spaces", "src/main.rs")!.replace(/\\/g, "/"),
    ).toBe("C:/work/with spaces/src/main.rs");
    expect(
      resolveWorkspaceSourcePath("\\\\server\\share\\app", "src/main.rs")!.replace(/\\/g, "/"),
    ).toBe("//server/share/app/src/main.rs");
    expect(resolveWorkspaceSourcePath("C:/", "src/main.rs")!.replace(/\\/g, "/")).toBe(
      "C:/src/main.rs",
    );
    expect(resolveWorkspaceSourcePath(ROOT, "../output-path-fixture-sibling/a.rs")).toBeNull();
  });

  test("an empty workspace root refuses everything", () => {
    expect(resolveWorkspaceSourcePath("", "src/main.rs")).toBeNull();
  });
});
