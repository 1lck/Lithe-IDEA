import { describe, expect, test } from "bun:test";
import type { LspLocation } from "./lsp-client";
import { definitionLocationsFromCommandArgs } from "./definition-navigation-hint";

const location: LspLocation = {
  uri: "file:///workspace/Target.java",
  range: {
    start: { line: 7, character: 4 },
    end: { line: 7, character: 10 },
  },
};

function commandArgs(locations: LspLocation[] = [location]) {
  return {
    definitionHint: {
      sourceFilePath: "C:/workspace/Source.java",
      sourceLine: 3,
      sourceStartCharacter: 8,
      sourceEndCharacter: 14,
      locations,
    },
  };
}

describe("definition navigation hint", () => {
  test("reuses locations only for the matching source word", () => {
    expect(
      definitionLocationsFromCommandArgs(commandArgs(), {
        filePath: "C:/workspace/Source.java",
        line: 3,
        character: 10,
      }),
    ).toEqual([location]);

    expect(
      definitionLocationsFromCommandArgs(commandArgs(), {
        filePath: "C:/workspace/Other.java",
        line: 3,
        character: 10,
      }),
    ).toBeUndefined();
    expect(
      definitionLocationsFromCommandArgs(commandArgs(), {
        filePath: "C:/workspace/Source.java",
        line: 4,
        character: 10,
      }),
    ).toBeUndefined();
    expect(
      definitionLocationsFromCommandArgs(commandArgs(), {
        filePath: "C:/workspace/Source.java",
        line: 3,
        character: 14,
      }),
    ).toBeUndefined();
  });

  test("preserves an empty resolved result so click does not request the same symbol twice", () => {
    expect(
      definitionLocationsFromCommandArgs(commandArgs([]), {
        filePath: "C:/workspace/Source.java",
        line: 3,
        character: 8,
      }),
    ).toEqual([]);
  });

  test("ignores malformed command arguments", () => {
    expect(
      definitionLocationsFromCommandArgs(
        { definitionHint: { locations: "invalid" } },
        {
          filePath: "C:/workspace/Source.java",
          line: 3,
          character: 8,
        },
      ),
    ).toBeUndefined();
    expect(
      definitionLocationsFromCommandArgs(
        {
          definitionHint: {
            ...commandArgs().definitionHint,
            sourceStartCharacter: -1,
          },
        },
        {
          filePath: "C:/workspace/Source.java",
          line: 3,
          character: 8,
        },
      ),
    ).toBeUndefined();
    expect(
      definitionLocationsFromCommandArgs(undefined, {
        filePath: "C:/workspace/Source.java",
        line: 3,
        character: 8,
      }),
    ).toBeUndefined();
  });
});
