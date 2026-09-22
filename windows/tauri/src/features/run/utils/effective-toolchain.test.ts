import { expect, test } from "bun:test";
import { createTranslator } from "@/i18n/locale";
import { describeEffectiveToolchain, toolchainRequirementMessages } from "./effective-toolchain";

const en = createTranslator("en-US");
const zh = createTranslator("zh-CN");

test("automatic names the JDK a launch picks and where it came from", () => {
  const state = {
    status: "resolved",
    path: "C:/Java/jdk-21",
    version: "21.0.4",
    vendor: "Temurin",
    source: "javaHome",
  } as const;
  expect(describeEffectiveToolchain(state, "java", "automatic", en)).toEqual({
    text: "Automatic → JDK 21.0.4 · C:/Java/jdk-21 · from JAVA_HOME",
    tone: "normal",
  });
  expect(describeEffectiveToolchain(state, "java", "automatic", zh).text).toBe(
    "自动 → JDK 21.0.4 · C:/Java/jdk-21 · 来自 JAVA_HOME",
  );
});

test("inherited and selected values name the value, not a redundant source", () => {
  const inherited = {
    status: "resolved",
    path: "C:/Java/jdk-17",
    version: "17.0.2",
    vendor: "",
    source: "projectJdk",
  } as const;
  expect(describeEffectiveToolchain(inherited, "java", "projectJdk", en).text).toBe(
    "Use project JDK → JDK 17.0.2 · C:/Java/jdk-17",
  );
  const wrapper = {
    status: "resolved",
    path: "C:/work/mvnw.cmd",
    version: "",
    vendor: "",
    source: "mavenWrapper",
  } as const;
  expect(describeEffectiveToolchain(wrapper, "maven", "inherit", en).text).toBe(
    "Inherited from project → Maven · C:/work/mvnw.cmd · project Maven Wrapper",
  );
});

test("missing, invalid and pending toolchains say so instead of 'automatic'", () => {
  expect(describeEffectiveToolchain({ status: "detecting" }, "java", "automatic", en)).toEqual({
    text: "Detecting…",
    tone: "normal",
  });
  expect(
    describeEffectiveToolchain({ status: "notFound", message: null }, "java", "automatic", en).tone,
  ).toBe("error");
  expect(
    describeEffectiveToolchain(
      { status: "invalid", message: "JDK Home does not point to a directory: C:/missing" },
      "java",
      "configured",
      en,
    ),
  ).toEqual({
    text: "Cannot be used: JDK Home does not point to a directory: C:/missing",
    tone: "error",
  });
});

test("requirement messages are scoped to the toolchain and configuration", () => {
  const diagnostics = [
    {
      id: "api",
      code: "toolchainVersionMismatch",
      toolchain: "project-jdk",
      message: "java 1.8 does not satisfy required version 17",
    },
    {
      id: "web",
      code: "toolchainVersionMismatch",
      toolchain: "project-jdk",
      message: "java 1.8 does not satisfy required version 17",
    },
    {
      id: "api",
      code: "missingToolchain",
      toolchain: "project-maven",
      message: "No local maven toolchain is selected",
    },
    { id: "api", code: "staleFingerprint", message: "Project inputs changed" },
  ];
  // Project defaults apply to every configuration, so duplicates collapse.
  expect(toolchainRequirementMessages(diagnostics, "project-jdk")).toEqual([
    "java 1.8 does not satisfy required version 17",
  ]);
  expect(toolchainRequirementMessages(diagnostics, "project-maven", "web")).toEqual([]);
  expect(toolchainRequirementMessages(diagnostics, "project-maven", "api")).toEqual([
    "No local maven toolchain is selected",
  ]);
});
