import { expect, test } from "bun:test";
import { basicLanguageForFilename } from "./basic-file-associations";
import fixture from "../../../shared/fixtures/editor/basic-file-highlighting-v1.json";

test("basic associations match basenames and native paths on both hosts", () => {
  for (const { filename, language } of fixture.associations) {
    for (const prefix of ["", "/workspace/project/", "C:\\workspace\\project\\"]) {
      expect(basicLanguageForFilename(prefix + filename.toUpperCase())).toBe(language);
    }
  }
  for (const filename of ["README", "notMakefile", "ContainerfileBackup", ".environment", "code.unknown"]) {
    expect(basicLanguageForFilename(filename)).toBeUndefined();
  }
});
