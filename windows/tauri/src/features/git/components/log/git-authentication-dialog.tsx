import { useState } from "react";
import { toast } from "sonner";
import { invoke } from "@/platform/tauri-core";
import { useTranslation } from "@/i18n/locale-provider";
import AppDialog from "@/ui/dialog";
import { Button } from "@/ui/button";
import Input from "@/ui/input";
import { dismissGitAuthentication, useGitConsoleStore } from "../../stores/git-console.store";
import type { GitExecutionEvent } from "@/platform/git-execution-events";

export function GitAuthenticationDialog() {
  const challenge = useGitConsoleStore((state) => state.authentication[0]);
  return challenge ? <AuthenticationPrompt key={challenge.requestId} challenge={challenge} /> : null;
}
function AuthenticationPrompt({ challenge }: { challenge: GitExecutionEvent }) {
  const { t } = useTranslation();
  const [answer, setAnswer] = useState("");
  const [busy, setBusy] = useState(false);
  async function reply(value: string | null) {
    if (busy) return;
    setBusy(true);
    setAnswer("");
    try {
      const result = await invoke<{ accepted: boolean }>("git.authRespond", { requestId: challenge.requestId, answer: value });
      if (!result.accepted && value !== null) toast.error(t("git.execution.authExpired"));
      if (value === null || !result.accepted) await invoke("core_cancel", { operationId: challenge.operationId });
    } catch (error) { toast.error(String(error)); }
    finally { dismissGitAuthentication(challenge.requestId ?? ""); }
  }
  return <AppDialog title={t("git.execution.authentication")} onClose={() => void reply(null)} size="md"
    footer={<><Button disabled={busy} onClick={() => void reply(null)}>{t("git.console.cancel")}</Button><Button disabled={busy} onClick={() => void reply(challenge.retry ? "retry" : answer)}>{t(challenge.retry ? "git.execution.retry" : "git.execution.continue")}</Button></>}>
    <form className="flex flex-col gap-3" onSubmit={(event) => { event.preventDefault(); void reply(challenge.retry ? "retry" : answer); }}>
      <p className="break-words text-sm">{challenge.prompt}</p>
      {(challenge.attempt ?? 1) > 1 && <p className="text-sm text-destructive">{t("git.execution.authAgain")}</p>}
      {!challenge.retry && <Input autoFocus aria-label={t("git.execution.response")} type={challenge.secret ? "password" : "text"} value={answer}
        autoComplete="off" onChange={(event) => setAnswer(event.target.value)} disabled={busy} />}
      <p className="text-xs text-subtle-foreground">{t("git.execution.authScope")}</p>
    </form>
  </AppDialog>;
}
