import { isJavaIdentifier, isJavaPackageName } from "@/utils/java-name-validation";
export { isJavaIdentifier, isJavaPackageName };
export const JAVA_TYPE_KINDS = [
  "class",
  "interface",
  "record",
  "enum",
  "annotation",
  "exception",
  "abstractClass",
  "packageInfo",
] as const;
export type JavaTypeKind = (typeof JAVA_TYPE_KINDS)[number];
export function renderJavaType(
  kind: JavaTypeKind,
  name: string,
  packageName: string,
  withMain = false,
): string {
  if (!JAVA_TYPE_KINDS.includes(kind) || !isJavaPackageName(packageName, kind !== "packageInfo")) {
    throw new Error("javaEntry.invalidPackage");
  }
  if (kind !== "packageInfo" && !isJavaIdentifier(name)) throw new Error("javaEntry.invalidName");
  const prefix = packageName ? `package ${packageName};\n\n` : "";
  if (kind === "packageInfo")
    return `/**\n * Package ${packageName}.\n */\npackage ${packageName};\n`;
  const declaration = {
    class: "class",
    interface: "interface",
    enum: "enum",
    record: "record",
    annotation: "@interface",
    abstractClass: "abstract class",
    exception: "class",
  }[kind];
  const body =
    kind === "enum"
      ? "    ;\n"
      : kind === "class" && withMain
        ? "    public static void main(String[] args) {\n        \n    }\n"
        : "";
  return `${prefix}public ${declaration} ${name}${kind === "record" ? "()" : kind === "exception" ? " extends Exception" : ""} {\n${body}}\n`;
}

/** Conventional-folder suggestion only; the dialog lets users correct the package.
 * Custom source roots remain user-owned; this is not a second Java project model.
 */
export function suggestJavaSourceLocation(
  root: string,
  directory: string,
): { sourceRoot: string; packageName: string } {
  const normalized = directory.replace(/\\/g, "/").replace(/\/+$/, "");
  const workspace = root.replace(/\\/g, "/").replace(/\/+$/, "");
  if (
    normalized.toLowerCase() !== workspace.toLowerCase() &&
    !normalized.toLowerCase().startsWith(`${workspace.toLowerCase()}/`)
  ) {
    return { sourceRoot: directory, packageName: "" };
  }
  const relative = normalized.slice(workspace.length).replace(/^\//, "");
  const conventional =
    relative.match(/(?:^|\/)src\/(?:main|test)\/java(?:\/|$)/) ??
    relative.match(/(?:^|\/)src(?:\/|$)/);
  const boundary = conventional ? conventional.index! + conventional[0].length : 0;
  const packagePath = relative.slice(boundary);
  const packageName = packagePath.replace(/\//g, ".");
  if (!isJavaPackageName(packageName, true)) return { sourceRoot: directory, packageName: "" };
  const sourceRoot = boundary
    ? `${workspace}/${relative.slice(0, boundary).replace(/\/$/, "")}`
    : workspace;
  return { sourceRoot, packageName };
}
