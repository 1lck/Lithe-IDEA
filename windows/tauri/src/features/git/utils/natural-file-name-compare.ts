// Natural file-name comparison aligned with intellij-community, which orders the
// commit dialog's file tree: TreeModelBuilder ranks same-level nodes by sort weight
// (directory nodes before file nodes) and compares names through FileNameComparator,
// i.e. NaturalComparator.naturalCompare(ignoreCase=true, likeFileNames=true).
// Numbers compare by value ("file2" < "file10"), '-' and '_' rank alike (IDEA-80435),
// and case-insensitive ties fall back to one case-sensitive pass.

const SPACE = 0x20;
const ZERO = 0x30;
const DASH = 0x2d;
const UNDERSCORE = 0x5f;

const isDigit = (code: number) => code >= ZERO && code <= ZERO + 9;

const sign = (value: number) => (value < 0 ? -1 : value > 0 ? 1 : 0);

const toUpperCode = (code: number) => {
  const upper = String.fromCharCode(code).toUpperCase();
  return upper.length === 1 ? upper.charCodeAt(0) : code;
};

const toLowerCode = (code: number) => {
  const lower = String.fromCharCode(code).toLowerCase();
  return lower.length === 1 ? lower.charCodeAt(0) : code;
};

// Mirrors NaturalComparator.compareChars: the space-vs-"between ' ' and '0'" fix keeps
// the comparator transitive, then Strings.compare folds case like equalsIgnoreCase.
function compareChars(left: number, right: number, ignoreCase: boolean): number {
  if (left === SPACE && right > SPACE && right < ZERO) return 1;
  if (right === SPACE && left > SPACE && left < ZERO) return -1;

  const direct = sign(left - right);
  if (direct === 0 || !ignoreCase) return direct;

  const upperDiff = sign(toUpperCode(left) - toUpperCode(right));
  if (upperDiff === 0) return 0;
  // Uppercase conversion alone misorders some Georgian letters; compare the
  // lowercased uppercase forms as the final tie-breaker.
  return sign(toLowerCode(toUpperCode(left)) - toLowerCode(toUpperCode(right)));
}

const skipChar = (text: string, from: number, length: number, code: number) => {
  let index = from;
  while (index < length && text.charCodeAt(index) === code) index += 1;
  return index;
};

const skipDigits = (text: string, from: number, length: number) => {
  let index = from;
  while (index < length && isDigit(text.charCodeAt(index))) index += 1;
  return index;
};

const compareCharRange = (
  left: string,
  right: string,
  fromLeft: number,
  fromRight: number,
  endLeft: number,
) => {
  for (let i = fromLeft, j = fromRight; i < endLeft; i += 1, j += 1) {
    const diff = sign(left.charCodeAt(i) - right.charCodeAt(j));
    if (diff !== 0) return diff;
  }
  return 0;
};

function naturalCompare(
  left: string,
  right: string,
  length1: number,
  length2: number,
  ignoreCase: boolean,
): number {
  let i = 0;
  let j = 0;
  for (; i < length1 && j < length2; i += 1, j += 1) {
    const ch1 = left.charCodeAt(i);
    const ch2 = right.charCodeAt(j);

    if ((isDigit(ch1) || ch1 === SPACE) && (isDigit(ch2) || ch2 === SPACE)) {
      const start1 = skipChar(left, skipChar(left, i, length1, SPACE), length1, ZERO);
      const start2 = skipChar(right, skipChar(right, j, length2, SPACE), length2, ZERO);
      const end1 = skipDigits(left, start1, length1);
      const end2 = skipDigits(right, start2, length2);

      // Numbers with more digits are always greater than shorter numbers.
      const lengthDiff = end1 - start1 - (end2 - start2);
      if (lengthDiff !== 0) return sign(lengthDiff);

      const numberDiff = compareCharRange(left, right, start1, start2, end1);
      if (numberDiff !== 0) return numberDiff;

      // Compare number length including leading spaces and zeroes.
      const fullLengthDiff = end1 - i - (end2 - j);
      if (fullLengthDiff !== 0) return sign(fullLengthDiff);

      // The numbers are the same; compare leading spaces and zeroes.
      const leadingDiff = compareCharRange(left, right, i, j, start1);
      if (leadingDiff !== 0) return leadingDiff;

      i = end1 - 1;
      j = end2 - 1;
    } else if (ch1 !== ch2) {
      // likeFileNames: treat '-' as '_' unless the other side already is one (IDEA-80435).
      let diff: number;
      if (ch1 === DASH && ch2 !== UNDERSCORE) {
        diff = compareChars(UNDERSCORE, ch2, ignoreCase);
      } else if (ch2 === DASH && ch1 !== UNDERSCORE) {
        diff = compareChars(ch1, UNDERSCORE, ignoreCase);
      } else {
        diff = compareChars(ch1, ch2, ignoreCase);
      }
      if (diff !== 0) return diff;
    }
  }

  if (i < length1) return 1;
  if (j < length2) return -1;
  if (length1 !== length2) return sign(length1 - length2);

  // Case-insensitive strings are equal; compare once more case-sensitively.
  return ignoreCase ? naturalCompare(left, right, length1, length2, false) : 0;
}

export function compareGitFileNames(left: string, right: string): number {
  return naturalCompare(left, right, left.length, right.length, true);
}
