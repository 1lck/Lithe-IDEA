import { useEffect, useRef, useState } from "react";
import { invoke } from "@/platform/tauri-core";
import { openFolder } from "@/features/file-system/controllers/platform";
import { useTranslation } from "@/i18n/locale-provider";
import { Button } from "@/ui/button";
import Input from "@/ui/input";
import { Field, FieldDescription, FieldError, FieldLabel } from "@/ui/field";
import { Spinner } from "@/ui/spinner";
import { normalizePath } from "@/utils/path-helpers";
import { setDeclarativePluginEnabled } from "@/features/plugins/declarative-plugin-launch";
import { DeclarativeMarketplaceSection } from "@/features/plugins/marketplace/marketplace-section";
import {
  listMarketplaceInstalledPlugins,
  marketplaceHostService,
} from "@/features/plugins/marketplace/marketplace-host-service";
import {
  GeneratorFormSession,
  canReview,
  emptyFormState,
  pluginActions,
  type GeneratorFormState,
} from "./generator-form-session";
import { GeneratorEnumField } from "./generator-enum-field";
import {
  GenerationSession,
  type CreatedProject,
  type GenerationReview,
} from "./generation-session";

const command = "declarative_plugins_generator_";

export default function ProjectGeneratorWizard({
  parent,
  onBack,
  onClose,
}: {
  parent: string;
  onBack(): void;
  onClose(): void;
}) {
  const { t } = useTranslation();
  const [formState, setFormState] = useState<GeneratorFormState>(emptyFormState);
  const { entries, selected, form, evaluation, loading, enabling } = formState;
  const forms = useRef<GeneratorFormSession | null>(null);
  const [query, setQuery] = useState("");
  const [location, setLocation] = useState(parent);
  const [git, setGit] = useState(false);
  const [advanced, setAdvanced] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [review, setReview] = useState<GenerationReview>();
  const [created, setCreated] = useState<CreatedProject>();
  const alive = useRef(false);
  const [marketplaceQuery, setMarketplaceQuery] = useState<string>();
  const [marketplace] = useState(() => marketplaceHostService(() => {}));
  const session = useRef<GenerationSession | null>(null);
  const errorText = (error: unknown) => {
    const code =
      error && typeof error === "object" && "code" in error
        ? String(error.code)
        : error instanceof Error
          ? error.message
          : "";
    return t(generatorErrorKey(code));
  };

  useEffect(() => {
    alive.current = true;
    const owner = new GenerationSession({
      prepare: (request) => invoke(command + "prepare", { request }),
      generate: (id) => invoke(command + "generate", { id }),
      cancel: (id) => invoke(command + "cancel", { id }),
    });
    session.current = owner;
    const formOwner = new GeneratorFormSession(
      {
        catalog: async () =>
          (await invoke<{ generators: GeneratorFormState["entries"] }>(command + "catalog"))
            .generators,
        evaluate: (entry, form) =>
          invoke(command + "form", {
            pluginId: entry.pluginID,
            generatorId: entry.generator.id,
            packageIdentity: entry.packageIdentity,
            form,
          }),
        enable: (pluginID) => setDeclarativePluginEnabled(pluginID, true),
      },
      setFormState,
    );
    forms.current = formOwner;
    void formOwner.reload();
    return () => {
      alive.current = false;
      formOwner.dispose();
      void owner.close().catch((error) => console.error("Project generator cleanup failed", error));
    };
  }, []);

  const act = async (action: () => Promise<void>) => {
    if (busy) return;
    setBusy(true);
    setError("");
    try {
      await action();
    } catch (error) {
      if (alive.current) setError(errorText(error));
    } finally {
      if (alive.current) setBusy(false);
    }
  };
  const update = (id: string, value: unknown) => {
    setError("");
    void forms.current?.update({
      ...form,
      values: { ...form.values, [id]: value },
      edited: [...new Set([...form.edited, id])],
    });
  };
  const openCreated = async (project: CreatedProject) => {
    const { useFileSystemStore } = await import("@/features/file-system/stores/file-system.store");
    const store = useFileSystemStore.getState();
    if (!(await store.handleOpenFolderByPath(normalizePath(project.root)))) {
      setError(t("newProject.errorCreatedButCouldNotOpen"));
      return;
    }
    const target = useFileSystemStore.getState();
    for (const path of project.openFiles) await target.handleFileOpen(normalizePath(path), false);
    if (alive.current) onClose();
  };
  const cancel = () =>
    act(async () => {
      await session.current?.cancel();
      if (!alive.current) return;
      setReview(undefined);
      if (selected) await forms.current?.choose();
      else onBack();
    });
  const actions = pluginActions(formState);

  if (marketplaceQuery !== undefined)
    return (
      <div className="flex min-h-0 flex-1 flex-col gap-4 overflow-auto p-4">
        <Button
          variant="ghost"
          onClick={() => {
            setMarketplaceQuery(undefined);
            void forms.current?.reload();
          }}
        >
          {t("generator.back")}
        </Button>
        <DeclarativeMarketplaceSection
          key={marketplaceQuery}
          initialQuery={marketplaceQuery}
          service={marketplace}
          installed={listMarketplaceInstalledPlugins}
        />
      </div>
    );

  return (
    <div className="flex min-h-0 flex-1 flex-col gap-4 overflow-auto p-4">
      <div className="flex items-center justify-between gap-2">
        <h2>{t("generator.title")}</h2>
        <Button
          variant="ghost"
          disabled={busy || enabling}
          onClick={() =>
            act(async () => {
              await session.current?.cancel();
              if (!alive.current) return;
              setReview(undefined);
              await forms.current?.reload();
            })
          }
        >
          {t("generator.refresh")}
        </Button>
        <Button variant="ghost" onClick={cancel} disabled={busy && !review}>
          {t("generator.back")}
        </Button>
      </div>
      {error && <FieldError role="alert">{error}</FieldError>}
      {formState.error != null && (
        <FieldError role="alert">{errorText(formState.error)}</FieldError>
      )}
      {loading && <Spinner />}
      {!selected && (
        <>
          <Input
            aria-label={t("generator.search")}
            placeholder={t("generator.search")}
            value={query}
            onChange={(event) => setQuery(event.target.value)}
          />
          {!loading && entries.length === 0 && <p>{t("generator.empty")}</p>}
          {["project", "generator"].map((section) => (
            <section key={section} className="flex flex-col gap-2">
              <h3>{t(section === "project" ? "generator.projects" : "generator.generators")}</h3>
              {entries
                .filter(
                  (entry) =>
                    entry.generator.section === section &&
                    `${entry.generator.displayName} ${entry.pluginName}`
                      .toLowerCase()
                      .includes(query.toLowerCase()),
                )
                .map((entry) => (
                  <Button
                    key={`${entry.pluginID}/${entry.generator.id}`}
                    variant="ghost"
                    disabled={busy}
                    onClick={() => {
                      void forms.current?.choose(entry);
                      setError("");
                    }}
                  >
                    {entry.generator.displayName} · {entry.pluginName}
                    {!entry.pluginEnabled && ` · ${t("generator.disabled")}`}
                  </Button>
                ))}
            </section>
          ))}
        </>
      )}
      {selected && !review && !created && (
        <fieldset disabled={busy || enabling || loading} className="flex flex-col gap-3">
          <h3>{selected.generator.displayName}</h3>
          {!selected.pluginEnabled && <p role="status">{t("generator.enableOwner")}</p>}
          <Field>
            <FieldLabel htmlFor="generator-name">{t("newProject.projectName")}</FieldLabel>
            <Input
              id="generator-name"
              value={form.projectName}
              onChange={(event) => {
                void forms.current?.update({ ...form, projectName: event.target.value });
              }}
            />
            {evaluation?.projectName.problem && (
              <FieldError>{t("generator.invalidField")}</FieldError>
            )}
          </Field>
          <Field>
            <FieldLabel htmlFor="generator-location">{t("newProject.location")}</FieldLabel>
            <Input
              id="generator-location"
              value={location}
              onChange={(event) => setLocation(event.target.value)}
            />
            <Button
              variant="ghost"
              onClick={() =>
                act(async () => {
                  const path = await openFolder();
                  if (alive.current && path) setLocation(path);
                })
              }
            >
              {t("newProject.chooseParentFolder")}
            </Button>
          </Field>
          <label>
            <input
              type="checkbox"
              checked={git}
              onChange={(event) => setGit(event.target.checked)}
            />{" "}
            {t("generator.git")}
          </label>
          <label>
            <input
              type="checkbox"
              checked={advanced}
              onChange={(event) => setAdvanced(event.target.checked)}
            />{" "}
            {t("generator.advanced")}
          </label>
          {selected.generator.fields.map((field) => {
            const state = evaluation?.fields.find((value) => value.id === field.id);
            if (!state?.visible || (field.advanced && !advanced)) return null;
            const id = `generator-field-${field.id}`;
            const value = form.values[field.id] ?? state.value;
            return (
              <Field key={field.id}>
                <FieldLabel htmlFor={id}>{field.title}</FieldLabel>
                {field.description && <FieldDescription>{field.description}</FieldDescription>}
                {field.type === "text" && (
                  <Input
                    id={id}
                    placeholder={field.placeholder}
                    value={String(form.values[field.id] ?? state.value ?? "")}
                    onChange={(event) => update(field.id, event.target.value)}
                  />
                )}
                {field.type === "enum" && (
                  <GeneratorEnumField
                    field={field}
                    value={String(value ?? "")}
                    onChange={(value) => update(field.id, value)}
                  />
                )}
                {field.type === "boolean" && (
                  <input
                    id={id}
                    type="checkbox"
                    checked={Boolean(value)}
                    onChange={(event) => update(field.id, event.target.checked)}
                  />
                )}
                {field.type === "multiSelect" && (
                  <div id={id}>
                    {field.options?.map((option) => (
                      <label key={option.value} className="mr-3">
                        <input
                          type="checkbox"
                          checked={Array.isArray(value) && value.includes(option.value)}
                          onChange={(event) => {
                            const current = Array.isArray(value) ? value : [];
                            update(
                              field.id,
                              event.target.checked
                                ? [...current, option.value]
                                : current.filter((value) => value !== option.value),
                            );
                          }}
                        />{" "}
                        {option.group ? `${option.group} · ${option.title}` : option.title}
                      </label>
                    ))}
                  </div>
                )}
                {field.type === "runtime" && (
                  <div className="flex items-center gap-2">
                    <span>{form.runtimes[field.id]?.home}</span>
                    <Button
                      id={id}
                      variant="ghost"
                      disabled={!selected.pluginEnabled}
                      onClick={() =>
                        act(async () => {
                          const owner = forms.current;
                          const selection = owner?.state.selected;
                          if (!owner || !selection) return;
                          const home = await openFolder();
                          if (
                            !alive.current ||
                            !home ||
                            forms.current !== owner ||
                            owner.state.selected !== selection
                          )
                            return;
                          const runtime = await invoke<{ homePath: string; version: string }>(
                            command + "runtime",
                            { pluginId: selected.pluginID, home },
                          );
                          if (
                            !alive.current ||
                            forms.current !== owner ||
                            owner.state.selected !== selection
                          )
                            return;
                          const current = owner.state.form;
                          await owner.update({
                            ...current,
                            runtimes: {
                              ...current.runtimes,
                              [field.id]: { home: runtime.homePath, version: runtime.version },
                            },
                          });
                        })
                      }
                    >
                      {t("generator.chooseRuntime")}
                    </Button>
                  </div>
                )}
                {state.problem && <FieldError>{t("generator.invalidField")}</FieldError>}
              </Field>
            );
          })}
          {actions.map((action) =>
            action.kind === "enable" ? (
              <Button
                key={action.pluginID}
                variant="ghost"
                onClick={() => {
                  void forms.current?.enable(action.pluginID);
                }}
              >
                {t("generator.enablePlugin", { name: action.name })}
              </Button>
            ) : (
              <Button
                key={`market:${action.query}`}
                variant="ghost"
                onClick={() => {
                  setMarketplaceQuery(action.query);
                }}
              >
                {t("generator.findPlugin", { name: action.query })}
              </Button>
            ),
          )}
          {actions.some(
            (action) =>
              action.kind === "marketplace" ||
              (action.kind === "enable" && action.pluginID !== selected.pluginID),
          ) && <p>{t("generator.advisoryRequirements")}</p>}
          <Button
            disabled={!canReview(formState) || !location || busy}
            onClick={() =>
              act(async () => {
                const next = await session.current?.prepare({
                  pluginId: selected.pluginID,
                  generatorId: selected.generator.id,
                  packageIdentity: selected.packageIdentity,
                  form,
                  parent: location,
                  createGit: git,
                });
                if (alive.current) setReview(next);
              })
            }
          >
            {t("generator.review")}
          </Button>
        </fieldset>
      )}
      {review && !created && (
        <>
          <p>{review.destination}</p>
          {review.plan.usesNetwork && <p>{t("generator.network")}</p>}
          <details>
            <summary>{t("generator.steps", { count: review.plan.steps.length })}</summary>
            <pre className="whitespace-pre-wrap break-all">
              {JSON.stringify(review.plan.steps, null, 2)}
            </pre>
          </details>
          {review.programs.map((program, index) => (
            <pre key={index} className="whitespace-pre-wrap break-all">
              {program.executable}
              {"\n"}
              {JSON.stringify(program.arguments)}
            </pre>
          ))}
          <Button
            disabled={busy}
            onClick={() =>
              act(async () => {
                try {
                  const result = await session.current!.generate();
                  if (alive.current) {
                    setCreated(result);
                    setReview(undefined);
                    await openCreated(result);
                  }
                } finally {
                  if (alive.current) setReview(undefined);
                }
              })
            }
          >
            {busy ? <Spinner /> : t("generator.create")}
          </Button>
          <Button
            variant="ghost"
            disabled={busy}
            onClick={() =>
              act(async () => {
                await session.current?.cancel();
                setReview(undefined);
              })
            }
          >
            {t("generator.edit")}
          </Button>
          {busy && (
            <Button
              variant="ghost"
              onClick={() => {
                void session.current?.cancel().catch((error) => {
                  if (alive.current) setError(errorText(error));
                });
              }}
            >
              {t("generator.cancel")}
            </Button>
          )}
        </>
      )}
      {created && (
        <Button disabled={busy} onClick={() => act(() => openCreated(created))}>
          {t("generator.openCreated")}
        </Button>
      )}
    </div>
  );
}

export function generatorErrorKey(code: string): string {
  switch (code) {
    case "generator.archiveUnavailable":
      return "generator.archiveUnavailable";
    case "generator.downloadFailed":
      return "generator.downloadFailed";
    case "generator.archiveInvalid":
      return "generator.archiveInvalid";
    case "generator.outputLimit":
      return "generator.outputLimit";
    case "generator.cleanupFailed":
      return "generator.cleanupFailed";
    case "generator.destinationExists":
      return "generator.destinationExists";
    case "generator.cancelled":
      return "generator.cancelled";
    case "generator.timeout":
      return "generator.timeout";
    case "generator.toolMissing":
      return "generator.toolMissing";
    case "generator.stale":
      return "generator.stale";
    case "generator.untrusted":
    case "generator.inactive":
      return "generator.pluginUnavailable";
    case "generator.pluginEnableFailed":
      return "generator.pluginEnableFailed";
    case "generator.runtimeInvalid":
      return "generator.runtimeInvalid";
    case "generator.batchArgumentUnsupported":
      return "generator.batchArgumentUnsupported";
    default:
      return "generator.failed";
  }
}
