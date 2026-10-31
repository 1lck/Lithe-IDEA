/** Public Core language-import projection; hosts forward these facts to the
 * language/runtime adapters without interpreting project descriptors. */
export interface MavenLanguageImportContext {
  version: 1; reactorPath: string; profiles: string[];
  settingsPath?: string | null; localRepositoryPath?: string | null; skipTests?: boolean;
  mavenExecutablePath?: string | null; javaHomePath?: string | null;
}
export type BuildLanguageImport =
  | { kind: "maven"; mavenContext: MavenLanguageImportContext }
  | { kind: "gradle"; javaGradle: { wrapperPresent: boolean; offline: boolean; userHome?: string } };
