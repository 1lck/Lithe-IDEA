import { useBufferStore } from "@/features/editor/stores/buffer.store";
import { GitHubMarkdownEditor } from "@/features/github/components/github-markdown-editor";
import { useTranslation } from "@/i18n/locale-provider";

interface MarkdownDocumentViewProps {
  bufferId: string;
}

export function MarkdownDocumentView({ bufferId }: MarkdownDocumentViewProps) {
  const { t } = useTranslation();
  const buffer = useBufferStore((state) => {
    const candidate = state.buffers.find((item) => item.id === bufferId);
    return candidate?.type === "markdownDocument" ? candidate : null;
  });
  const updateBuffer = useBufferStore.use.actions().updateBuffer;

  if (!buffer) return null;

  return (
    <div className="size-full overflow-auto bg-background px-6 pt-7 pb-16">
      <div className="mx-auto w-full max-w-3xl">
        <GitHubMarkdownEditor
          value={buffer.content}
          onChange={(content) => updateBuffer({ ...buffer, content })}
          placeholder={t("markdownDocument.placeholder")}
          minHeight={560}
          autoFocus
        />
      </div>
    </div>
  );
}
