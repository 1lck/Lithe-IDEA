import { describe, expect, test } from "bun:test";
import { getProjectPickerInitialState } from "./project-picker-mode";

describe("project picker launch mode", () => {
  test("opens the searchable picker by default", () => {
    expect(getProjectPickerInitialState("picker")).toEqual({
      commandStep: "picker",
      newProjectSource: undefined,
    });
  });

  test("opens the new project source chooser", () => {
    expect(getProjectPickerInitialState("new-project")).toEqual({
      commandStep: "newProject",
      newProjectSource: undefined,
    });
  });

  test("opens the clone repository details form directly", () => {
    expect(getProjectPickerInitialState("clone-repository")).toEqual({
      commandStep: "newProject",
      newProjectSource: "clone",
    });
  });
});
