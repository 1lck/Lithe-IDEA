import { useSyncExternalStore } from "react";
import { useTranslation } from "@/i18n/locale-provider";
import { Button } from "@/ui/button";
import Select from "@/ui/select";
import type { VcsRootController } from "./vcs-root-controller";
import type { VcsSnapshot } from "./vcs-root-types";

export function VcsMappingPanel({
  controller,
  snapshot,
}: {
  controller: VcsRootController;
  snapshot: VcsSnapshot;
}) {
  const { t } = useTranslation();
  const { drafts, saving, error } = useSyncExternalStore(
    controller.mappings.subscribe,
    controller.mappings.getSnapshot,
  );
  if (!snapshot.mappings) return null;
  const choices = snapshot.mappingChoices ?? snapshot.detection.ambiguous;
  const rows = [...choices];
  for (const entry of snapshot.mappings.entries) {
    if (!rows.some((row) => row.id === entry.id)) rows.push({ id: entry.id, vcs: [entry.vcs] });
  }
  for (const [id, draft] of drafts) {
    if (!rows.some((row) => row.id === id))
      rows.push({
        id,
        vcs: draft.source.mappingChoices?.find((row) => row.id === id)?.vcs ?? [draft.value],
      });
  }
  if (!rows.length) return null;
  return (
    <div className="space-y-1" data-testid="vcs-root-mappings">
      <p className="truncate text-subtle-foreground" title={t("vcs.mapping.sourceInfo")}>
        {t("vcs.mapping.source", { path: snapshot.mappings.source })}
      </p>
      {rows.slice(0, 64).map((row) => {
        const saved = snapshot.mappings!.entries.find((entry) => entry.id === row.id)?.vcs ?? "";
        const value = drafts.get(row.id)?.value ?? saved;
        return (
          <div key={row.id} className="flex flex-wrap items-center gap-1">
            <span className="min-w-0 truncate" title={row.id}>
              {row.id || controller.scope.workspaceRoot}
            </span>
            <Select
              size="xs"
              value={value}
              disabled={saving !== null || snapshot.detection.truncated}
              aria-label={t("vcs.mapping.select", {
                path: row.id || controller.scope.workspaceRoot,
              })}
              options={[
                { value: "", label: t("vcs.mapping.automatic") },
                ...row.vcs.map((vcs) => ({
                  value: vcs,
                  label:
                    snapshot.detection.providers.find((provider) => provider.vcs === vcs)
                      ?.displayName ?? vcs,
                })),
              ]}
              onChange={(value) => controller.mappings.edit(row.id, value)}
            />
            <Button
              size="xs"
              disabled={
                saving !== null ||
                !drafts.get(row.id) ||
                value === saved ||
                snapshot.detection.truncated
              }
              onClick={() => {
                void controller.mappings.save(row.id);
              }}
            >
              {t("vcs.mapping.save")}
            </Button>
            {drafts.get(row.id) && (
              <Button
                size="xs"
                disabled={saving !== null}
                onClick={() => controller.mappings.cancel(row.id)}
              >
                {t("vcs.mapping.cancel")}
              </Button>
            )}
          </div>
        );
      })}
      {error !== null && (
        <p role="alert">
          {t(
            String(error).includes("vcs.mapping.conflict")
              ? "vcs.mapping.conflict"
              : "vcs.mapping.failed",
          )}
        </p>
      )}
    </div>
  );
}
