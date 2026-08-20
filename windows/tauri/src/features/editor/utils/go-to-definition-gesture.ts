interface EditorGoToDefinitionModifierEvent {
  ctrlKey?: boolean;
  metaKey?: boolean;
  altKey?: boolean;
  shiftKey?: boolean;
}

export function isEditorGoToDefinitionModifierActive(
  event: EditorGoToDefinitionModifierEvent,
): boolean {
  return Boolean((event.ctrlKey || event.metaKey) && !event.altKey && !event.shiftKey);
}

export function isEditorGoToDefinitionModifierClick(
  event: EditorGoToDefinitionModifierEvent & { leftButton?: boolean },
): boolean {
  return Boolean(event.leftButton && isEditorGoToDefinitionModifierActive(event));
}
