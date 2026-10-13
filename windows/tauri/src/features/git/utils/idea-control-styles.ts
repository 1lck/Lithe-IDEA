// IntelliJ new UI control metrics shared by the Commit panel and its changes tree:
// 4px corners (arc 8), 1px Component.borderColor, a 2px focus outline and 28px-high
// buttons; checkboxes are 16px boxes with 3px corners, an accent fill when checked.

/** Outline button; becomes the blue default button while the commit message has focus. */
export const IDEA_BUTTON_CLASS_NAME =
  "h-7 min-w-18 rounded-[4px] border border-control-border bg-checkbox-background px-3 text-foreground hover:bg-accent focus-visible:border-primary focus-visible:ring-1 focus-visible:ring-primary disabled:opacity-50";

export const IDEA_CHECKBOX_CLASS_NAME =
  "size-4 rounded-[3px] border-checkbox-border bg-checkbox-background after:-inset-1 active:scale-100 focus-visible:border-2 focus-visible:border-primary focus-visible:ring-0 data-checked:border-primary data-checked:bg-primary data-indeterminate:border-primary data-indeterminate:bg-primary data-indeterminate:text-white data-disabled:opacity-60";
