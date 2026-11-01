import { expect, test } from "bun:test";
import fixture from "../../../../../../shared/fixtures/agent/thought-presentation-v1.json";
import { currentThoughtTitle, thoughtSections } from "./agent-thought-presentation";

for (const example of fixture.cases) {
  test(example.name, () => {
    expect(thoughtSections(example.source, "isStreaming" in example && example.isStreaming)).toEqual(example.sections);
    expect(currentThoughtTitle(example.source)).toBe(example.currentTitle);
    expect(thoughtSections(example.source, true, false)).toEqual([
      { title: null, body: example.source, isTitleComplete: true },
    ]);
  });
}

test("streaming prefixes converge to the same sections as history without showing delimiters", () => {
  const text = "**Defining groups****Choosing keys**\nRead the **README**.";
  let title: string | null = null;
  for (let length = 2; length <= text.length; length++) {
    const prefix = text.slice(0, length);
    const sections = thoughtSections(prefix, true);
    expect(sections.every((section) => !section.title?.includes("**"))).toBe(true);
    if (length <= text.indexOf("\n")) expect(sections.every((section) => section.body === "")).toBe(true);
    title = currentThoughtTitle(prefix) ?? title;
  }
  expect(title).toBe("Choosing keys");
  expect(thoughtSections(text, true)).toEqual(thoughtSections(text));
});
