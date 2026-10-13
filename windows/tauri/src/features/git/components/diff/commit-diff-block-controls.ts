import type { CommitDiffBlock } from "../../utils/commit-diff-blocks";

export interface CommitDiffBlockControls {
  blocks: readonly CommitDiffBlock[];
  disabled: boolean;
  includeTitle: string;
  excludeTitle: string;
  rollbackTitle: string;
  onToggle: (id: string, included: boolean) => void;
  onRollback: (id: string) => void;
}

/** Shared accessible controls; the layout owner supplies positions. Keep them
 * outside the selectable code and use real checkbox semantics, including mixed. */
export function commitDiffBlockControl(
  block: CommitDiffBlock, controls: CommitDiffBlockControls, action: "toggle" | "rollback",
) {
  const button = document.createElement("button");
  button.type = "button";
  button.className = `commit-diff-block-${action}`;
  button.dataset.blockId = block.id;
  button.disabled = controls.disabled || !(action === "toggle" ? block.canToggle : block.canRollback);
  button.title = action === "rollback" ? controls.rollbackTitle
    : block.checked ? controls.excludeTitle : controls.includeTitle;
  button.setAttribute("aria-label", button.title);
  if (action === "toggle") {
    button.setAttribute("role", "checkbox");
    button.setAttribute("aria-checked", block.indeterminate ? "mixed" : String(block.checked));
    button.textContent = block.indeterminate ? "−" : block.checked ? "✓" : "";
  } else {
    button.innerHTML = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="m4 5 7 7-7 7m8-14 7 7-7 7" fill="none" stroke="currentColor" stroke-width="1.5"/></svg>';
  }
  button.onclick = event => {
    event.stopPropagation();
    if (button.disabled) return;
    if (action === "toggle") controls.onToggle(block.id, !block.checked);
    else controls.onRollback(block.id);
  };
  button.onmousedown = event => event.stopPropagation();
  return button;
}
