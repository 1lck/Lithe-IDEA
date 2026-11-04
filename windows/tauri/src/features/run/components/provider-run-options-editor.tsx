import { useRef } from "react";
import { useVirtualizer } from "@tanstack/react-virtual";
import { useTranslation } from "@/i18n/locale-provider";
import { Button } from "@/ui/button";
import Input from "@/ui/input";
import Textarea from "@/ui/textarea";
import { Field, FieldDescription, FieldLabel } from "@/ui/field";
import { PlusIcon, XIcon } from "@/ui/icons";
import { ScrollArea } from "@/ui/scroll-area";
import type { BuildProviderRunOptions } from "../types/run.types";

/** Each row is one exact argv element, including an empty string. The
 * provider interprets these values; the editor does not parse a shell line. */
export function ProviderRunOptionsEditor({ value, onChange }: {
  value?: BuildProviderRunOptions; onChange: (value: BuildProviderRunOptions) => void;
}) {
  const { t } = useTranslation(), viewport = useRef<HTMLDivElement>(null);
  const arguments_ = value?.runtimeArguments ?? [];
  const update = (patch: Partial<BuildProviderRunOptions>) => onChange({ runtimeArguments: [], entrypoint: "", options: {}, ...value, ...patch });
  const virtual = useVirtualizer({ count: arguments_.length, getScrollElement: () => viewport.current,
    estimateSize: () => 36, overscan: 4 });
  const row = (index: number) => <div className="flex h-9 items-center gap-1" key={index}>
    <Textarea aria-label={t("build.window.argument", { index: index + 1 })} rows={1} className="h-8 resize-none font-mono" value={arguments_[index]!}
      onChange={event => { const text = event.target.value; update({ runtimeArguments: arguments_.map((value, slot) => slot === index ? text : value) }); }} />
    <Button type="button" variant="ghost" size="icon-xs" aria-label={t("ui.remove")}
      onClick={() => update({ runtimeArguments: arguments_.filter((_, slot) => slot !== index) })}><XIcon /></Button>
  </div>;
  return <>
    <Field>
      <FieldLabel>{t("run.provider.runtimeArguments")}</FieldLabel>
      <FieldDescription>{t("run.provider.runtimeArgumentsHint")}</FieldDescription>
      <ScrollArea style={{ height: Math.min(216, arguments_.length * 36) }} viewportProps={{ ref: viewport }}>
        {arguments_.length <= 6 ? arguments_.map((_, index) => row(index)) : <div className="relative" style={{ height: virtual.getTotalSize() }}>
          {virtual.getVirtualItems().map(item => <div key={item.key} className="absolute top-0 w-full" style={{ transform: `translateY(${item.start}px)` }}>{row(item.index)}</div>)}
        </div>}
      </ScrollArea>
      <Button type="button" variant="ghost" disabled={arguments_.length >= 1024}
        onClick={() => update({ runtimeArguments: [...arguments_, ""] })}><PlusIcon />{t("build.window.addArgument")}</Button>
    </Field>
    <Field>
      <FieldLabel htmlFor="run-provider-entrypoint">{t("run.provider.entrypoint")}</FieldLabel>
      <Input id="run-provider-entrypoint" className="font-mono" value={value?.entrypoint ?? ""}
        onChange={event => update({ entrypoint: event.target.value })} />
    </Field>
  </>;
}
