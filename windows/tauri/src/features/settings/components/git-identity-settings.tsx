import { useEffect, useRef, useState } from "react";
import {
  configureGitIdentity,
  getGitRepositorySetup,
  type GitIdentityField,
  type GitIdentityScope,
  type GitRepositorySetup,
} from "@/features/git/api/git-setup-api";
import { useRepositoryStore } from "@/features/git/stores/git-repository.store";
import { useProjectStore } from "@/features/window/stores/project.store";
import { useTranslation } from "@/i18n/locale-provider";
import { Button } from "@/ui/button";
import Input from "@/ui/input";
import Section from "./settings-section";

export function GitIdentitySettings() {
  const { t } = useTranslation();
  const activeRoot = useRepositoryStore.use.activeRepoPath();
  const workspaceRoot = useProjectStore((state) => state.rootFolderPath);
  const root = activeRoot ?? workspaceRoot;
  const [scope, setScope] = useState<GitIdentityScope>("local");
  const [state, setState] = useState<GitRepositorySetup | null>(null);
  const [name, setName] = useState("");
  const [email, setEmail] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [saved, setSaved] = useState<GitIdentityField | null>(null);
  const [reload, setReload] = useState(0);
  const generation = useRef(0);
  const context = `${root ?? ""}|${scope}`;
  const currentContext = useRef(context);
  currentContext.current = context;

  useEffect(() => {
    const request = ++generation.current;
    setState(null);
    setName("");
    setEmail("");
    setError(null);
    setSaved(null);
    setBusy(Boolean(root));
    if (root) {
      void getGitRepositorySetup(root, scope)
        .then((value) => {
          if (generation.current !== request || currentContext.current !== context) return;
          setState(value);
          setName(value.configuredName ?? "");
          setEmail(value.configuredEmail ?? "");
        })
        .catch((failure: unknown) => {
          if (generation.current === request && currentContext.current === context)
            setError(String(failure));
        })
        .finally(() => {
          if (generation.current === request && currentContext.current === context) setBusy(false);
        });
    }
    return () => {
      generation.current++;
    };
  }, [root, scope, reload, context]);

  async function save(field: GitIdentityField, clear = false) {
    if (!root || busy || !state || (scope === "local" && !state.isRepository)) return;
    const request = ++generation.current;
    const value = clear ? null : (field === "name" ? name : email).trim();
    if (value === "") return;
    setBusy(true);
    setError(null);
    setSaved(null);
    try {
      const result = await configureGitIdentity(root, scope, field, value);
      if (generation.current !== request || currentContext.current !== context) return;
      setState(result);
      // A successful name save must not overwrite an unsaved email draft.
      if (field === "name") setName(result.configuredName ?? "");
      else setEmail(result.configuredEmail ?? "");
      setSaved(field);
    } catch (failure) {
      if (generation.current === request && currentContext.current === context)
        setError(String(failure));
    } finally {
      if (generation.current === request && currentContext.current === context) setBusy(false);
    }
  }

  return (
    <Section title={t("git.setup.identity")}>
      <p className="ui-text-sm text-subtle-foreground">{t("git.setup.identityDescription")}</p>
      <label className="flex items-center gap-3 ui-text-sm">
        {t("git.setup.scope")}
        <select
          value={scope}
          disabled={busy}
          onChange={(event) => setScope(event.target.value as GitIdentityScope)}
          className="h-8 rounded border border-input bg-background px-2"
        >
          <option value="local">{t("git.setup.local")}</option>
          <option value="global">{t("git.setup.global")}</option>
        </select>
      </label>
      <p className="ui-text-sm text-subtle-foreground">
        {t(scope === "global" ? "git.setup.globalDescription" : "git.setup.localDescription")}
      </p>
      {!root ? (
        <p>{t("git.setup.openProject")}</p>
      ) : (
        <>
          <p className="break-all ui-text-caption text-subtle-foreground">{root}</p>
          {state && !state.isRepository && scope === "local" && (
            <p className="ui-text-sm">{t("git.setup.initializeFirst")}</p>
          )}
          {(["name", "email"] as const).map((field) => {
            const value = field === "name" ? name : email;
            const configured = field === "name" ? state?.configuredName : state?.configuredEmail;
            const effective = field === "name" ? state?.effectiveName : state?.effectiveEmail;
            return (
              <div key={field} className="flex flex-col gap-2">
                <label htmlFor={`git-identity-${field}`} className="ui-text-sm font-medium">
                  {t(field === "name" ? "git.setup.name" : "git.setup.email")}
                </label>
                <div className="flex items-center gap-2">
                  <Input
                    id={`git-identity-${field}`}
                    value={value}
                    onChange={(event) =>
                      (field === "name" ? setName : setEmail)(event.target.value)
                    }
                    disabled={busy || !state || (scope === "local" && !state.isRepository)}
                  />
                  <Button
                    size="xs"
                    disabled={
                      busy ||
                      !state ||
                      (scope === "local" && !state.isRepository) ||
                      !value.trim() ||
                      value === configured
                    }
                    onClick={() => void save(field)}
                  >
                    {t("git.setup.save")}
                  </Button>
                  <Button
                    size="xs"
                    variant="ghost"
                    disabled={busy || configured == null}
                    onClick={() => void save(field, true)}
                  >
                    {t("git.setup.clear")}
                  </Button>
                </div>
                <p className="ui-text-caption text-subtle-foreground">
                  {effective
                    ? `${t("git.setup.effective")}: ${effective}`
                    : t("git.setup.unconfigured")}
                </p>
                {saved === field && (
                  <p role="status" className="ui-text-caption">
                    {t("git.setup.saved")}
                  </p>
                )}
              </div>
            );
          })}
          <p className="ui-text-caption text-subtle-foreground">{t("git.setup.separateSave")}</p>
          <Button
            size="xs"
            variant="ghost"
            disabled={busy}
            onClick={() => setReload((value) => value + 1)}
          >
            {t("git.setup.reload")}
          </Button>
        </>
      )}
      {busy && <p role="status">{t("git.setup.loading")}</p>}
      {error && (
        <p role="alert" className="ui-text-sm text-destructive">
          {error}
        </p>
      )}
    </Section>
  );
}
