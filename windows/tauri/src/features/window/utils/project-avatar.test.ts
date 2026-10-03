import { describe, expect, test } from "bun:test";
import { getProjectGradientColorIndex } from "./project-gradient";
import { getProjectAvatarBackground, getProjectAvatarInitials } from "./project-avatar";

describe("getProjectAvatarInitials", () => {
  // Cases mirror the examples documented on IntelliJ AvatarUtils.initials.
  test.each([
    ["John Smith", "JS"],
    ["John-Smith-Harris", "JH"],
    ["MyProject", "MP"],
    ["My-Project", "MP"],
    ["Lithe-IDEA-issue-35-ci", "LC"],
    ["lithe", "L"],
    ["文档项目", "文"],
    ["my_app.web", "MA"],
  ])("%s -> %s", (name, initials) => {
    expect(getProjectAvatarInitials(name)).toBe(initials);
  });
});

describe("getProjectAvatarBackground", () => {
  test("shares the project gradient color index so the avatar matches the window gradient", () => {
    // "/projects/alpha" is gradient color 4, whose Islands avatar runs #3b92b8 -> #6183ec.
    expect(getProjectGradientColorIndex("/projects/alpha")).toBe(4);
    expect(getProjectAvatarBackground("/projects/alpha")).toBe(
      "linear-gradient(to top right, #6183ec, #3b92b8)",
    );
  });
});
