import {
  isFrontendDiagnosticEnabled,
  serializeConsoleArguments,
  submitFrontendLog,
} from "@/features/logging/frontend-log-runtime";
/**
 * Editor logging utility
 * Provides structured logging with levels and can be disabled in production
 */

type LogLevel = "debug" | "info" | "warn" | "error";

interface LoggerConfig {
  enabled: boolean;
  minLevel: LogLevel;
  prefix: string;
}

const LOG_LEVELS: Record<LogLevel, number> = {
  debug: 0,
  info: 1,
  warn: 2,
  error: 3,
};

class EditorLogger {
  private config: LoggerConfig = {
    enabled: true, // Errors remain observable in installed builds.
    minLevel: "warn",
    prefix: "[Editor]",
  };

  configure(config: Partial<LoggerConfig>): void {
    this.config = { ...this.config, ...config };
  }

  private shouldLog(level: LogLevel): boolean {
    if (!this.config.enabled) return false;
    if (level === "debug") return isFrontendDiagnosticEnabled();
    return LOG_LEVELS[level] >= LOG_LEVELS[this.config.minLevel];
  }

  private formatMessage(component: string, message: string): string {
    return `${this.config.prefix}${component ? `[${component}]` : ""} ${message}`;
  }

  debug(component: string, message: string, ...args: unknown[]): void {
    if (this.shouldLog("debug")) {
      void submitFrontendLog({
        level: "debug",
        scope: `editor.${component}`,
        message,
        payload: { detail: serializeConsoleArguments(args) },
      });
    }
  }

  info(component: string, message: string, ...args: unknown[]): void {
    if (this.shouldLog("info")) {
      void submitFrontendLog({
        level: "info",
        scope: `editor.${component}`,
        message,
        payload: { detail: serializeConsoleArguments(args) },
      });
    }
  }

  warn(component: string, message: string, ...args: unknown[]): void {
    if (this.shouldLog("warn")) {
      void submitFrontendLog({
        level: "warn",
        scope: `editor.${component}`,
        message,
        payload: { detail: serializeConsoleArguments(args) },
      });
    }
  }

  error(component: string, message: string, ...args: unknown[]): void {
    if (this.shouldLog("error")) {
      void submitFrontendLog({
        level: "error",
        scope: `editor.${component}`,
        message,
        payload: { detail: serializeConsoleArguments(args) },
      });
    }
  }
}

export const logger = new EditorLogger();
