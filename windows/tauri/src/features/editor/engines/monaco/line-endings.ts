/**
 * Monaco keeps a separate EOL setting. If a model is created or later updated
 * with LF while the buffer still contains CRLF, `\r` stays on the line and
 * mouse hit-testing cannot land after the last visible character.
 */
export function documentUsesCrlf(content: string): boolean {
  return content.includes("\r\n");
}

export function toMonacoModelValue(content: string): string {
  if (!content.includes("\r")) return content;
  return content.replace(/\r\n/g, "\n").replace(/\r/g, "\n");
}

export function monacoModelMatchesContent(modelValue: string, content: string): boolean {
  return toMonacoModelValue(modelValue) === toMonacoModelValue(content);
}
