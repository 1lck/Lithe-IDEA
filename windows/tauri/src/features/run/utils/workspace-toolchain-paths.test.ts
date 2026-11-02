import { expect, test } from "bun:test";
import { workspaceToolchainPath, workspaceToolchainSelection } from "./workspace-toolchain-paths";

test("relative JDK and opaque runtime selections resolve against the opened workspace with spaces", () => {
  const selected = { javaHomePath: "tools/JDK 21", mavenExecutablePath: "tools/maven/bin/mvn.cmd",
    mavenJavaHomePath: "tools/JDK 17", runtimeExecutablePaths: { "opaque-runtime": "tools/runtime.exe" } };
  expect(workspaceToolchainSelection("D:/workspace with spaces", selected)).toEqual({
    javaHomePath: "D:/workspace with spaces/tools/JDK 21",
    mavenExecutablePath: "D:/workspace with spaces/tools/maven/bin/mvn.cmd",
    mavenJavaHomePath: "D:/workspace with spaces/tools/JDK 17",
    runtimeExecutablePaths: { "opaque-runtime": "D:/workspace with spaces/tools/runtime.exe" },
  });
  expect(selected.javaHomePath).toBe("tools/JDK 21");
});

test("workspace switching recomputes selections without writing or retaining the old root", () => {
  const selected = { javaHomePath: "jdk", mavenExecutablePath: "", mavenJavaHomePath: "",
    runtimeExecutablePaths: { java: "jdk/bin/java.exe" } };
  expect(workspaceToolchainSelection("C:/one", selected).runtimeExecutablePaths.java).toBe("C:/one/jdk/bin/java.exe");
  expect(workspaceToolchainSelection("C:/two", selected).runtimeExecutablePaths.java).toBe("C:/two/jdk/bin/java.exe");
  expect(workspaceToolchainSelection("C:/one", selected).javaHomePath).toBe("C:/one/jdk");
});

test("absolute and UNC selections stay absolute; native validation retains malformed drive-relative inputs", () => {
  for (const [input, expected] of [["C:\\JDK 21", "C:/JDK 21"], ["\\\\server\\share\\jdk", "//server/share/jdk"],
    ["D:bad.exe", "D:bad.exe"], ["", ""], ["   ", ""]]) {
    expect(workspaceToolchainPath("C:/workspace", input)).toBe(expected);
  }
});


test("dot-relative selections match canonical candidates without escaping drive or UNC anchors", () => {
  expect(workspaceToolchainPath("D:/work/project", "./tools/../JDK 21")).toBe("D:/work/project/JDK 21");
  expect(workspaceToolchainPath("D:/work/project", "../JDK 21")).toBe("D:/work/JDK 21");
  expect(workspaceToolchainPath("//server/share/project", "../../jdk")).toBe("//server/share/jdk");
});
