/** Native invoke normalizes Rust strings to Error objects. Preserve unknown
 * failures while translating the stable codes our plugin host owns. */
export function translatePluginHostFailure(cause: unknown, translate: (key: string) => string): unknown {
  const fields = cause && typeof cause === "object" ? cause as { code?: unknown; message?: unknown } : undefined;
  const code = typeof fields?.code === "string" ? fields.code
    : typeof fields?.message === "string" ? fields.message : typeof cause === "string" ? cause : "";
  const key = code.startsWith("toolchain.native.") ? "native.selectedToolchainUnavailable"
    : code === "plugin.packageSignature.invalid" ? "native.thePluginPackageSignatureIsInvalid" : undefined;
  return key ? Object.assign(new Error(translate(key)), { code, cause }) : cause;
}
