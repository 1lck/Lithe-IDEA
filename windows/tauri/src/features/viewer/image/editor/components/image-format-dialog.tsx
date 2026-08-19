import { ImageIcon as Image } from "@/ui/icons";
import { useEffect, useState } from "react";
import { Button } from "@/ui/button";
import Dialog from "@/ui/dialog";
import { useTranslation } from "@/i18n/locale-provider";
import { cn } from "@/utils/cn";
import type { ImageFormat } from "../types/image-operation.types";
import { convertImageFormat } from "../utils/image-conversion";
import { formatFileSize } from "@/utils/format-file-size";
import { getDataURLSize } from "../utils/image-file-utils";

interface ImageFormatDialogProps {
  isOpen: boolean;
  onClose: () => void;
  onConvert: (format: ImageFormat, quality?: number) => void;
  format: ImageFormat;
  currentImageSrc: string;
  currentFileName: string;
}

interface FormatConfig {
  name: string;
  descriptionKey: string;
  recommended: number;
  options: { labelKey: string; quality: number }[];
  supportsQuality: boolean;
}

const FORMAT_CONFIGS: Record<ImageFormat, FormatConfig> = {
  png: {
    name: "PNG",
    descriptionKey: "image.losslessTransparency",
    recommended: 1,
    options: [],
    supportsQuality: false,
  },
  jpeg: {
    name: "JPEG",
    descriptionKey: "image.lossySmaller",
    recommended: 0.85,
    options: [
      { labelKey: "image.highQuality", quality: 0.9 },
      { labelKey: "image.recommended", quality: 0.85 },
      { labelKey: "image.balanced", quality: 0.75 },
      { labelKey: "image.smallSize", quality: 0.6 },
    ],
    supportsQuality: true,
  },
  webp: {
    name: "WebP",
    descriptionKey: "image.modernBestCompression",
    recommended: 0.85,
    options: [
      { labelKey: "image.highQuality", quality: 0.9 },
      { labelKey: "image.recommended", quality: 0.85 },
      { labelKey: "image.balanced", quality: 0.75 },
      { labelKey: "image.smallSize", quality: 0.6 },
    ],
    supportsQuality: true,
  },
  avif: {
    name: "AVIF",
    descriptionKey: "image.nextGenCompression",
    recommended: 0.85,
    options: [
      { labelKey: "image.highQuality", quality: 0.9 },
      { labelKey: "image.recommended", quality: 0.85 },
      { labelKey: "image.balanced", quality: 0.75 },
      { labelKey: "image.smallSize", quality: 0.6 },
    ],
    supportsQuality: true,
  },
};

export function ImageFormatDialog({
  isOpen,
  onClose,
  onConvert,
  format,
  currentImageSrc,
  currentFileName,
}: ImageFormatDialogProps) {
  const { t } = useTranslation();
  const config = FORMAT_CONFIGS[format];
  const [selectedQuality, setSelectedQuality] = useState(config.recommended);
  const [estimatedSize, setEstimatedSize] = useState<number | null>(null);
  const [isEstimating, setIsEstimating] = useState(false);

  const currentSize = getDataURLSize(currentImageSrc);

  useEffect(() => {
    if (!isOpen) return;
    setSelectedQuality(config.recommended);
  }, [isOpen, config.recommended]);

  useEffect(() => {
    if (!isOpen || !currentImageSrc) return;

    const estimateSize = async () => {
      setIsEstimating(true);
      try {
        const result = await convertImageFormat(currentImageSrc, {
          format,
          quality: config.supportsQuality ? selectedQuality : undefined,
        });
        const size = result.blob.size;
        setEstimatedSize(size);
      } catch (error) {
        console.error("Failed to estimate size:", error);
        setEstimatedSize(null);
      } finally {
        setIsEstimating(false);
      }
    };

    estimateSize();
  }, [isOpen, currentImageSrc, format, selectedQuality, config.supportsQuality]);

  const handleConvert = () => {
    onConvert(format, config.supportsQuality ? selectedQuality : undefined);
    onClose();
  };

  if (!isOpen) return null;

  const sizeDiff = estimatedSize ? ((estimatedSize - currentSize) / currentSize) * 100 : 0;

  return (
    <Dialog
      title={t("image.convertToFormat", { format: config.name })}
      icon={Image}
      onClose={onClose}
      size="md"
      classNames={{ content: "space-y-4 p-4" }}
      footer={
        <>
          <Button onClick={onClose} variant="default" size="xs">
            {t("ui.cancel")}
          </Button>
          <Button onClick={handleConvert} disabled={isEstimating} variant="accent" size="xs">
            {t("image.convert")}
          </Button>
        </>
      }
    >
      <div className="flex flex-col gap-1">
        <p className="text-foreground ui-text-sm">{t(config.descriptionKey)}</p>
        <p className="text-subtle-foreground ui-text-sm">
          {t("image.currentFile")}: <span className="font-sans">{currentFileName}</span> •{" "}
          {formatFileSize(currentSize)}
        </p>
      </div>

      {config.supportsQuality && (
        <div className="flex flex-col gap-2">
          <div className="font-semibold text-foreground ui-text-sm">
            {t("image.qualitySetting")}
          </div>
          <div className="flex flex-col gap-1">
            {config.options.map((option) => (
              <Button
                key={option.quality}
                type="button"
                onClick={() => setSelectedQuality(option.quality)}
                variant="ghost"
                size="xs"
                className={cn(
                  "flex h-auto items-center justify-between rounded border px-3 py-2 text-left ui-text-sm",
                  selectedQuality === option.quality
                    ? "border-primary bg-primary/10 text-foreground"
                    : "border-border bg-background text-foreground hover:bg-accent",
                )}
              >
                <span>
                  {t(option.labelKey)}
                  {option.quality === config.recommended && (
                    <span className="ml-2 ui-text-sm text-primary">
                      ★ {t("image.recommendedBadge")}
                    </span>
                  )}
                </span>
                <span className="text-subtle-foreground">{Math.round(option.quality * 100)}%</span>
              </Button>
            ))}
          </div>
        </div>
      )}

      <div className="rounded border border-border bg-surface p-3">
        <div className="flex items-center justify-between">
          <span className="text-foreground ui-text-sm">{t("image.estimatedSize")}</span>
          <div className="flex items-center gap-2">
            {isEstimating ? (
              <span className="text-subtle-foreground ui-text-sm">{t("image.calculating")}</span>
            ) : estimatedSize ? (
              <>
                <span className="font-sans text-foreground ui-text-sm">
                  {formatFileSize(estimatedSize)}
                </span>
                {sizeDiff !== 0 && (
                  <span
                    className={cn(
                      "font-sans ui-text-sm",
                      sizeDiff < 0 ? "text-success" : "text-warning",
                    )}
                  >
                    {sizeDiff > 0 ? "+" : ""}
                    {Math.round(sizeDiff)}%
                  </span>
                )}
              </>
            ) : (
              <span className="text-subtle-foreground ui-text-sm">--</span>
            )}
          </div>
        </div>
      </div>
    </Dialog>
  );
}
