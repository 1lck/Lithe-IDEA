//! Fuzzy subsequence matching for the app's search boxes.
//!
//! The command palette and the file filter rank by it directly. The model
//! picker uses it as its last tier, below whole-word and substring matches, so
//! a scattered-letter hit can surface a similar name without outranking a row
//! that contains the query outright.

/// Score `query` against `target`, or `None` when the query's characters do
/// not all appear in `target` in order.
///
/// Higher is better. Matches nearer the start of the target score higher, so
/// typing a prefix surfaces the obvious candidate first.
pub fn fuzzy_score(query: &str, target: &str) -> Option<usize> {
    if query.is_empty() {
        return Some(0);
    }
    let target_len = target.len();
    let mut score: usize = 0;
    let mut target_chars = target.char_indices();
    // Callers usually lowercase both sides already; doing it here as well keeps
    // direct calls correct.
    for query_char in query.to_lowercase().chars() {
        loop {
            match target_chars.next() {
                Some((pos, target_char)) => {
                    if target_char.to_ascii_lowercase() == query_char {
                        score += target_len.saturating_sub(pos);
                        break;
                    }
                }
                None => return None,
            }
        }
    }
    Some(score)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_exact_match_scores() {
        assert!(fuzzy_score("commit", "commit").is_some());
    }

    #[test]
    fn matching_is_case_insensitive() {
        assert!(fuzzy_score("COMMIT", "commit").is_some());
        assert!(fuzzy_score("commit", "COMMIT").is_some());
    }

    #[test]
    fn every_query_character_must_appear_in_order() {
        assert!(fuzzy_score("abc", "axbxc").is_some());
        assert!(fuzzy_score("cba", "axbxc").is_none());
        assert!(fuzzy_score("xyz", "commit").is_none());
    }

    #[test]
    fn an_empty_query_matches_anything_with_no_preference() {
        assert_eq!(fuzzy_score("", "anything"), Some(0));
        assert_eq!(fuzzy_score("", ""), Some(0));
    }

    #[test]
    fn an_empty_target_matches_only_an_empty_query() {
        assert_eq!(fuzzy_score("a", ""), None);
    }

    #[test]
    fn an_earlier_match_scores_higher() {
        let early = fuzzy_score("g", "gemini").unwrap();
        let late = fuzzy_score("g", "openai/g").unwrap();
        assert!(early > late);
    }

    #[test]
    fn a_query_longer_than_its_target_cannot_match() {
        assert_eq!(fuzzy_score("commit-message", "commit"), None);
    }

    #[test]
    fn repeated_characters_consume_distinct_positions() {
        assert!(fuzzy_score("aa", "aa").is_some());
        assert!(fuzzy_score("aa", "a").is_none());
    }

    #[test]
    fn digits_punctuation_and_unicode_all_match() {
        assert!(fuzzy_score("gpt5", "gpt-5.6-luna").is_some());
        assert!(fuzzy_score("a/b", "a/b/c").is_some());
        assert!(fuzzy_score("é", "café").is_some());
    }

    #[test]
    fn a_multibyte_target_does_not_panic_on_a_missing_character() {
        assert_eq!(fuzzy_score("z", "日本語"), None);
    }
}
