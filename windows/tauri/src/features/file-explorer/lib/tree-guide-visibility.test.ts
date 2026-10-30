import { afterAll, beforeEach, describe, expect, test } from "bun:test";
import { installHappyDom } from "@/test-utils/happy-dom";
import {
  installTreeGuideVisibility,
  resetTreeGuideVisibilityForTests,
} from "./tree-guide-visibility";

const restoreDom = installHappyDom();

afterAll(() => {
  restoreDom();
});

function buildTree() {
  const tree = document.createElement("div");
  tree.className = "file-tree-container";
  const guide = document.createElement("span");
  guide.className = "file-tree-guide";
  const row = document.createElement("button");
  tree.append(guide, row);
  document.body.append(tree);
  return { tree, guide, row };
}

beforeEach(() => {
  document.body.innerHTML = "";
  resetTreeGuideVisibilityForTests();
  installTreeGuideVisibility(document);
});

describe("tree guide visibility", () => {
  test("marks the tree while a guide is hovered", () => {
    const { tree, guide, row } = buildTree();

    const view = document.defaultView as unknown as typeof globalThis;
    guide.dispatchEvent(new view.MouseEvent("pointerover", { bubbles: true }));
    expect(tree.hasAttribute("data-guide-hover")).toBe(true);

    guide.dispatchEvent(new view.MouseEvent("pointerout", { bubbles: true, relatedTarget: row }));
    expect(tree.hasAttribute("data-guide-hover")).toBe(false);
  });

  test("clears focus marking when focus leaves the tree", () => {
    const { tree, row } = buildTree();
    tree.setAttribute("data-guide-focus", "");
    const outside = document.createElement("button");
    document.body.append(outside);

    const view = document.defaultView as unknown as typeof globalThis;
    row.dispatchEvent(new view.FocusEvent("focusout", { bubbles: true, relatedTarget: outside }));
    expect(tree.hasAttribute("data-guide-focus")).toBe(false);
  });
});
