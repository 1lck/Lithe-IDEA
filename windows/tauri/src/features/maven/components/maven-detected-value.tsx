import { useRunStore } from "@/features/run/stores/run.store";
import { useTranslation } from "@/i18n/locale-provider";
import type {
  MavenEffectiveConfiguration,
  MavenEffectiveConfigurationStatus,
  MavenSettings,
} from "../types/maven.types";

const DETECTED_FIELD = {
  settingsPath: "detectedSettingsPath",
  localRepositoryPath: "detectedLocalRepositoryPath",
  mavenExecutablePath: "detectedMavenExecutablePath",
  javaHomePath: "detectedJavaHomePath",
} as const satisfies Record<keyof MavenSettings, keyof MavenEffectiveConfiguration>;

function canonicalPath(value: string): string {
  return value.trim().replace(/[\\/]+$/, "").replace(/\\/g, "/").toLowerCase();
}

function versionForPath(path: string, candidates: Array<{ path: string; version: string }>): string {
  const target = canonicalPath(path);
  return (
    candidates.find((candidate) => candidate.path && canonicalPath(candidate.path) === target)
      ?.version.trim() ?? ""
  );
}

/**
 * The line under a Maven path field showing what automatic detection found on
 * this machine. A custom value does not hide it: the field is the saved
 * override, and this line is the detection result.
 */
export function MavenDetectedValue({
  field,
  value,
  effective,
  status = "idle",
}: {
  field: keyof MavenSettings;
  value: string;
  effective: MavenEffectiveConfiguration | null;
  status?: MavenEffectiveConfigurationStatus;
}) {
  const { t } = useTranslation();
  const discoveredMaven = useRunStore((state) => state.discoveredMaven);
  const discoveredJava = useRunStore((state) => state.discoveredJava);
  if (!effective) {
    if (status === "loading") {
      return (
        <p className="text-subtle-foreground ui-text-xs" data-maven-detected={field}>
          {t("maven.detecting")}
        </p>
      );
    }
    if (status === "failed") {
      return (
        <p className="text-subtle-foreground ui-text-xs" data-maven-detected={field}>
          {t("maven.detectedMissing")}
        </p>
      );
    }
    return null;
  }

  const detectedField = DETECTED_FIELD[field];
  const reported = effective[detectedField];
  const detected = reported !== undefined ? reported : value ? null : effective[field];
  const version =
    !detected
      ? ""
      : field === "mavenExecutablePath"
        ? versionForPath(
            detected,
            discoveredMaven.map((runtime) => ({
              path: runtime.executablePath,
              version: runtime.version,
            })),
          )
        : field === "javaHomePath"
          ? versionForPath(
              detected,
              discoveredJava.map((runtime) => ({
                path: runtime.homePath,
                version: runtime.version,
              })),
            )
          : "";
  const label = detected && version ? `${detected} (${version})` : detected;
  return (
    <p
      className="truncate font-mono text-subtle-foreground ui-text-xs"
      title={detected ?? undefined}
      data-maven-detected={field}
    >
      {label ? t("maven.detectedValue", { value: label }) : t("maven.detectedMissing")}
    </p>
  );
}
