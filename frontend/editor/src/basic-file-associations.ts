// Syntax associations do not imply language-server or build-provider support.
export const BASIC_FILE_ASSOCIATIONS = [
  { id: "makefile", extensions: [".mk", ".mak"], filenames: ["makefile", "gnumakefile"], prefixes: ["makefile."] },
  { id: "cmake", extensions: [".cmake"], filenames: ["cmakelists.txt"] },
  { id: "groovy", extensions: [".groovy", ".gradle"], filenames: ["jenkinsfile"] },
  { id: "kotlin", extensions: [".gradle.kts"] },
  { id: "powershell", extensions: [".ps1", ".psm1", ".psd1"] },
  { id: "batch", extensions: [".bat", ".cmd"] },
  { id: "bash", extensions: [".sh", ".bash", ".zsh"],
    filenames: [".bashrc", ".zshrc", ".bash_profile", ".zprofile", ".profile"] },
  { id: "dotenv", filenames: [".env"], prefixes: [".env."] },
  { id: "dockerfile", filenames: ["dockerfile", "containerfile"], prefixes: ["dockerfile.", "containerfile."] },
] as const;

/** Both hosts use case-insensitive basenames, including Windows paths. */
export function basicLanguageForFilename(filename: string): string | undefined {
  const name = filename.replace(/\\/g, "/").split("/").pop()!.toLowerCase();
  for (const association of BASIC_FILE_ASSOCIATIONS) {
    if ("filenames" in association && association.filenames.some(file => file === name)) return association.id;
    if ("prefixes" in association && association.prefixes.some(prefix => name.startsWith(prefix))) return association.id;
  }
  return BASIC_FILE_ASSOCIATIONS.flatMap(association => "extensions" in association
    ? association.extensions.map(extension => ({ id: association.id, extension })) : [])
    .filter(association => name.endsWith(association.extension))
    .sort((left, right) => right.extension.length - left.extension.length)[0]?.id;
}
