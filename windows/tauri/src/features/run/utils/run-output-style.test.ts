import { describe, expect, test } from "bun:test";
import { getLitheDefaultTheme } from "@/extensions/themes/default-theme";
import { stampOutput } from "./output-timestamper";
import {
  parseAnsi,
  renderRunOutput,
  resolveAnsi16Palette,
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
    expect(spans[0]?.style?.color).toBe("var(--terminal-red)");
  });

  test("restores the default style after a reset sequence", () => {
    const spans = renderRunOutput("\u001b[31mred\u001b[0mplain");
    expect(spans).toHaveLength(2);
    expect(spans[0]?.style?.color).toBe("var(--terminal-red)");
    expect(spans[1]?.text).toBe("plain");
    expect(spans[1]?.style?.color).toBeUndefined();
    expect(spans[1]?.className).toBeUndefined();
  });

  test("skips severity coloring when the process already styled the line", () => {
    const spans = renderRunOutput("\u001b[1m[ERROR] Failed\u001b[0m\n");
    const error = spans.find((span) => span.text.includes("[ERROR]"));
    expect(spans.map((span) => span.text).join("")).toBe("[ERROR] Failed\n");
    expect(error?.className).toBeUndefined();
    expect(error?.style?.fontWeight).toBe(700);
  });

  test("keeps severity coloring on unstyled ERROR lines after an ANSI-styled line", () => {
    const spans = renderRunOutput(
      "\u001b[32m[INFO] Building\u001b[0m\n[ERROR] Failed to execute goal\n",
    );
    const info = spans.find((span) => span.text.includes("[INFO]"));
    const error = spans.find((span) => span.text.includes("[ERROR]"));
    expect(info?.style?.color).toBe("var(--terminal-green)");
    expect(info?.className).toBeUndefined();
    expect(error?.className).toBe("text-destructive");
    expect(error?.style?.color).toBeUndefined();
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

describe("theme ANSI palette", () => {
  test("uses current-theme variables for the 16-color palette", () => {
    expect(renderRunOutput("\u001b[30mblack")[0]?.style?.color).toBe("var(--terminal-black)");
    expect(renderRunOutput("\u001b[37mwhite")[0]?.style?.color).toBe("var(--terminal-white)");
    expect(renderRunOutput("\u001b[97mbright")[0]?.style?.color).toBe(
      "var(--terminal-bright-white)",
    );
  });

  test("light theme keeps SGR 37/97 visible against the background", () => {
    const theme = getLitheDefaultTheme("light");
    const palette = resolveAnsi16Palette(theme.colors);
    expect(renderRunOutput("\u001b[37mwhite")[0]?.style?.color).toBe("var(--terminal-white)");
    expect(renderRunOutput("\u001b[97mbright")[0]?.style?.color).toBe(
      "var(--terminal-bright-white)",
    );
    expect(palette[7]).toBe(theme.colors["terminal-white"]);
    expect(palette[15]).toBe(theme.colors["terminal-bright-white"]);
    expect(palette[7]?.toLowerCase()).not.toBe(theme.colors.background.toLowerCase());
    expect(palette[15]?.toLowerCase()).not.toBe(theme.colors.background.toLowerCase());
    expect(palette[15]?.toLowerCase()).not.toBe("#ffffff");
  });

  test("dark theme keeps SGR 30 visible against the background", () => {
    const theme = getLitheDefaultTheme("dark");
    const palette = resolveAnsi16Palette(theme.colors);
    expect(renderRunOutput("\u001b[30mblack")[0]?.style?.color).toBe("var(--terminal-black)");
    expect(palette[0]).toBe(theme.colors["terminal-black"]);
    expect(palette[0]?.toLowerCase()).not.toBe(theme.colors.background.toLowerCase());
  });
});
