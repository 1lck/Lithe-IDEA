import { useTranslation } from "@/i18n/locale-provider";
import { redactConsoleText } from "../services/git-execution-journal";

export function GitRepositoryErrorNotice({ error, root }: { error: string; root: string }) {
  const { t } = useTranslation();
  const details = redactConsoleText(error);
  const authenticationFailure = /authentication|authorization|permission denied \([^)]*(?:publickey|password|keyboard-interactive)/i.test(error);
  const description = /detected dubious ownership/i.test(error)
    ? "git.setup.ownershipDenied"
    : !authenticationFailure && /permission denied|access is denied|access denied|operation not permitted/i.test(error)
      ? "git.setup.permissionDenied"
      : "git.setup.readFailedHint";

  return (
    <div role="alert" className="flex w-full min-w-0 flex-col gap-2 text-destructive">
      <p className="font-medium">{t("git.setup.readFailed")}</p>
      <p>{t(description)}</p>
      <p className="break-all font-mono ui-text-xs text-subtle-foreground">{root}</p>
      <details className="min-w-0 text-left text-subtle-foreground">
        <summary className="cursor-pointer">{t("git.setup.errorDetails")}</summary>
        <pre className="mt-2 max-h-48 overflow-auto whitespace-pre-wrap break-all select-text ui-text-xs">
          {details}
        </pre>
      </details>
    </div>
  );
}
