//! Word-fragment matching for Search Everywhere names, ranking and UTF-16 highlighting.

use crate::protocol::SearchNameRange;

/// One match owns both its ranking and the fragments painted by native clients.
pub(crate) struct NameMatch {
    pub(crate) degree: i32,
    pub(crate) ranges: Vec<SearchNameRange>,
}

/// Implements case-insensitive contiguous and camel/word-hump matching.
/// Gaps resume at word starts, not at arbitrary letters inside a word.
pub(crate) fn match_name(pattern: &str, name: &str) -> Option<NameMatch> {
    match_fragments(pattern, name).or_else(|| {
        if pattern.is_ascii() && name.is_ascii() {
            return None;
        }
        let needle = pattern.to_lowercase();
        if needle.is_empty() {
            return None;
        }
        // Preserve whole-string lowercase substring semantics, including expansions
        // such as U+0130 and contextual Greek sigma. Folded byte offsets are not
        // original UTF-16 offsets; highlight every original character they overlap.
        let folded = name.to_lowercase();
        let start = folded.find(&needle)?;
        let end = start + needle.len();
        let (mut byte_offset, mut utf16_offset) = (0, 0);
        let mut range = SearchNameRange {
            start: 0,
            length: 0,
        };
        for c in name.chars() {
            let next = byte_offset + c.to_lowercase().map(char::len_utf8).sum::<usize>();
            if byte_offset < end && next > start {
                if range.length == 0 {
                    range.start = utf16_offset;
                }
                range.length += c.len_utf16();
            }
            byte_offset = next;
            utf16_offset += c.len_utf16();
        }
        let stem = name.rsplit_once('.').map_or(name, |(stem, _)| stem);
        let form = if folded == needle || stem.to_lowercase() == needle {
            40000
        } else if start == 0 {
            30000
        } else {
            20000
        };
        Some(NameMatch {
            degree: form,
            ranges: vec![range],
        })
    })
}

fn match_fragments(pattern: &str, name: &str) -> Option<NameMatch> {
    let needle: Vec<char> = pattern.chars().collect();
    let text: Vec<char> = name.chars().collect();
    let equal = |a: char, b: char| a.to_lowercase().eq(b.to_lowercase());
    if needle.is_empty() || text.is_empty() || needle.len() > text.len() {
        return None;
    }
    // ponytail: cap the DP at 256 query characters; longer queries use literal matching
    // below rather than allocating an unbounded query-by-name matrix.
    if needle.len() > 256 {
        let start = text
            .windows(needle.len())
            .position(|w| w.iter().zip(&needle).all(|(a, b)| equal(*a, *b)))?;
        return Some(NameMatch {
            degree: 10000,
            ranges: vec![SearchNameRange {
                start: text[..start].iter().map(|c| c.len_utf16()).sum(),
                length: text[start..start + needle.len()]
                    .iter()
                    .map(|c| c.len_utf16())
                    .sum(),
            }],
        });
    }
    // Most filenames cannot contain even the ordered letters. Reject those before
    // allocating the fragment-ranking matrix for a workspace-sized candidate set.
    let mut matched = 0;
    for c in &text {
        if equal(needle[matched], *c) {
            matched += 1;
            if matched == needle.len() {
                break;
            }
        }
    }
    if matched != needle.len() {
        return None;
    }
    let boundary = |i: usize| {
        i == 0
            || !text[i - 1].is_alphanumeric()
            || (text[i].is_uppercase()
                && (!text[i - 1].is_uppercase()
                    || text.get(i + 1).is_some_and(|c| c.is_lowercase())))
            || (text[i].is_numeric() && !text[i - 1].is_numeric())
    };
    let n = text.len();
    let mut previous = vec![i32::MIN; n];
    let mut links = vec![vec![None; n]; needle.len()];
    for (i, c) in text.iter().enumerate() {
        if equal(needle[0], *c) {
            previous[i] = 100 - i as i32 / 16 + if boundary(i) { 20 } else { 0 };
        }
    }
    for row in 1..needle.len() {
        let mut next = vec![i32::MIN; n];
        let mut best = None;
        for col in 0..n {
            if col > 0
                && previous[col - 1] != i32::MIN
                && best.is_none_or(|b: usize| previous[col - 1] > previous[b])
            {
                best = Some(col - 1);
            }
            if !equal(needle[row], text[col]) {
                continue;
            }
            if col > 0 && previous[col - 1] != i32::MIN {
                next[col] = previous[col - 1] + 100;
                links[row][col] = Some(col - 1);
            }
            if boundary(col) {
                if let Some(b) = best {
                    let score = previous[b] + 20;
                    if score > next[col] {
                        next[col] = score;
                        links[row][col] = Some(b);
                    }
                }
            }
        }
        previous = next;
    }
    let (mut col, score) = previous
        .iter()
        .enumerate()
        .max_by_key(|(i, score)| (**score, std::cmp::Reverse(*i)))?;
    if *score == i32::MIN {
        return None;
    }
    let mut positions = vec![col];
    for row in (1..needle.len()).rev() {
        col = links[row][col]?;
        positions.push(col);
    }
    positions.reverse();
    let contiguous = positions.windows(2).all(|w| w[1] == w[0] + 1);
    let stem = name.rsplit_once('.').map_or(name, |(stem, _)| stem);
    let form = if name.to_lowercase() == pattern.to_lowercase()
        || stem.to_lowercase() == pattern.to_lowercase()
    {
        40000
    } else if contiguous && positions[0] == 0 {
        30000
    } else if contiguous {
        20000
    } else {
        10000
    };
    let mut offsets = vec![0];
    for c in &text {
        offsets.push(offsets.last().copied().unwrap_or(0) + c.len_utf16());
    }
    let mut ranges: Vec<SearchNameRange> = Vec::new();
    for p in positions {
        let start = offsets[p];
        let length = offsets[p + 1] - start;
        if let Some(last) = ranges.last_mut().filter(|r| r.start + r.length == start) {
            last.length += length;
        } else {
            ranges.push(SearchNameRange { start, length });
        }
    }
    Some(NameMatch {
        degree: form + *score,
        ranges,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unicode_contiguous_matches_map_back_to_original_utf16() {
        let fixture: serde_json::Value = serde_json::from_str(include_str!(
            "../../../../shared/fixtures/search/unicode-contiguous.json"
        ))
        .unwrap();
        for case in fixture["cases"].as_array().unwrap() {
            let name = case["path"].as_str().unwrap().rsplit('/').next().unwrap();
            let hit = match_name(case["query"].as_str().unwrap(), name)
                .unwrap_or_else(|| panic!("missing Unicode match: {case}"));
            assert_eq!(
                serde_json::to_value(hit.ranges).unwrap(),
                case["ranges"],
                "{case}"
            );
        }
        let pattern = format!("{}i", "a".repeat(256));
        let name = format!("{}\u{130}.txt", "a".repeat(256));
        assert_eq!(match_name(&pattern, &name).unwrap().ranges[0].length, 257);
        assert!(match_name("", "\u{130}.txt").is_none());
        assert!(match_name("unrelated", "\u{130}.txt").is_none());
    }

    #[test]
    fn name_matches_the_reported_idea_word_fragments() {
        for name in [
            "Name.swift",
            "NamedColorUtil.java",
            "NativeMenu",
            "navigation-menu.tsx",
            "native-menu-accelerators.ts",
        ] {
            assert!(match_name("name", name).is_some(), "{name}");
        }
        assert!(match_name("name", "normalizer.swift").is_none());
        let hit = match_name("name", "NativeMenu").unwrap();
        assert_eq!(
            hit.ranges
                .iter()
                .map(|r| (r.start, r.length))
                .collect::<Vec<_>>(),
            [(0, 2), (6, 2)]
        );
        assert!(match_name("name", "Name.swift").unwrap().degree > hit.degree);
        assert_eq!(
            match_name("name", "😀Name.swift").unwrap().ranges[0].start,
            2
        );
        assert!(match_name("NME", "NativeMenuEditor").is_some());
    }
}
