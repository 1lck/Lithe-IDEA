import type { ComponentType } from "react";
import {
  Blocks,
  Box,
  FlaskConical,
  Leaf,
  ListChecks,
  Orbit,
  Route,
  Sparkles,
  Star,
  Workflow,
  Wrench,
  Zap,
} from "lucide-react";
import { TerminalIcon } from "@/ui/icons";
import { cn } from "@/utils/cn";
import {
  runConfigurationPresentation,
  type RunIconKey,
} from "../utils/run-configuration-presentation";
import dockerLight from "@/extensions/bundled/icon-themes/idea/icons/expui/fileTypes/docker.svg?url";
import dockerDark from "@/extensions/bundled/icon-themes/idea/icons/expui/fileTypes/docker_dark.svg?url";
import mavenLight from "@/extensions/bundled/icon-themes/idea/icons/expui/fileTypes/maven.svg?url";
import mavenDark from "@/extensions/bundled/icon-themes/idea/icons/expui/fileTypes/maven_dark.svg?url";
import gradleLight from "@/extensions/bundled/icon-themes/symbols/icons/files/gradle.svg?url";
import gradleDark from "@/extensions/bundled/icon-themes/symbols/icons/files/gradle.svg?url";
import pnpmLight from "@/extensions/bundled/icon-themes/symbols/icons/files/pnpm.svg?url";
import pnpmDark from "@/extensions/bundled/icon-themes/symbols/icons/files/pnpm.svg?url";
import yarnLight from "@/extensions/bundled/icon-themes/symbols/icons/files/yarn.svg?url";
import yarnDark from "@/extensions/bundled/icon-themes/symbols/icons/files/yarn.svg?url";
import nextLight from "@/extensions/bundled/icon-themes/pierre/icons/nextjs-light.svg?url";
import nextDark from "@/extensions/bundled/icon-themes/pierre/icons/nextjs.svg?url";
import nuxtLight from "@/extensions/bundled/icon-themes/symbols/icons/files/nuxt.svg?url";
import nuxtDark from "@/extensions/bundled/icon-themes/symbols/icons/files/nuxt.svg?url";
import angularLight from "@/extensions/bundled/icon-themes/symbols/icons/files/angular.svg?url";
import angularDark from "@/extensions/bundled/icon-themes/symbols/icons/files/angular.svg?url";
import nestLight from "@/extensions/bundled/icon-themes/symbols/icons/files/nest.svg?url";
import nestDark from "@/extensions/bundled/icon-themes/symbols/icons/files/nest.svg?url";
import astroLight from "@/extensions/bundled/icon-themes/pierre/icons/astro-color-light.svg?url";
import astroDark from "@/extensions/bundled/icon-themes/pierre/icons/astro-color.svg?url";
import vueLight from "@/extensions/bundled/icon-themes/pierre/icons/vue-color-light.svg?url";
import vueDark from "@/extensions/bundled/icon-themes/pierre/icons/vue-color.svg?url";
import svelteLight from "@/extensions/bundled/icon-themes/pierre/icons/svelte-color-light.svg?url";
import svelteDark from "@/extensions/bundled/icon-themes/pierre/icons/svelte-color.svg?url";
import reactLight from "@/extensions/bundled/icon-themes/pierre/icons/react-color-light.svg?url";
import reactDark from "@/extensions/bundled/icon-themes/pierre/icons/react-color.svg?url";
import viteLight from "@/extensions/bundled/icon-themes/pierre/icons/vite-color-light.svg?url";
import viteDark from "@/extensions/bundled/icon-themes/pierre/icons/vite-color.svg?url";
import npmLight from "@/extensions/bundled/icon-themes/pierre/icons/npm-color-light.svg?url";
import npmDark from "@/extensions/bundled/icon-themes/pierre/icons/npm-color.svg?url";
import bunLight from "@/extensions/bundled/icon-themes/symbols/icons/files/bun.svg?url";
import bunDark from "@/extensions/bundled/icon-themes/symbols/icons/files/bun.svg?url";
import pythonLight from "@/extensions/bundled/icon-themes/pierre/icons/lang-python-color-light.svg?url";
import pythonDark from "@/extensions/bundled/icon-themes/pierre/icons/lang-python-color.svg?url";
import goLight from "@/extensions/bundled/icon-themes/pierre/icons/lang-go-color-light.svg?url";
import goDark from "@/extensions/bundled/icon-themes/pierre/icons/lang-go-color.svg?url";
import rustLight from "@/extensions/bundled/icon-themes/pierre/icons/lang-rust-color-light.svg?url";
import rustDark from "@/extensions/bundled/icon-themes/pierre/icons/lang-rust-color.svg?url";

type IconDefinition =
  | { light: string; dark: string }
  | { glyph: ComponentType<{ className?: string }>; className?: string };

// Reuse bundled vector assets. Frameworks without a bundled logo use a consistent semantic glyph.
const ICONS = {
  docker: { light: dockerLight, dark: dockerDark },
  maven: { light: mavenLight, dark: mavenDark },
  gradle: { light: gradleLight, dark: gradleDark },
  pnpm: { light: pnpmLight, dark: pnpmDark },
  yarn: { light: yarnLight, dark: yarnDark },
  next: { light: nextLight, dark: nextDark },
  nuxt: { light: nuxtLight, dark: nuxtDark },
  angular: { light: angularLight, dark: angularDark },
  nest: { light: nestLight, dark: nestDark },
  astro: { light: astroLight, dark: astroDark },
  vue: { light: vueLight, dark: vueDark },
  svelte: { light: svelteLight, dark: svelteDark },
  react: { light: reactLight, dark: reactDark },
  vite: { light: viteLight, dark: viteDark },
  npm: { light: npmLight, dark: npmDark },
  bun: { light: bunLight, dark: bunDark },
  python: { light: pythonLight, dark: pythonDark },
  go: { light: goLight, dark: goDark },
  rust: { light: rustLight, dark: rustDark },
  sveltekit: { light: svelteLight, dark: svelteDark },
  spring: { glyph: Leaf, className: "text-success" },
  quarkus: { glyph: Box },
  micronaut: { glyph: Orbit },
  java: { glyph: JavaCupIcon },
  remix: { glyph: Route },
  django: { glyph: Blocks },
  flask: { glyph: FlaskConical },
  fastapi: { glyph: Zap },
  starlette: { glyph: Star },
  litestar: { glyph: Sparkles },
  make: { glyph: Wrench },
  just: { glyph: ListChecks },
  procfile: { glyph: Workflow },
  terminal: { glyph: TerminalIcon },
} satisfies Record<RunIconKey, IconDefinition>;

export function RunConfigurationIcon({
  provider,
  iconKey,
  className,
}: {
  provider: string;
  iconKey?: RunIconKey;
  className?: string;
}) {
  const key = iconKey ?? runConfigurationPresentation({ provider }).iconKey;
  const definition: IconDefinition = ICONS[key];
  return (
    <span className={cn("inline-flex size-4 shrink-0", className)} aria-hidden data-run-icon={key}>
      {"light" in definition ? (
        <svg viewBox="0 0 16 16" className="lithe-idea-icon size-full">
          <image href={definition.light} width="16" height="16" className="lithe-idea-icon-light" />
          <image href={definition.dark} width="16" height="16" className="lithe-idea-icon-dark" />
        </svg>
      ) : (
        <definition.glyph className={cn("size-full", definition.className)} />
      )}
    </span>
  );
}

export function JavaCupIcon({ className }: { className?: string }) {
  return (
    <svg viewBox="0 0 16 16" width="14" height="14" fill="none" className={className} aria-hidden>
      <path
        d="M3.5 5.5h7.25c.97 0 1.75.78 1.75 1.75S11.72 9 10.75 9H10.5"
        stroke="currentColor"
        strokeWidth="1.15"
        strokeLinecap="round"
      />
      <path
        d="M3.75 5.5h6.5v4.25a2.75 2.75 0 0 1-2.75 2.75h-1A2.75 2.75 0 0 1 3.75 9.75V5.5Z"
        stroke="currentColor"
        strokeWidth="1.15"
      />
      <path d="M4.25 13.25h5.5" stroke="currentColor" strokeWidth="1.15" strokeLinecap="round" />
    </svg>
  );
}
