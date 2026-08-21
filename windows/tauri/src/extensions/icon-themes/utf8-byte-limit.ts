export function isUtf8WithinByteLimit(value: string, maxBytes: number): boolean {
  if (!Number.isSafeInteger(maxBytes) || maxBytes < 0) {
    throw new RangeError("UTF-8 byte limit must be a non-negative safe integer");
  }

  let byteLength = 0;
  for (let index = 0; index < value.length; index += 1) {
    const codeUnit = value.charCodeAt(index);
    let encodedLength: number;
    if (codeUnit <= 0x7f) {
      encodedLength = 1;
    } else if (codeUnit <= 0x7ff) {
      encodedLength = 2;
    } else if (
      codeUnit >= 0xd800 &&
      codeUnit <= 0xdbff &&
      index + 1 < value.length &&
      value.charCodeAt(index + 1) >= 0xdc00 &&
      value.charCodeAt(index + 1) <= 0xdfff
    ) {
      encodedLength = 4;
      index += 1;
    } else {
      // TextEncoder replaces unpaired surrogates with the three-byte replacement character.
      encodedLength = 3;
    }

    if (byteLength > maxBytes - encodedLength) return false;
    byteLength += encodedLength;
  }
  return true;
}
