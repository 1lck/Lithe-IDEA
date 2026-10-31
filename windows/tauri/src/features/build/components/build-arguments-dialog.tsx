import { useState } from "react";
import { useTranslation } from "@/i18n/locale-provider";
import { Button } from "@/ui/button";
import { PlusIcon, XIcon } from "@/ui/icons";
import Dialog from "@/ui/dialog";
import Input from "@/ui/input";

// Match the public userArguments bound; Core validates again.
const MAX_TASK_ARGUMENTS = 64;

export function BuildArgumentsDialog({ title, onRun, onCancel, submitLabel, initialArguments = [""], busy = false }: { title: string; onRun: (arguments_: string[]) => void; onCancel: () => void; submitLabel?: string; initialArguments?: string[]; busy?: boolean }) {
  const { t } = useTranslation();
  const [arguments_, setArguments] = useState(initialArguments);
  return <Dialog title={title} onClose={onCancel} footer={<>
    <Button variant="ghost" onClick={onCancel}>{t(busy ? "build.window.stop" : "ui.cancel")}</Button>
    <Button variant="accent" disabled={busy} onClick={() => onRun(arguments_)}>{submitLabel ?? t("build.window.runTask")}</Button>
  </>}>
    <div className="flex flex-col gap-2">
      {arguments_.map((value, index) => <div key={index} className="flex items-center gap-1">
        <Input value={value} disabled={busy} aria-label={t("build.window.argument", { index: index + 1 })} onChange={event => {
          const text = event.target.value;
          setArguments(previous => previous.map((value, slot) => slot === index ? text : value));
        }} />
        <Button variant="ghost" size="icon-xs" disabled={busy} aria-label={t("ui.remove")} onClick={() => setArguments(previous => previous.filter((_, slot) => slot !== index))}><XIcon /></Button>
      </div>)}
      <Button variant="ghost" disabled={busy || arguments_.length >= MAX_TASK_ARGUMENTS} onClick={() => setArguments(previous => [...previous, ""])}><PlusIcon />{t("build.window.addArgument")}</Button>
    </div>
  </Dialog>;
}
