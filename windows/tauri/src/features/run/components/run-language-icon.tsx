import { CodeXml } from "lucide-react";
import type { RunLanguageKey } from "../utils/run-configuration-language";
import { RunConfigurationIcon } from "./run-icon";
import nodeLight from "@/extensions/bundled/icon-themes/lithe/icons/light/files/node.svg?url";
import nodeDark from "@/extensions/bundled/icon-themes/lithe/icons/files/node.svg?url";
import swiftLight from "@/extensions/bundled/icon-themes/pierre/icons/lang-swift-color-light.svg?url";
import swiftDark from "@/extensions/bundled/icon-themes/pierre/icons/lang-swift-color.svg?url";
import phpLight from "@/extensions/bundled/icon-themes/lithe/icons/light/files/php.svg?url";
import phpDark from "@/extensions/bundled/icon-themes/lithe/icons/files/php.svg?url";
import rubyLight from "@/extensions/bundled/icon-themes/pierre/icons/lang-ruby-color-light.svg?url";
import rubyDark from "@/extensions/bundled/icon-themes/pierre/icons/lang-ruby-color.svg?url";
import dotnetLight from "@/extensions/bundled/icon-themes/pierre/icons/lang-csharp-color-light.svg?url";
import dotnetDark from "@/extensions/bundled/icon-themes/pierre/icons/lang-csharp-color.svg?url";

const ASSETS = {
  nodejs: [nodeLight, nodeDark],
  swift: [swiftLight, swiftDark],
  php: [phpLight, phpDark],
  ruby: [rubyLight, rubyDark],
  dotnet: [dotnetLight, dotnetDark],
} as const;
const EXISTING_ICONS = {
  java: "java",
  python: "python",
  rust: "rust",
  go: "go",
  infrastructure: "docker",
  tools: "make",
} as const;

export function RunLanguageIcon({ language }: { language: RunLanguageKey }) {
  if (language in ASSETS) {
    const [light, dark] = ASSETS[language as keyof typeof ASSETS];
    return (
      <svg viewBox="0 0 16 16" className="lithe-idea-icon size-4 shrink-0" aria-hidden>
        <image href={light} width="16" height="16" className="lithe-idea-icon-light" />
        <image href={dark} width="16" height="16" className="lithe-idea-icon-dark" />
      </svg>
    );
  }
  if (language in EXISTING_ICONS) {
    return (
      <RunConfigurationIcon
        provider=""
        iconKey={EXISTING_ICONS[language as keyof typeof EXISTING_ICONS]}
      />
    );
  }
  return <CodeXml className="size-4 shrink-0" aria-hidden />;
}
