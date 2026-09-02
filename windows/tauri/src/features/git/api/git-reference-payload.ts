import type { GitReference } from "../types/git.types";

export type GitReferenceInput = GitReference | string;

export const toCoreGitReference = (reference: GitReference) => ({
  fullName: reference.fullName,
  shortName: reference.shortName,
  kind: reference.kind,
});

export const referencePayload = (reference: GitReferenceInput) =>
  typeof reference === "string"
    ? { reference }
    : { gitReference: toCoreGitReference(reference) };
