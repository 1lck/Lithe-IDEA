import type { ReactNode } from "react";
import { toast } from "sonner";
import { useTranslation } from "@/i18n/locale-provider";
import { InfoIcon, XIcon } from "@/ui/icons";
import { cn } from "@/utils/cn";

export interface IdeaNotificationAction {
  label: string;
  onClick: () => void;
}

interface IdeaNotificationCardProps {
  /** Bold lead-in such as "Deleted Branch:", like IDEA's `<b>…</b>` notification titles. */
  title: string;
  /** Plain text after the title, for example the branch name. */
  message?: string;
  actions?: readonly IdeaNotificationAction[];
  icon?: ReactNode;
  onDismiss: () => void;
}

/**
 * Notification card laid out like IDEA's balloon: an information icon, a bold lead-in
 * followed by the details, and the actions as plain accent-coloured links on their own row
 * rather than filled buttons. A close button sits in the top-right corner.
 */
export function IdeaNotificationCard({
  title,
  message,
  actions = [],
  icon,
  onDismiss,
}: IdeaNotificationCardProps) {
  const { t } = useTranslation();
  return (
    <div
      role="status"
      data-slot="idea-notification"
      // The shared Toaster reserves pr-8 around toast content for its own close button; this
      // card draws its own, so cancel that gutter to keep the close button in the corner. The
      // width follows Sonner's variable so the card is as wide as every other toast.
      className="-mr-8 flex w-(--width) max-w-[calc(100vw-2rem)] items-start gap-2.5 py-3 pr-2.5 pl-3 font-sans text-foreground"
    >
      <span className="mt-0.5 shrink-0 text-primary [&_svg:not([class*='size-'])]:size-4">
        {icon ?? <InfoIcon aria-hidden="true" />}
      </span>
      <div className="min-w-0 flex-1 ui-text-sm leading-5">
        <p className="wrap-anywhere">
          <span className="font-semibold">{title}</span>
          {message ? <span> {message}</span> : null}
        </p>
        {actions.length > 0 ? (
          <div className="mt-1 flex flex-wrap gap-x-3 gap-y-0.5">
            {actions.map((action) => (
              <button
                key={action.label}
                type="button"
                className={cn(
                  "cursor-pointer rounded-sm text-primary outline-none hover:underline",
                  "focus-visible:ring-2 focus-visible:ring-ring/50",
                )}
                onClick={() => {
                  onDismiss();
                  action.onClick();
                }}
              >
                {action.label}
              </button>
            ))}
          </div>
        ) : null}
      </div>
      <button
        type="button"
        aria-label={t("ui.closeToast")}
        className="flex size-4.5 shrink-0 cursor-pointer items-center justify-center rounded-md text-subtle-foreground outline-none hover:bg-accent hover:text-foreground focus-visible:ring-2 focus-visible:ring-ring/50"
        onClick={onDismiss}
      >
        <XIcon aria-hidden="true" className="size-3.5" />
      </button>
    </div>
  );
}

/** Shows an IDEA-style notification in the shared toast stack and returns its toast id. */
export function showIdeaNotification({
  duration,
  id,
  ...card
}: Omit<IdeaNotificationCardProps, "onDismiss"> & {
  duration?: number;
  id?: string | number;
}) {
  // Sonner spreads these options over the id it generates, so an explicit `undefined` would
  // erase it and the close button could no longer find its toast.
  const options: { duration?: number; id?: string | number } = {};
  if (duration !== undefined) options.duration = duration;
  if (id !== undefined) options.id = id;
  return toast.custom(
    (toastId) => <IdeaNotificationCard {...card} onDismiss={() => toast.dismiss(toastId)} />,
    options,
  );
}
