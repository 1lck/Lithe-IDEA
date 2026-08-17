export function isEditorGoToDefinitionModifierClick(event: {
  leftButton?: boolean;
  ctrlKey?: boolean;
  metaKey?: boolean;
  altKey?: boolean;
  shiftKey?: boolean;
}): boolean {
  return Boolean(
    event.leftButton &&
      (event.ctrlKey || event.metaKey) &&
      !event.altKey &&
      !event.shiftKey,
  );
}
