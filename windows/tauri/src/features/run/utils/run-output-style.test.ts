import { describe, expect, test } from "bun:test";
import { stampOutput } from "./output-timestamper";
import {
  parseAnsi,
  renderRunOutput,
  severityOfLine,
} from "./run-output-style";

const noon = new Date(2026, 7, 8, 10, 12, 33, 123);

describe("output severity coloring", () => {
  test("recognizes bracketed Maven levels", () => {
    expect(severityOfLine("[ERROR] Failed to execute goal")).toBe("error");
    expect(severityOfLine("[WARNING] deprecated API")).toBe("warning");
    expect(severityOfLine("[INFO] Building")).toBe("info");
  });

  test("recognizes Spring Boot spaced levels", () => {
    expect(
      severityOfLine("2026-08-08T10:12:33.123  WARN 1 --- [main] Port 8081 was already in use"),
    ).toBe("warning");
  });

  test("ignores level words embedded in paths", () => {
    expect(severityOfLine("  at src/main/java/ErrorHandler.java:42")).toBeUndefined();
    expect(severityOfLine("Compiling Information.kt")).toBeUndefined();
  });

  test("reports no severity for ordinary output", () => {
    expect(severityOfLine("Tomcat started on port 8081")).toBeUndefined();
  });
});

describe("ANSI output colors", () => {
  test("strips escape sequences and keeps the visible text", () => {
    const parsed = parseAnsi("\u001b[31mred\u001b[0m and plain\n");
    expect(parsed.text).toBe("red and plain\n");
    expect(parsed.hasStyling).toBe(true);
  });

  test("applies the palette color for a foreground SGR code", () => {
    const spans = renderRunOutput("\u001b[31mred\u001b[0m");
    expect(spans.map((span) => span.text).join("")).toBe("red");
    expect(spans[0]?.style?.color).toBe("#f16d75");
  });

  test("restores the default style after a reset sequence", () => {
    const spans = renderRunOutput("\u001b[31mred\u001b[0mplain");
    expect(spans).toHaveLength(2);
    expect(spans[0]?.style?.color).toBe("#f16d75");
    expect(spans[1]?.text).toBe("plain");
    expect(spans[1]?.style?.color).toBeUndefined();
    expect(spans[1]?.className).toBeUndefined();
  });

  test("skips severity coloring when the process already styled the line", () => {
    const spans = renderRunOutput("\u001b[1m[ERROR] Failed\u001b[0m\n");
    expect(spans.map((span) => span.text).join("")).toBe("[ERROR] Failed\n");
    expect(spans.some((span) => span.className === "text-destructive")).toBe(false);
    expect(spans[0]?.style?.fontWeight).toBe(700);
  });
});

describe("run output rendering", () => {
  test("colors Maven severity lines when no ANSI is present", () => {
    const spans = renderRunOutput("[ERROR] Failed to execute goal\n[INFO] Building\n");
    expect(spans[0]?.className).toBe("text-destructive");
    expect(spans[0]?.text.startsWith("[ERROR]")).toBe(true);
    expect(spans[1]?.className).toBe("text-info");
    expect(spans[1]?.text.startsWith("[INFO]")).toBe(true);
  });

  test("dims timestamps without recoloring the message", () => {
    const stamped = stampOutput("[ERROR] Port in use\n", false, noon);
    const spans = renderRunOutput(stamped);
    expect(spans[0]?.className).toBe("text-subtle-foreground/70");
    expect(spans[0]?.text).toBe("10:12:33.123 ");
    expect(spans[1]?.className).toBe("text-destructive");
    expect(spans[1]?.text).toBe("[ERROR] Port in use\n");
  });
});
