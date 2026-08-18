import type { DatabaseType } from "../../types/provider.types";

const CONNECTION_DB_TYPES: DatabaseType[] = [
  "sqlite",
  "duckdb",
  "postgres",
  "mysql",
  "mongodb",
  "redis",
];

export interface DatabaseExtensionAvailability {
  isInstalled?: boolean;
  manifest: {
    databases?: Array<{ id: string; protocolVersion?: number }>;
    databaseProviders?: Array<{ id: string; protocolVersion?: number }>;
  };
}

export interface ConnectionValidationInput {
  dbType: DatabaseType;
  isFileBased: boolean;
  mode: "form" | "string";
  filePath: string;
  host: string;
  port: number;
  database: string;
  connectionString: string;
}

export interface ConnectionValidationMessages {
  selectDatabaseFile: string;
  enterConnectionString: string;
  enterHost: string;
  enterValidPort: string;
  enterDatabaseName: string;
}

const DEFAULT_CONNECTION_VALIDATION_MESSAGES: ConnectionValidationMessages = {
  selectDatabaseFile: "Select a database file",
  enterConnectionString: "Enter a connection string",
  enterHost: "Enter a host",
  enterValidPort: "Enter a valid port",
  enterDatabaseName: "Enter a database name",
};

export function getInstalledDatabaseTypes(
  _availableExtensions: Map<string, DatabaseExtensionAvailability>,
): DatabaseType[] {
  return CONNECTION_DB_TYPES;
}

export function validateConnectionInput(
  input: ConnectionValidationInput,
  messages: ConnectionValidationMessages = DEFAULT_CONNECTION_VALIDATION_MESSAGES,
): string | null {
  if (input.isFileBased) {
    return input.filePath.trim() ? null : messages.selectDatabaseFile;
  }

  if (input.mode === "string") {
    return input.connectionString.trim() ? null : messages.enterConnectionString;
  }

  if (!input.host.trim()) {
    return messages.enterHost;
  }

  if (!Number.isInteger(input.port) || input.port < 1 || input.port > 65535) {
    return messages.enterValidPort;
  }

  if (input.dbType !== "redis" && !input.database.trim()) {
    return messages.enterDatabaseName;
  }

  return null;
}
