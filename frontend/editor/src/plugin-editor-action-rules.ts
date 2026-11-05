// Pure rules for plugin editor actions (API-27): what the page accepts from
// the host's list, where each marker sits in the gutter and what its menu
// offers. Core and the host have already validated the list; this module
// only keeps the page safe against a malformed or stale reply.

/** The gutter lane a marker is drawn in: navigation beside the run lane. */
export type ActionLane = "left" | "right";

export interface EditorActionAlternative {
  id: string;
  title: string;
  icon: string;
}

/** One action as the host sends it, with one-based lines. */
export interface EditorAction {
  id: string;
  line: number;
  endLine: number;
  title: string;
  icon: string;
  alternatives: EditorActionAlternative[];
}

/** One gutter decoration: the first action of a line and lane draws it. */
export interface ActionMarker {
  line: number;
  lane: ActionLane;
  icon: string;
  title: string;
}

/** One menu row: the action alone, or the action with one alternative. */
export interface ActionChoice {
  key: string;
  title: string;
  action: string;
  alternative?: string;
}

// The host declares icon names (`actionIcons` in its options); they become
// CSS class suffixes, so only that spelling is ever put into a class.
const ICON_NAME = /^[a-z][a-z0-9-]*$/;
const MAX_ALTERNATIVES = 4;

export function actionLane(icon: string): ActionLane {
  return icon.startsWith("navigate-") ? "left" : "right";
}

function normalizeAlternatives(value: unknown): EditorActionAlternative[] {
  if (!Array.isArray(value)) return [];
  return (value as Partial<EditorActionAlternative>[])
    .filter(item => typeof item?.id === "string" && typeof item.title === "string" &&
      typeof item.icon === "string" && ICON_NAME.test(item.icon))
    .slice(0, MAX_ALTERNATIVES)
    .map(item => ({ id: item.id!, title: item.title!, icon: item.icon! }));
}

/** Keeps only well-formed actions that start inside the document. */
export function normalizeEditorActions(value: unknown, lineCount: number): EditorAction[] {
  if (!Array.isArray(value)) return [];
  const actions: EditorAction[] = [];
  for (const item of value as Partial<EditorAction>[]) {
    if (typeof item?.id !== "string" || typeof item.title !== "string" ||
        typeof item.icon !== "string" || !ICON_NAME.test(item.icon) ||
        !Number.isInteger(item.line) || item.line! < 1 || item.line! > lineCount) continue;
    const endLine = Number.isInteger(item.endLine) && item.endLine! >= item.line!
      ? Math.min(item.endLine!, lineCount) : item.line!;
    actions.push({
      id: item.id, line: item.line!, endLine, title: item.title, icon: item.icon,
      alternatives: normalizeAlternatives(item.alternatives),
    });
  }
  return actions;
}

/** One marker per line and lane, in document order. */
export function actionMarkers(actions: readonly EditorAction[]): ActionMarker[] {
  const markers = new Map<string, ActionMarker>();
  for (const action of actions) {
    const lane = actionLane(action.icon), key = `${action.line}:${lane}`;
    if (!markers.has(key)) markers.set(key, { line: action.line, lane, icon: action.icon, title: action.title });
  }
  return [...markers.values()].sort((left, right) => left.line - right.line);
}

/**
 * The menu behind one marker: each action of the line and lane, followed by
 * its alternatives (for example "Debug" after "Run").
 */
export function actionChoices(actions: readonly EditorAction[], line: number, lane: ActionLane): ActionChoice[] {
  return actions.filter(action => action.line === line && actionLane(action.icon) === lane).flatMap(action => [
    { key: action.id, title: action.title, action: action.id },
    ...action.alternatives.map(alternative => ({
      key: `${action.id}.${alternative.id}`, title: alternative.title, action: action.id, alternative: alternative.id,
    })),
  ]);
}
