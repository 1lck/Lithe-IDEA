export interface InitializrChoice {
  id: string;
  name: string;
  description?: string;
}
export interface InitializrMetadata {
  bootVersion: { default: string; values: InitializrChoice[] };
  javaVersion: { default: string; values: InitializrChoice[] };
  dependencies: { values: Array<{ name: string; values: InitializrChoice[] }> };
}
export interface SpringProjectOptions {
  groupId: string;
  artifactId: string;
  packageName: string;
  javaVersion: string;
  bootVersion: string;
  buildType: "maven-project" | "gradle-project" | "gradle-project-kotlin";
  dependencies: string[];
}

export function parseInitializrMetadata(value: unknown): InitializrMetadata {
  const metadata = value as InitializrMetadata | null;
  const isChoices = (choices: unknown): choices is InitializrChoice[] =>
    Array.isArray(choices) &&
    choices.every((choice) => typeof choice?.id === "string" && typeof choice?.name === "string");
  if (
    !metadata ||
    !isChoices(metadata.bootVersion?.values) ||
    !isChoices(metadata.javaVersion?.values) ||
    !metadata.bootVersion.values.some(({ id }) => id === metadata.bootVersion.default) ||
    !metadata.javaVersion.values.some(({ id }) => id === metadata.javaVersion.default) ||
    !Array.isArray(metadata.dependencies?.values) ||
    !metadata.dependencies.values.every((group) => isChoices(group.values))
  ) {
    throw new Error("Invalid Spring Initializr metadata.");
  }
  return metadata;
}
