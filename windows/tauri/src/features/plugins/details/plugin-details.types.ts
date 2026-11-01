import type { DeclarativePluginRejection, DeclarativePluginSetting } from "../declarative-plugin-launch";

export type PluginCatalogSource = "bundled" | "installed";

export interface PluginDetailsSelection {
  pluginId: string;
  source: PluginCatalogSource;
}

export interface PluginDetailsIdentity extends PluginDetailsSelection {
  version: string;
}

export interface PluginDetailFeature {
  kind:
    | "language"
    | "languageServer"
    | "run"
    | "test"
    | "buildSystem"
    | "projectGenerator"
    | "toolWindow"
    | "command";
  subject: string;
  title: string;
  availability: "available" | "declaredOnly";
  detail: unknown | null;
}

export interface PluginProvenanceVerification {
  status: "publisherSignature" | "hostSeal" | "approvedDigest" | "rejected" | "unknown";
  keyId: string | null;
}

export interface PluginVersionProvenance {
  version: string;
  origin: "bundled" | "marketplace" | "community" | "unknown";
  channel: "bundled" | "marketplace" | "disk" | "unknown";
  sourceId: string | null;
  sourceName: string | null;
  repository: string | null;
  fileName: string | null;
  archiveSha256: string | null;
  contentDigest: string | null;
  verification: PluginProvenanceVerification;
}

export interface PluginDetailsModel {
  identity: PluginDetailsIdentity;
  displayName: string;
  vendorName: string | null;
  description: string | null;
  localizedDescriptions: Record<string, string>;
  apiVersion: number;
  enabled: boolean;
  status: "accepted" | "rejected";
  rejection: DeclarativePluginRejection | null;
  settings: DeclarativePluginSetting[];
  primaryLanguageId: string | null;
  features: PluginDetailFeature[];
  permissions: string[];
  /** Complete Core install-review objects. Never replace these with command names. */
  programs: unknown[];
  versions: {
    current: PluginVersionProvenance;
    previous: PluginVersionProvenance | null;
    updateStatus: "unknown";
  };
  operations: {
    canSetEnabled: boolean;
    canUninstall: boolean;
    canRollback: boolean;
  };
}

export type PluginDetailsOperation = "enable" | "disable" | "uninstall" | "rollback";

export type PluginDetailsState =
  | { phase: "idle"; selection: null; workspacePath: string | null }
  | { phase: "loading"; selection: PluginDetailsSelection; workspacePath: string | null }
  | {
      phase: "ready";
      selection: PluginDetailsSelection;
      workspacePath: string | null;
      details: PluginDetailsModel;
      operation: PluginDetailsOperation | null;
      error: string | null;
    }
  | {
      phase: "failed";
      selection: PluginDetailsSelection;
      workspacePath: string | null;
      error: string;
    };

export function samePluginSelection(
  left: PluginDetailsSelection | null,
  right: PluginDetailsSelection | null,
): boolean {
  return left?.pluginId === right?.pluginId && left?.source === right?.source;
}
