import {
  submitFrontendLog,
  sanitizeFrontendLogPayload,
  type FrontendLogLevel,
} from "@/features/logging/frontend-log-runtime";

type TraceLevel = FrontendLogLevel;

export function frontendTrace(
  level: TraceLevel,
  scope: string,
  message: string,
  payload?: Record<string, unknown>,
) {
  void submitFrontendLog({
    level,
    scope,
    message,
    payload: sanitizeFrontendLogPayload(payload),
  });
}
