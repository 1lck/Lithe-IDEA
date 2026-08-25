/** Inheritance relationship represented by one Java gutter marker. */
export type JavaImplementationRelation = "interface" | "inheritance";

/** Shared Core marker projected into Monaco gutter coordinates. */
export interface JavaImplementationMarker {
  line: number;
  utf16Column: number;
  implementationCount: number;
  direction: "up" | "down";
  relation: JavaImplementationRelation;
}

function isImplementationMarker(value: unknown): value is JavaImplementationMarker {
  if (!value || typeof value !== "object") return false;
  const marker = value as Partial<JavaImplementationMarker>;
  return (
    Number.isInteger(marker.line) &&
    Number.isInteger(marker.utf16Column) &&
    Number.isInteger(marker.implementationCount) &&
    (marker.direction === "up" || marker.direction === "down") &&
    (marker.relation === "interface" || marker.relation === "inheritance")
  );
}

/** Rejects malformed boundary data and preserves deterministic source order. */
export function normalizeJavaImplementationMarkers(value: unknown): JavaImplementationMarker[] {
  if (!Array.isArray(value)) return [];
  return value
    .filter(isImplementationMarker)
    .sort((left, right) => left.line - right.line || left.utf16Column - right.utf16Column);
}
