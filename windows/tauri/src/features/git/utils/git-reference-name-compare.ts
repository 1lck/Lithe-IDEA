// Display-order comparison for reference names (branch filter lists and reference
// groups). Graph head ordering is Core's (`git.graphProjection`); this is the same
// IntelliJ `NaturalComparator` order for UI sorting.

/** The natural-name ordering used by IntelliJ's Git reference comparator. */
export function naturalCompare(left: string, right: string, ignoreCase = true): number {
  const a = Array.from({ length: left.length }, (_, index) => left.charCodeAt(index));
  const b = Array.from({ length: right.length }, (_, index) => right.charCodeAt(index));
  let i = 0;
  let j = 0;
  const isDigit = (value: number) => value >= 48 && value <= 57;
  const simpleCaseUnit = (value: number, uppercase: boolean) => {
    if (value >= 0x61 && value <= 0x7a) return uppercase ? value - 0x20 : value;
    if (value >= 0x41 && value <= 0x5a) return uppercase ? value : value + 0x20;
    const mapped = String.fromCharCode(value)[uppercase ? "toUpperCase" : "toLowerCase"]();
    return mapped.length === 1 ? mapped.charCodeAt(0) : value;
  };

  while (i < a.length && j < b.length) {
    const first = a[i];
    const second = b[j];
    if ((isDigit(first) || first === 32) && (isDigit(second) || second === 32)) {
      let firstStart = i;
      while (firstStart < a.length && a[firstStart] === 32) firstStart += 1;
      while (firstStart < a.length && a[firstStart] === 48) firstStart += 1;
      let firstEnd = firstStart;
      while (firstEnd < a.length && isDigit(a[firstEnd])) firstEnd += 1;

      let secondStart = j;
      while (secondStart < b.length && b[secondStart] === 32) secondStart += 1;
      while (secondStart < b.length && b[secondStart] === 48) secondStart += 1;
      let secondEnd = secondStart;
      while (secondEnd < b.length && isDigit(b[secondEnd])) secondEnd += 1;

      const firstLength = firstEnd - firstStart;
      const secondLength = secondEnd - secondStart;
      if (firstLength !== secondLength) return firstLength - secondLength;
      for (let offset = 0; offset < firstLength; offset += 1) {
        const difference = a[firstStart + offset] - b[secondStart + offset];
        if (difference !== 0) return difference;
      }
      const lengthDifference = firstEnd - i - (secondEnd - j);
      if (lengthDifference !== 0) return lengthDifference;
      for (let offset = 0; offset < firstStart - i; offset += 1) {
        const difference = a[i + offset] - b[j + offset];
        if (difference !== 0) return difference;
      }
      i = firstEnd;
      j = secondEnd;
      continue;
    }

    if (first === 32 && second > 32 && second < 48) return 1;
    if (second === 32 && first > 32 && first < 48) return -1;
    let difference = first - second;
    if (difference !== 0 && ignoreCase) {
      const upperDifference = simpleCaseUnit(first, true) - simpleCaseUnit(second, true);
      difference =
        upperDifference !== 0
          ? upperDifference
          : simpleCaseUnit(first, false) - simpleCaseUnit(second, false);
    }
    if (difference !== 0) return difference;
    i += 1;
    j += 1;
  }
  if (i < a.length) return 1;
  if (j < b.length) return -1;
  if (a.length !== b.length) return a.length - b.length;
  return ignoreCase ? naturalCompare(left, right, false) : 0;
}
