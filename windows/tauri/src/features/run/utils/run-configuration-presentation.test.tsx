import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { RunConfigurationIcon } from "../components/run-icon";
import { mapCoreConfiguration } from "./run-configuration";
import type { CoreResolvedConfiguration } from "../types/run.types";
import type { RunIconKey } from "./run-configuration-presentation";

function configuration(value: Partial<CoreResolvedConfiguration>) {
  return mapCoreConfiguration({ id: "entry", name: "entry", provider: "custom.command", ...value });
}

// The provider values are the built-in Core discovery outputs, including multi-target providers.
test.each([
  ["spring-boot.maven", "spring"],
  ["quarkus.maven", "quarkus"],
  ["micronaut.maven", "micronaut"],
  ["java.main", "java"],
  ["java.current-file", "java"],
  ["maven.module", "maven"],
  ["gradle.service", "gradle"],
  ["gradle.application", "gradle"],
  ["npm.script", "npm"],
  ["python.script", "python"],
  ["python.django", "django"],
  ["python.flask", "flask"],
  ["python.uvicorn", "python"],
  ["go.main", "go"],
  ["go.command", "go"],
  ["cargo.binary", "rust"],
  ["compose.service", "docker"],
  ["compose.stack", "docker"],
  ["make.target", "make"],
  ["just.recipe", "just"],
  ["procfile.process", "procfile"],
] as const)("Core provider %s renders its type icon", (provider, key) => {
  const mapped = configuration({ provider });
  expect(mapped.iconKey).toBe(key);
  const html = renderToStaticMarkup(
    <RunConfigurationIcon provider={provider} iconKey={mapped.iconKey} />,
  );
  expect(html).toContain(`data-run-icon="${key}"`);
  expect(html).toContain("<svg");
  expect(html).not.toContain("undefined");
});

test.each([
  ["next", "Next.js", "next"],
  ["nuxt", "Nuxt", "nuxt"],
  ["sveltekit", "SvelteKit", "sveltekit"],
  ["remix", "Remix", "remix"],
  ["angular", "Angular", "angular"],
  ["nest", "NestJS", "nest"],
  ["astro", "Astro", "astro"],
  ["vue", "Vue", "vue"],
  ["svelte", "Svelte", "svelte"],
  ["react", "React", "react"],
] as const)(
  "%s services use the framework while tasks retain their manager",
  (framework, title, key) => {
    const source = {
      provider: "npm.script",
      extensions: { npm: { framework, manager: "pnpm", server: "vite" } },
    };
    const service = configuration({ ...source, execution: "service" });
    expect([service.kindTitle, service.iconKey]).toEqual([title, key]);
    expect(
      renderToStaticMarkup(
        <RunConfigurationIcon provider={service.provider} iconKey={service.iconKey} />,
      ),
    ).toContain("<svg");
    const task = configuration({ ...source, execution: "task" });
    expect([task.kindTitle, task.iconKey]).toEqual(["pnpm", "pnpm"]);
  },
);

test.each(["npm", "pnpm", "yarn", "bun"] as const)(
  "npm.script preserves the %s manager icon",
  (manager) => {
    const mapped = configuration({
      provider: "npm.script",
      execution: "service",
      extensions: { npm: { manager } },
    });
    expect(mapped.iconKey).toBe(manager);
    expect(
      renderToStaticMarkup(
        <RunConfigurationIcon provider={mapped.provider} iconKey={mapped.iconKey} />,
      ),
    ).toContain("<image");
  },
);

test("Gradle and Uvicorn services retain explicitly discovered frameworks", () => {
  for (const [plugin, key] of [
    ["org.springframework.boot", "spring"],
    ["io.quarkus", "quarkus"],
    ["io.micronaut.application", "micronaut"],
  ] as const) {
    expect(
      configuration({
        provider: "gradle.service",
        execution: "service",
        extensions: { gradle: { plugin } },
      }).iconKey,
    ).toBe(key);
    expect(
      configuration({
        provider: "gradle.application",
        execution: "task",
        extensions: { gradle: { plugin } },
      }).iconKey,
    ).toBe("gradle");
  }
  for (const framework of ["fastapi", "starlette", "litestar"] as const) {
    const mapped = configuration({
      provider: "python.uvicorn",
      execution: "service",
      extensions: { python: { framework } },
    });
    expect(mapped.iconKey).toBe(framework);
    expect(
      renderToStaticMarkup(
        <RunConfigurationIcon provider={mapped.provider} iconKey={mapped.iconKey} />,
      ),
    ).toContain("<svg");
  }
});

test("missing and unsupported metadata fall back without guessing from names or commands", () => {
  expect(
    configuration({
      provider: "npm.script",
      execution: "service",
      extensions: { npm: { server: "vite" } },
    }).iconKey,
  ).toBe("vite");
  expect(
    configuration({
      provider: "npm.script",
      execution: "task",
      extensions: { npm: { server: "vite" } },
    }).iconKey,
  ).toBe("npm");
  for (const unknown of ["new-framework", "constructor", "__proto__", ""]) {
    expect(
      configuration({
        provider: "npm.script",
        extensions: { npm: { manager: unknown, framework: unknown } },
        execution: "service",
      }).iconKey,
    ).toBe("npm");
    expect(
      configuration({ provider: "python.uvicorn", extensions: { python: { framework: unknown } } })
        .iconKey,
    ).toBe("python");
    expect(
      configuration({
        provider: "gradle.service",
        execution: "service",
        extensions: { gradle: { plugin: unknown } },
      }).iconKey,
    ).toBe("gradle");
  }
  expect(configuration({ name: "Spring Boot Vue Django", args: ["next", "dev"] }).iconKey).toBe(
    "terminal",
  );
});

test("asset icons include both theme variants and the shared 16px viewport", () => {
  const assets: RunIconKey[] = [
    "docker",
    "maven",
    "gradle",
    "npm",
    "pnpm",
    "yarn",
    "bun",
    "next",
    "nuxt",
    "angular",
    "nest",
    "astro",
    "vue",
    "svelte",
    "sveltekit",
    "react",
    "vite",
    "python",
    "go",
    "rust",
  ];
  for (const iconKey of assets) {
    const html = renderToStaticMarkup(
      <RunConfigurationIcon provider="custom.command" iconKey={iconKey} />,
    );
    expect(html).toContain('viewBox="0 0 16 16"');
    expect(html.match(/<image /g)?.length).toBe(2);
    expect(html).toContain('class="lithe-idea-icon-light"');
    expect(html).toContain('class="lithe-idea-icon-dark"');
  }
});
