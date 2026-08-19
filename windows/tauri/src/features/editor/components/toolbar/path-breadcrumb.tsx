import { Fragment, type MouseEvent, type ReactNode } from "react";
import { Button } from "@/ui/button";
import {
  Breadcrumb,
  BreadcrumbItem,
  BreadcrumbLink,
  BreadcrumbList,
  BreadcrumbPage,
  BreadcrumbSeparator,
} from "@/ui/breadcrumb";
import { useTranslation } from "@/i18n/locale-provider";
import { cn } from "@/utils/cn";

interface PathBreadcrumbProps {
  segments: string[];
  interactive?: boolean;
  onSegmentClick?: (index: number, event: MouseEvent<HTMLButtonElement>) => void;
  setSegmentRef?: (index: number, element: HTMLButtonElement | null) => void;
  lastSegmentLeading?: ReactNode;
  className?: string;
}

export function PathBreadcrumb({
  segments,
  interactive = false,
  onSegmentClick,
  setSegmentRef,
  lastSegmentLeading,
  className,
}: PathBreadcrumbProps) {
  const { t } = useTranslation();
  if (segments.length === 0) return null;

  return (
    <Breadcrumb
      aria-label={t("footer.filePath")}
      className={cn("min-w-0 overflow-x-auto scrollbar-none", className)}
    >
      <BreadcrumbList className="flex-nowrap gap-0">
        {segments.map((segment, index) => {
          const isLast = index === segments.length - 1;

          return (
            <Fragment key={`${segment}-${index}`}>
              {index > 0 ? <BreadcrumbSeparator className="mx-0.5 shrink-0" /> : null}
              <BreadcrumbItem className="shrink-0 gap-0">
                {interactive ? (
                  <BreadcrumbLink
                    render={
                      <Button
                        ref={(element) => setSegmentRef?.(index, element)}
                        onClick={(event) => onSegmentClick?.(index, event)}
                        variant="ghost"
                        size="xs"
                        data-slot="breadcrumb-segment"
                      />
                    }
                    className={cn(
                      "min-w-0 items-center gap-1 whitespace-nowrap",
                      isLast
                        ? "font-medium text-foreground hover:text-foreground"
                        : "text-subtle-foreground hover:text-foreground",
                    )}
                  >
                    {isLast && lastSegmentLeading ? (
                      <span className="flex shrink-0 items-center">{lastSegmentLeading}</span>
                    ) : null}
                    {segment}
                  </BreadcrumbLink>
                ) : isLast ? (
                  <BreadcrumbPage
                    data-slot="breadcrumb-segment"
                    className="inline-flex items-center gap-1 truncate px-1.5"
                  >
                    {lastSegmentLeading ? (
                      <span className="flex shrink-0 items-center">{lastSegmentLeading}</span>
                    ) : null}
                    {segment}
                  </BreadcrumbPage>
                ) : (
                  <span
                    data-slot="breadcrumb-segment"
                    className="truncate px-1.5 text-subtle-foreground"
                  >
                    {segment}
                  </span>
                )}
              </BreadcrumbItem>
            </Fragment>
          );
        })}
      </BreadcrumbList>
    </Breadcrumb>
  );
}
