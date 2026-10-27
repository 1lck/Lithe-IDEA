import { useVirtualizer } from "@tanstack/react-virtual";
import { useEffect, useId, useRef, useState, type CSSProperties, type KeyboardEvent } from "react";
import { useTranslation } from "@/i18n/locale-provider";
import { Button } from "@/ui/button";
import { Checkbox } from "@/ui/checkbox";
import {
  ContextMenu,
  ContextMenuContent,
  ContextMenuItem,
  ContextMenuTrigger,
} from "@/ui/context-menu";
import { Field, FieldLabel } from "@/ui/field";
import {
  ArrowClockwiseIcon,
  CaretDownIcon,
  CaretRightIcon,
  InfoIcon,
  MinusIcon,
  PlayIcon,
} from "@/ui/icons";
import Input from "@/ui/input";
import NumberInput from "@/ui/number-input";
import { SearchField } from "@/ui/search";
import Select from "@/ui/select";
import { SidebarHeaderIconButton, SidebarPanel, SidebarTitleBar } from "@/ui/sidebar";
import { Spinner } from "@/ui/spinner";
import Textarea from "@/ui/textarea";
import { ToggleGroup } from "@/ui/toggle-group";
import Tooltip from "@/ui/tooltip";
import { getFileTreeRowHeight } from "@/features/file-explorer/lib/file-tree-row";
import { useSettingsStore } from "@/features/settings/stores/settings.store";
import { subscribePluginActivity } from "../declarative-plugin-lifecycle";
import { NativePanelSession, type NativePanelState } from "./native-panel-session";
import { NativePanelStateStore, nativePanelKey } from "./native-panel-state";
import type {
  NativeControl,
  NativePanelIdentity,
  NativePanelPort,
  NativeUI,
  NativeValue,
} from "./native-ui.types";
import "./native-panel.css";

export interface NativePanelProps {
  identity: NativePanelIdentity;
  title: string;
  ui: NativeUI;
  port: NativePanelPort;
  store: NativePanelStateStore;
  onClose(): void;
}

/** The key includes package bytes and panel, workspace and product window.
 * A reused dock slot cannot retain another panel's callbacks or requests. */
export function NativePanel(props: NativePanelProps) {
  return <MountedNativePanel key={nativePanelKey(props.identity)} {...props} />;
}

function MountedNativePanel({ identity, title, ui, port, store, onClose }: NativePanelProps) {
  const { t } = useTranslation();
  const onCloseRef = useRef(onClose);
  onCloseRef.current = onClose;
  const publishRef = useRef<(state: NativePanelState) => void>(() => {});
  const [owner] = useState(
    () => new NativePanelSession(identity, ui, port, store, (state) => publishRef.current(state)),
  );
  const [state, setState] = useState<NativePanelState>(() => owner.state);
  publishRef.current = setState;
  useEffect(() => {
    void owner.open();
    const stop = subscribePluginActivity((pluginId) => {
      if (identity.pluginId === pluginId) {
        owner.close();
        store.revoke(pluginId);
        onCloseRef.current();
      }
    });
    return () => {
      stop();
      owner.close();
    };
  }, [owner, identity.pluginId, store]);
  // All view callbacks carry the epoch they rendered. A reset/reload rejects
  // delayed blur, selection and commit handlers from the previous field draft.
  const epoch = state.epoch;
  const action = (id: string) => {
    void owner.perform(id, epoch);
  };
  const unavailable = !!ui.source || ui.actions.some((action) => action.kind === "invoke");
  return (
    <SidebarPanel className="group/native-panel" data-testid="native-plugin-panel">
      <SidebarTitleBar title={title}>
        <div className="flex items-center gap-1 opacity-0 group-hover/native-panel:opacity-100 focus-within:opacity-100">
          {ui.toolbar.map((id) => {
            const entry = ui.actions.find((action) => action.id === id)!;
            const Icon = entry.kind === "refresh" ? ArrowClockwiseIcon : PlayIcon;
            return (
              <SidebarHeaderIconButton
                key={id}
                aria-label={entry.title}
                tooltip={entry.title}
                disabled={!owner.canPerform(entry)}
                onClick={() => action(id)}
              >
                <Icon className="size-4" />
              </SidebarHeaderIconButton>
            );
          })}
          <SidebarHeaderIconButton
            aria-label={t("pluginNative.reset")}
            tooltip={t("pluginNative.reset")}
            onClick={() => {
              void owner.reset();
            }}
          >
            <ArrowClockwiseIcon className="size-4" />
          </SidebarHeaderIconButton>
          <SidebarHeaderIconButton
            aria-label={t("pluginNative.close")}
            tooltip={t("pluginNative.close")}
            onClick={onClose}
          >
            <MinusIcon className="size-4" />
          </SidebarHeaderIconButton>
        </div>
      </SidebarTitleBar>
      {state.phase === "loading" && <Spinner />}
      {state.busy && (
        <div role="status" className="px-3">
          <Spinner />
          <span className="sr-only">{t("pluginNative.loading")}</span>
        </div>
      )}
      {state.error && (
        <p role="alert" className="break-words px-3 py-2 text-destructive">
          {t(state.error)}
        </p>
      )}
      {unavailable && !port.functions && state.error !== "pluginNative.unavailable" && (
        <p role="status" className="px-3 py-2 text-subtle-foreground">
          {t("pluginNative.unavailable")}
        </p>
      )}
      {state.phase === "ready" &&
        (ui.kind === "form" ? (
          <div className="plugin-native-form min-h-0 flex-1 overflow-auto px-3 pb-3">
            <div
              className="plugin-native-grid"
              style={{ "--native-columns": ui.layout?.columns ?? 1 } as CSSProperties}
            >
              {(ui.controls ?? []).map((control) => (
                <NativeField
                  key={control.id}
                  control={control}
                  value={state.values[control.id]}
                  busy={state.busy}
                  span={control.span ?? ui.layout?.columns ?? 1}
                  change={(value, commit) => {
                    void owner.edit(control.id, value, epoch, commit).then((accepted) => {
                      if (accepted && commit && control.onCommit)
                        void owner.perform(control.onCommit, epoch);
                    });
                  }}
                />
              ))}
            </div>
            <div className="mt-3 flex flex-wrap items-start gap-1.5">
              {(ui.buttons ?? []).map((button) => {
                const declared = ui.actions.find((action) => action.id === button.action)!;
                return (
                  <div key={button.id} className="flex min-w-0 items-center gap-1.5">
                    <Button
                      variant={button.primary ? "default" : "accent"}
                      disabled={button.enabled === false || !owner.canPerform(declared)}
                      onClick={() => action(button.action)}
                    >
                      {button.label}
                    </Button>
                    {button.info && <NativeInfo label={button.label} info={button.info} />}
                  </div>
                );
              })}
            </div>
          </div>
        ) : (
          <NativeTree owner={owner} state={state} title={title} />
        ))}
    </SidebarPanel>
  );
}

function NativeInfo({ label, info }: { label: string; info: string }) {
  const { t } = useTranslation();
  return (
    <Tooltip content={info}>
      <Button variant="ghost" size="icon-xs" aria-label={t("pluginNative.info", { name: label })}>
        <InfoIcon className="size-4" />
      </Button>
    </Tooltip>
  );
}

function NativeField({
  control,
  value,
  busy,
  span,
  change,
}: {
  control: NativeControl;
  value: NativeValue;
  busy: boolean;
  span: number;
  change(value: NativeValue, commit: boolean): void;
}) {
  const id = useId();
  const disabled = busy || control.enabled === false;
  const composing = useRef(false);
  const options = (control.options ?? []).map((option) => ({
    value: option.id,
    label: option.label,
  }));
  const enter = (event: KeyboardEvent<HTMLInputElement>) => {
    if (event.key === "Enter" && !composing.current && !event.nativeEvent.isComposing) {
      event.preventDefault();
      change(event.currentTarget.value, true);
    }
  };
  const inputProps = {
    id,
    disabled,
    "aria-label": control.label,
    value: String(value),
    onCompositionStart: () => {
      composing.current = true;
    },
    onCompositionEnd: () => {
      composing.current = false;
    },
    onKeyDown: enter,
  };
  return (
    <Field style={{ "--native-span": span } as CSSProperties}>
      <div className="flex items-center gap-1.5">
        <FieldLabel htmlFor={id}>{control.label}</FieldLabel>
        {control.info && <NativeInfo label={control.label} info={control.info} />}
      </div>
      {control.kind === "input" && (
        <Input
          {...inputProps}
          placeholder={control.placeholder}
          onChange={(event) => change(event.target.value, false)}
        />
      )}
      {control.kind === "search" && (
        <SearchField
          {...inputProps}
          placeholder={control.placeholder}
          onChange={(value) => change(value, false)}
        />
      )}
      {control.kind === "editor" && (
        <Textarea
          id={id}
          aria-label={control.label}
          disabled={disabled}
          rows={control.rows ?? 4}
          value={String(value)}
          onChange={(event) => change(event.target.value, false)}
        />
      )}
      {control.kind === "select" && (
        <Select
          id={id}
          aria-label={control.label}
          disabled={disabled}
          options={options}
          value={String(value)}
          onChange={(value) => change(value, true)}
        />
      )}
      {control.kind === "segmented" && (
        <fieldset disabled={disabled}>
          <ToggleGroup
            ariaLabel={control.label}
            variant="segmented"
            options={options}
            value={String(value)}
            onValueChange={(value) => change(value, true)}
          />
        </fieldset>
      )}
      {control.kind === "checkbox" && (
        <Checkbox
          id={id}
          aria-label={control.label}
          disabled={disabled}
          checked={value === true}
          onCheckedChange={(value) => change(value, true)}
        />
      )}
      {control.kind === "stepper" && (
        <NumberInput
          id={id}
          aria-label={control.label}
          disabled={disabled}
          min={control.minimum}
          max={control.maximum}
          step={control.step}
          value={Number(value)}
          onChange={(value) => change(value, true)}
        />
      )}
    </Field>
  );
}

function NativeTree({
  owner,
  state,
  title,
}: {
  owner: NativePanelSession;
  state: NativePanelState;
  title: string;
}) {
  const { t } = useTranslation();
  const viewport = useRef<HTMLDivElement>(null);
  const prefix = useId();
  const rowHeight = getFileTreeRowHeight(useSettingsStore((state) => state.settings.uiFontSize));
  const virtual = useVirtualizer({
    count: state.rows.length,
    getScrollElement: () => viewport.current,
    estimateSize: () => rowHeight,
    getItemKey: (index) => state.rows[index].node.id,
    overscan: 8,
    initialRect: { width: 0, height: 300 },
  });
  const selectedIndex = state.rows.findIndex((row) => row.node.id === state.selection);
  const visible = virtual.getVirtualItems();
  const selectedIsMounted = visible.some((item) => item.index === selectedIndex);
  return (
    <div
      ref={viewport}
      className="min-h-0 flex-1 overflow-auto px-1 outline-none"
      role={owner.ui.kind === "tree" ? "tree" : "listbox"}
      tabIndex={0}
      aria-label={title}
      aria-activedescendant={selectedIsMounted ? `${prefix}-${state.selection}` : undefined}
      onKeyDown={(event) => {
        if (
          event.nativeEvent.isComposing ||
          ![
            "ArrowUp",
            "ArrowDown",
            "ArrowLeft",
            "ArrowRight",
            "Home",
            "End",
            "Enter",
            " ",
          ].includes(event.key)
        )
          return;
        event.preventDefault();
        const selected = owner.navigate(event.key);
        const index = owner.state.rows.findIndex((row) => row.node.id === selected);
        if (index >= 0) virtual.scrollToIndex(index, { align: "auto" });
      }}
    >
      {!state.rows.length && (
        <p className="p-3 text-subtle-foreground">{t("pluginNative.empty")}</p>
      )}
      <div className="relative" style={{ height: virtual.getTotalSize() }}>
        {visible.map((item) => {
          const row = state.rows[item.index];
          const branch = !!row.node.children?.length;
          const expanded = state.expanded.includes(row.node.id);
          const Caret = expanded ? CaretDownIcon : CaretRightIcon;
          return (
            <ContextMenu key={row.node.id}>
              <ContextMenuTrigger
                render={<div />}
                id={`${prefix}-${row.node.id}`}
                role={owner.ui.kind === "tree" ? "treeitem" : "option"}
                aria-selected={state.selection === row.node.id}
                aria-level={owner.ui.kind === "tree" ? row.depth + 1 : undefined}
                aria-posinset={row.position}
                aria-setsize={row.siblings}
                aria-expanded={branch ? expanded : undefined}
                className={`absolute inset-x-0 flex min-w-0 items-center rounded px-2 hover:bg-accent/50 ${state.selection === row.node.id ? "bg-accent text-foreground" : ""}`}
                style={{
                  height: rowHeight,
                  transform: `translateY(${item.start}px)`,
                  paddingLeft: 8 + row.depth * 12,
                }}
                onClick={() => {
                  owner.select(row.node.id);
                  viewport.current?.focus();
                }}
                onContextMenu={() => owner.select(row.node.id)}
              >
                {branch ? (
                  <Button
                    variant="ghost"
                    size="icon-xs"
                    aria-label={t(expanded ? "pluginNative.collapse" : "pluginNative.expand", {
                      name: row.node.label,
                    })}
                    onClick={(event) => {
                      event.stopPropagation();
                      owner.toggle(row.node.id);
                      viewport.current?.focus();
                    }}
                  >
                    <Caret className="size-3" />
                  </Button>
                ) : (
                  <span className="w-6 shrink-0" />
                )}
                <span className="truncate">{row.node.label}</span>
              </ContextMenuTrigger>
              {owner.ui.contextMenu.length > 0 && (
                <ContextMenuContent>
                  {owner.ui.contextMenu.map((id) => {
                    const action = owner.ui.actions.find((action) => action.id === id)!;
                    return (
                      <ContextMenuItem
                        key={id}
                        disabled={!owner.canPerform(action)}
                        onClick={() => {
                          void owner.perform(id, state.epoch);
                        }}
                      >
                        {action.title}
                      </ContextMenuItem>
                    );
                  })}
                </ContextMenuContent>
              )}
            </ContextMenu>
          );
        })}
      </div>
    </div>
  );
}
