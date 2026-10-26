import { useTranslation } from "@/i18n/locale-provider";
import type { BuildProviderReview } from "../build-systems-types";

/** Display the frozen native program selection that this approval authorizes. */
export default function BuildProviderReviewDetails({ review }: { review: BuildProviderReview }) {
  const { t } = useTranslation();
  const shared = (review.launchPlan.buildProvider as { languageServer?: string } | undefined)
    ?.languageServer;
  return (
    <section className="mt-3 space-y-2" aria-label={t("buildSystems.provider.programs")}>
      <p className="text-xs font-medium">{t("buildSystems.provider.programs")}</p>
      {shared && (
        <p className="text-xs">{t("buildSystems.provider.shared", { language: shared })}</p>
      )}
      <pre className="max-h-56 overflow-auto whitespace-pre-wrap break-all text-xs">
        {JSON.stringify(
          {
            executable: review.program.serverPath,
            arguments: review.program.serverArgs,
            environment: review.program.environment,
            launch: review.launchPlan.launch,
            initializationOptions: review.program.initializationOptions,
            workspaceConfiguration: review.program.workspaceConfiguration,
            runtimeRequirements: review.launchPlan.runtimeRequirements,
            validationArguments: review.launchPlan.validationArguments,
            buildToolCandidates: review.invocationPlan,
          },
          null,
          2,
        )}
      </pre>
    </section>
  );
}
