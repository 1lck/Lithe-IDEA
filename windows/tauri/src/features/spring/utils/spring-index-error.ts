import type { SpringIndexError } from "../types/spring.types";
import { isSupportedSpringRoot } from "./spring-root";

export class SpringIndexRequestError extends Error {
  readonly code: string;
  readonly details?: string;

  constructor(code: string, message: string, details?: string) {
    super(message);
    this.name = "SpringIndexRequestError";
    this.code = code;
    this.details = details;
  }
}

function errorDetail(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

export function classifySpringIndexError(
  error: unknown,
  root: string | null | undefined,
): SpringIndexError {
  const detail = errorDetail(error);
  if (!isSupportedSpringRoot(root)) {
    return {
      category: "unsupportedRoot",
      detail,
    };
  }
  if (error instanceof SpringIndexRequestError) {
    if (error.code === "workspace_not_found") {
      return { category: "rootUnavailable", detail };
    }
    if (error.code === "permission_denied") {
      return { category: "permissionDenied", detail };
    }
    if (error.code === "timed_out") {
      return { category: "indexTimeout", detail };
    }
  }
  return {
    category: "indexFailed",
    detail,
  };
}

export function springIndexErrorTranslationKey(error: SpringIndexError | null): string | null {
  return error ? `springEndpoints.error.${error.category}` : null;
}
