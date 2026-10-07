import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { graphColor, graphColorIdForName } from "./git-graph-colors";

test("light/dark RGB matches the real IntelliJ generator, including signed integer overflow", () => {
  const oracle = readFileSync(
    new URL(
      "../../../../../../macos/Tests/LitheTests/Fixtures/GitGraph/idea-theme-colors.txt",
      import.meta.url,
    ),
    "utf8",
  );
  for (const line of oracle.trim().split(/\r?\n/)) {
    const [theme, id, channels] = line.split("|");
    expect(graphColor(Number(id), theme === "dark")).toBe(`rgb(${channels.split(":").join(", ")})`);
  }
});

test("keeps full Java IDs and uses foreground for unreferenced fragments", () => {
  expect(graphColorIdForName("main")).toBe(3343801);
  expect(graphColor(0)).toBe("var(--foreground)");
  expect(graphColor(0, true)).toBe("var(--foreground)");
  expect(graphColor(1)).not.toBe(graphColor(7));
});
