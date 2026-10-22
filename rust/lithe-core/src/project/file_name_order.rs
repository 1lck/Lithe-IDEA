//! Sibling ordering for workspace tree rows, aligned with IntelliJ IDEA's Project view.
//!
//! IDEA ranks same-level nodes with `AlphaComparator`, which compares names through
//! `FileNameComparator`, i.e. `NaturalComparator.naturalCompare(ignoreCase = true,
//! likeFileNames = true)`. Digit runs compare by value (`v0.1.4` before `v0.1.12`),
//! letter case is ignored until every other difference ties, and `-` ranks next to
//! `_` (IDEA-80435).
//!
//! Adapted from intellij-community `NaturalComparator` and `FileNameComparator` at
//! d8c6714c7a3c110c56994d6b0f10814f902100e7 (Apache-2.0, Copyright JetBrains s.r.o.
//! and contributors). The macOS Swift port (`NaturalNameOrder`) and the Windows
//! TypeScript port follow the same source and share
//! `shared/fixtures/workspace/file-name-order-v1.json`.

use std::cmp::Ordering;

const SPACE: u16 = 0x20;
const ZERO: u16 = 0x30;
const DASH: u16 = 0x2D;
const UNDERSCORE: u16 = 0x5F;

/// A name pre-converted to UTF-16 code units so that sorting a large directory
/// converts each name once instead of once per comparison.
///
/// Java compares `char` values, so UTF-16 units keep the upstream order for
/// supplementary characters as well.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct FileNameKey(Vec<u16>);

impl FileNameKey {
    pub(crate) fn new(name: &str) -> Self {
        Self(name.encode_utf16().collect())
    }
}

impl Ord for FileNameKey {
    fn cmp(&self, other: &Self) -> Ordering {
        compare_utf16(&self.0, &other.0)
    }
}

impl PartialOrd for FileNameKey {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

/// Compares two file names in IDEA's Project view order.
#[cfg(test)]
pub(crate) fn compare_file_names(left: &str, right: &str) -> Ordering {
    FileNameKey::new(left).cmp(&FileNameKey::new(right))
}

fn compare_utf16(left: &[u16], right: &[u16]) -> Ordering {
    natural_compare(left, right, true)
}

fn natural_compare(left: &[u16], right: &[u16], ignore_case: bool) -> Ordering {
    let (mut i, mut j) = (0, 0);
    while i < left.len() && j < right.len() {
        let (first, second) = (left[i], right[j]);
        if (is_digit(first) || first == SPACE) && (is_digit(second) || second == SPACE) {
            let start_left = skip_unit(left, skip_unit(left, i, SPACE), ZERO);
            let start_right = skip_unit(right, skip_unit(right, j, SPACE), ZERO);
            let end_left = skip_digits(left, start_left);
            let end_right = skip_digits(right, start_right);

            // A number with more significant digits is always greater.
            let digits = (end_left - start_left).cmp(&(end_right - start_right));
            if digits != Ordering::Equal {
                return digits;
            }
            let value = left[start_left..end_left].cmp(&right[start_right..end_right]);
            if value != Ordering::Equal {
                return value;
            }
            // Equal values: the run with fewer leading spaces and zeroes comes first,
            // then the leading characters themselves decide.
            let full_length = (end_left - i).cmp(&(end_right - j));
            if full_length != Ordering::Equal {
                return full_length;
            }
            let leading = left[i..start_left].cmp(&right[j..start_right]);
            if leading != Ordering::Equal {
                return leading;
            }
            // Both runs end at the same offset; the loop increment below steps past them.
            i = end_left - 1;
            j = end_right - 1;
        } else if first != second {
            let order = compare_name_units(first, second, ignore_case);
            if order != Ordering::Equal {
                return order;
            }
        }
        i += 1;
        j += 1;
    }
    // One side can still have characters left when the other ended inside a number.
    if i < left.len() {
        return Ordering::Greater;
    }
    if j < right.len() {
        return Ordering::Less;
    }
    if left.len() != right.len() {
        return left.len().cmp(&right.len());
    }
    // Names that tie while ignoring case are ordered by one case-sensitive pass.
    if ignore_case {
        natural_compare(left, right, false)
    } else {
        Ordering::Equal
    }
}

/// The "likeFileNames" character comparison: a `-` ranks like `_` unless the other
/// character already is `_`, so `foo-bar` and `foo_bar` stay together (IDEA-80435).
fn compare_name_units(first: u16, second: u16, ignore_case: bool) -> Ordering {
    if first == DASH && second != UNDERSCORE {
        compare_units(UNDERSCORE, second, ignore_case)
    } else if second == DASH && first != UNDERSCORE {
        compare_units(first, UNDERSCORE, ignore_case)
    } else {
        compare_units(first, second, ignore_case)
    }
}

fn compare_units(first: u16, second: u16, ignore_case: bool) -> Ordering {
    // Upstream transitivity fix: without it a space and characters between ' ' and
    // '0' (such as '#') form a cycle with digits.
    if first == SPACE && second > SPACE && second < ZERO {
        return Ordering::Greater;
    }
    if second == SPACE && first > SPACE && first < ZERO {
        return Ordering::Less;
    }
    let direct = first.cmp(&second);
    if direct == Ordering::Equal || !ignore_case {
        return direct;
    }
    // Same folding as `String.equalsIgnoreCase`: compare uppercased units first and, when
    // those differ, their lowercase forms, because uppercasing alone misorders
    // some Georgian letters.
    let (upper_first, upper_second) = (map_case(first, true), map_case(second, true));
    if upper_first == upper_second {
        return Ordering::Equal;
    }
    map_case(upper_first, false).cmp(&map_case(upper_second, false))
}

/// Java `Character.toUpperCase/toLowerCase(char)`: the simple one-to-one mapping,
/// never a multi-character expansion and never leaving the BMP.
fn map_case(unit: u16, uppercase: bool) -> u16 {
    // U+0130 has a two-character full lowercase mapping, but Java maps it to 'i'.
    if !uppercase && unit == 0x0130 {
        return 0x0069;
    }
    let Some(character) = char::from_u32(u32::from(unit)) else {
        return unit;
    };
    let mut mapped = if uppercase {
        character.to_uppercase().collect::<Vec<_>>()
    } else {
        character.to_lowercase().collect::<Vec<_>>()
    };
    match (mapped.pop(), mapped.is_empty()) {
        (Some(single), true) => u16::try_from(u32::from(single)).unwrap_or(unit),
        _ => unit,
    }
}

fn is_digit(unit: u16) -> bool {
    (ZERO..=ZERO + 9).contains(&unit)
}

fn skip_unit(text: &[u16], from: usize, unit: u16) -> usize {
    from + text[from..]
        .iter()
        .take_while(|&&value| value == unit)
        .count()
}

fn skip_digits(text: &[u16], from: usize) -> usize {
    from + text[from..]
        .iter()
        .take_while(|&&value| is_digit(value))
        .count()
}
