/** React portals bubble through the component tree, not the DOM tree. A dialog
 * owned by the explorer must keep its native submit, checkbox and keyboard
 * defaults; it is not a tree interaction even though React bubbles it here. */
export function isTreeDomEvent(event: {
  currentTarget: Node;
  target: EventTarget | null;
}): boolean {
  return event.target instanceof Node && event.currentTarget.contains(event.target);
}
