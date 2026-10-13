import type { ExtensionRunPlan, RunActionExtensionAPI } from "../../SDK/run-actions";

const priority = [
  "dev",
  "start",
  "test",
  "check",
  "typecheck",
  "lint",
  "build",
  "format",
  "preview",
];

export function discoverRunActions(manifests: Record<string, string>): ExtensionRunPlan[] {
  const actions: ExtensionRunPlan[] = [];
  if (manifests["composer.json"]) {
    try {
      const scripts: unknown = JSON.parse(manifests["composer.json"]).scripts;
      if (scripts && typeof scripts === "object" && !Array.isArray(scripts)) {
        const rank = (name: string) =>
          priority.includes(name) ? priority.indexOf(name) : priority.length;
        for (const [name, script] of Object.entries(scripts)
          .filter(
            ([, value]) =>
              typeof value === "string" ||
              (Array.isArray(value) && value.every((part) => typeof part === "string")),
          )
          .sort(([a], [b]) => rank(a) - rank(b) || a.localeCompare(b))
          .slice(0, 40)) {
          actions.push({
            id: `composer:${name}`,
            name,
            sourceLabel: "composer.json",
            description: Array.isArray(script) ? script.join("\n") : String(script),
            executable: "composer",
            arguments: ["run", "--", name],
          });
        }
      }
    } catch {
      // An incomplete manifest during editing contributes no Composer actions.
    }
  }
  if ("phpunit.xml" in manifests || "phpunit.xml.dist" in manifests) {
    actions.push({
      id: "phpunit",
      name: "PHPUnit",
      sourceLabel: "PHPUnit",
      executable: "php",
      arguments: ["vendor/bin/phpunit"],
    });
  }
  return actions;
}

let registration: { dispose(): void } | undefined;
export function activate(api: RunActionExtensionAPI) {
  registration = api.runActions.register(discoverRunActions);
}
export function deactivate() {
  registration?.dispose();
  registration = undefined;
}
