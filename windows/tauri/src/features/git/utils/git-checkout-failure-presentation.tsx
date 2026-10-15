import { toast } from "sonner";
import { BalloonErrorIcon } from "@/ui/icons";

// Note: IDEA GitCheckoutOperation reports failures as a sticky ERROR balloon
// titled "Could not checkout {0}" (GitBundle checkout.operation.could.not.checkout.error.title)
// whose body is Git's output after GitUtil.cleanupErrorPrefixes.

const GIT_ERROR_PREFIXES = ["fatal:", "error:"];

/** Mirrors GitUtil.cleanupErrorPrefixes: trims each line and drops Git's severity prefix. */
export function presentableGitErrorOutput(output: string): string {
  return output
    .split(/\r?\n/)
    .map((line) => {
      let cleaned = line.trim();
      for (const prefix of GIT_ERROR_PREFIXES) {
        if (cleaned.startsWith(prefix)) cleaned = cleaned.slice(prefix.length).trim();
      }
      return cleaned;
    })
    .filter(Boolean)
    .join("\n");
}

export function showCheckoutFailure(
  t: (key: string, values?: Record<string, string | number>) => string,
  reference: string,
  output: string,
) {
  const description = presentableGitErrorOutput(output);
  return toast.error(t("git.log.couldNotCheckout", { reference }), {
    description: description || undefined,
    icon: <BalloonErrorIcon size={16} />,
    classNames: { description: "whitespace-pre-line wrap-break-word" },
    // Vcs Important Notifications use STICKY_BALLOON: the user dismisses them.
    duration: Number.POSITIVE_INFINITY,
  });
}
