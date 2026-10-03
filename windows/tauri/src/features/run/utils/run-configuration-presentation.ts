import type { CoreResolvedConfiguration, RunExecution } from "../types/run.types";

const TYPES = {
  spring: "Spring Boot",
  quarkus: "Quarkus",
  micronaut: "Micronaut",
  java: "Java Application",
  maven: "Maven Module",
  gradle: "Gradle",
  docker: "Docker",
  npm: "npm",
  pnpm: "pnpm",
  yarn: "Yarn",
  bun: "Bun",
  next: "Next.js",
  nuxt: "Nuxt",
  sveltekit: "SvelteKit",
  remix: "Remix",
  angular: "Angular",
  nest: "NestJS",
  astro: "Astro",
  vue: "Vue",
  svelte: "Svelte",
  react: "React",
  vite: "Vite",
  python: "Python",
  django: "Django",
  flask: "Flask",
  fastapi: "FastAPI",
  starlette: "Starlette",
  litestar: "Litestar",
  go: "Go",
  rust: "Cargo",
  make: "Make",
  just: "Just",
  procfile: "Procfile",
  terminal: "",
} as const;

export type RunIconKey = keyof typeof TYPES;
interface RunPresentation {
  title: string;
  iconKey: RunIconKey;
}
const presentation = (iconKey: RunIconKey): RunPresentation => ({ title: TYPES[iconKey], iconKey });

const FRAMEWORKS: Readonly<Record<string, RunIconKey>> = {
  next: "next",
  nuxt: "nuxt",
  sveltekit: "sveltekit",
  remix: "remix",
  angular: "angular",
  nest: "nest",
  astro: "astro",
  vue: "vue",
  svelte: "svelte",
  react: "react",
};
const GRADLE_PLUGINS: Readonly<Record<string, RunIconKey>> = {
  "org.springframework.boot": "spring",
  "io.quarkus": "quarkus",
  "io.micronaut.application": "micronaut",
};
const PYTHON_FRAMEWORKS: Readonly<Record<string, RunIconKey>> = {
  django: "django",
  flask: "flask",
  fastapi: "fastapi",
  starlette: "starlette",
  litestar: "litestar",
};
const MANAGERS: Readonly<Record<string, RunIconKey>> = {
  npm: "npm",
  pnpm: "pnpm",
  yarn: "yarn",
  bun: "bun",
};

function knownKey(
  map: Readonly<Record<string, RunIconKey>>,
  value: string | undefined,
): RunIconKey | undefined {
  return value && Object.prototype.hasOwnProperty.call(map, value) ? map[value] : undefined;
}

/** Display only facts supplied by Core; names, commands and process state never identify a type. */
export function runConfigurationPresentation(
  configuration: Pick<CoreResolvedConfiguration, "provider" | "extensions">,
  execution?: RunExecution,
): RunPresentation {
  const { provider, extensions } = configuration;
  const namespace = provider.split(".")[0];
  switch (namespace) {
    case "spring-boot":
      return presentation("spring");
    case "quarkus":
      return presentation("quarkus");
    case "micronaut":
      return presentation("micronaut");
    case "java":
      return {
        ...presentation("java"),
        title: provider === "java.current-file" ? "Current File" : TYPES.java,
      };
    case "maven":
      return presentation("maven");
    case "gradle":
      return presentation(
        execution === "service" && extensions?.gradle?.plugin
          ? (knownKey(GRADLE_PLUGINS, extensions.gradle.plugin) ?? "gradle")
          : "gradle",
      );
    case "compose":
    case "docker":
      return presentation("docker");
    case "npm": {
      const npm = extensions?.npm;
      // Framework metadata describes the whole project, including its lint/build tasks.
      const framework = execution === "service" ? knownKey(FRAMEWORKS, npm?.framework) : undefined;
      if (framework) return presentation(framework);
      if (execution === "service" && npm?.server === "vite") return presentation("vite");
      return presentation(knownKey(MANAGERS, npm?.manager) ?? "npm");
    }
    case "pnpm":
    case "yarn":
    case "bun":
      return presentation(namespace);
    case "python": {
      const framework = extensions?.python?.framework ?? provider.slice("python.".length);
      return presentation(knownKey(PYTHON_FRAMEWORKS, framework) ?? "python");
    }
    case "go":
      return presentation("go");
    case "cargo":
      return presentation("rust");
    case "make":
      return presentation("make");
    case "just":
      return presentation("just");
    case "procfile":
      return presentation("procfile");
    default:
      return { title: namespace.charAt(0).toUpperCase() + namespace.slice(1), iconKey: "terminal" };
  }
}
