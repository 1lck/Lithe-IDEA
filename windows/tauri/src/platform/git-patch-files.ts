import { invoke } from "./tauri-core";
import { GIT_PATCH_MAX_BYTES } from "@/config/git-limits";

export async function readGitPatchFile(path: string): Promise<string> {
  const response = await invoke<{ bytes: ArrayBuffer | number[]; truncated: boolean }>(
    "read_local_file_bounded",
    {
      path,
      maxBytes: GIT_PATCH_MAX_BYTES,
    },
  );
  const bytes =
    response.bytes instanceof ArrayBuffer
      ? new Uint8Array(response.bytes)
      : Uint8Array.from(response.bytes);
  if (response.truncated || bytes.byteLength > GIT_PATCH_MAX_BYTES)
    throw new Error("git.patch.fileTooLarge");
  try {
    // Preserve the actual text, including BOM and CRLF, for Core's patch check.
    return new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(bytes);
  } catch {
    throw new Error("git.patch.invalidUtf8");
  }
}

export function writeGitPatchFile(path: string, patch: string): Promise<void> {
  return invoke("write_patch_file", { path, contents: patch });
}
