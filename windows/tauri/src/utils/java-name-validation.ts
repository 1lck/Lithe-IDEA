// Lexical validation for user-created names, not Java symbol or project discovery.
const KEYWORDS = new Set(
  "abstract assert boolean break byte case catch char class const continue default do double else enum extends final finally float for goto if implements import instanceof int interface long native new package private protected public return short static strictfp super switch synchronized this throw throws transient try void volatile while true false null _ var yield record sealed permits".split(
    " ",
  ),
);

export function isJavaIdentifier(value: string): boolean {
  return (
    value.length > 0 &&
    value.length <= 150 &&
    !KEYWORDS.has(value) &&
    !/^(?:con|prn|aux|nul|com[1-9]|lpt[1-9])$/i.test(value) &&
    /^[$_\p{L}\p{Nl}\p{Sc}\p{Pc}][$_\p{L}\p{Nl}\p{Sc}\p{Pc}\p{Mn}\p{Mc}\p{Nd}]*$/u.test(value)
  );
}
export function isJavaPackageName(value: string, allowEmpty = false): boolean {
  return (
    (allowEmpty && value === "") ||
    (value.length <= 240 && value.split(".").every(isJavaIdentifier))
  );
}
