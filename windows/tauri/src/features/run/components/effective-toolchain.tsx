import { useTranslation } from "@/i18n/locale-provider";
import {
  describeEffectiveToolchain,
  type EffectiveToolchainMode,
  type EffectiveToolchainState,
} from "../utils/effective-toolchain";

/** The toolchain a launch would use, plus any unmet project requirement. */
export function EffectiveToolchain({
  state,
  kind,
  mode,
  requirements = [],
}: {
  state: EffectiveToolchainState;
  kind: "java" | "maven";
  mode: EffectiveToolchainMode;
  requirements?: string[];
}) {
  const { t } = useTranslation();
  const line = describeEffectiveToolchain(state, kind, mode, t);
  return (
    <div className="space-y-0.5">
      <p
        role={line.tone === "error" ? "alert" : undefined}
        className={`break-all ui-text-caption ${
          line.tone === "error" ? "text-destructive" : "text-foreground"
        }`}
      >
        {line.text}
      </p>
      {requirements.map((message) => (
        <p key={message} role="alert" className="break-all text-destructive ui-text-caption">
          {message}
        </p>
      ))}
    </div>
  );
}
