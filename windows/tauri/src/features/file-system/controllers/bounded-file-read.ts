import { invoke } from "@/platform/tauri-core";

interface BoundedLocalFileRead {
  bytes: ArrayBuffer | number[];
  truncated: boolean;
}

const strictUtf8Decoder = new TextDecoder("utf-8", { fatal: true });

export async function readFileWithinByteLimit(
  path: string,
  maxBytes: number,
): Promise<string | null> {
  if (!Number.isSafeInteger(maxBytes) || maxBytes < 0) {
    throw new RangeError("File read byte limit must be a non-negative safe integer");
  }

  const response = await invoke<BoundedLocalFileRead>("read_local_file_bounded", {
    path,
    maxBytes,
  });
  const bytes =
    response.bytes instanceof ArrayBuffer
      ? new Uint8Array(response.bytes)
      : Uint8Array.from(response.bytes);
  if (response.truncated || bytes.byteLength > maxBytes) return null;

  try {
    return strictUtf8Decoder.decode(bytes);
  } catch {
    return null;
  }
}
