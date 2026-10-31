export type IndexingErrorCode =
  | "invalidSettings"
  | "readFailed"
  | "writeFailed"
  | "configureFailed";

export class IndexingSettingsError extends Error {
  constructor(readonly code: IndexingErrorCode, cause?: unknown) {
    super(code, { cause });
    this.name = "IndexingSettingsError";
  }
}
