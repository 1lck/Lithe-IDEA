//! Bounded, stateless matching of host-localized action catalog snapshots.

use crate::protocol::{CoreError, ErrorCode};
use serde::Deserialize;
use unicode_normalization::UnicodeNormalization;

const MAX_CANDIDATES: usize = 4096;
const MAX_TEXT_BYTES: usize = 2 * 1024 * 1024;
const MAX_QUERY_BYTES: usize = 4096;
const MAX_FIELDS: usize = 16;

/// Caller-owned action text; position in the request is its opaque identity.
#[derive(Deserialize)]
pub(crate) struct Candidate {
    /// Original and localized presentation fields, in their display order.
    texts: Vec<String>,
}

/// One small action catalog; matching never scans workspace files or retains data.
#[derive(Deserialize)]
pub(crate) struct Request {
    query: String,
    candidates: Vec<Candidate>,
}

/// Returns matching candidate offsets in input order, preserving native actions.
pub(crate) fn search(request: Request) -> Result<Vec<usize>, CoreError> {
    let bytes = request.candidates.iter().try_fold(0usize, |total, item| {
        item.texts
            .iter()
            .try_fold(total, |sum, text| sum.checked_add(text.len()))
    });
    if request.query.len() > MAX_QUERY_BYTES
        || request.candidates.len() > MAX_CANDIDATES
        || request
            .candidates
            .iter()
            .any(|candidate| candidate.texts.len() > MAX_FIELDS)
        || bytes.is_none_or(|count| count > MAX_TEXT_BYTES)
    {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Action search exceeds its input budget",
        ));
    }
    let query: Vec<char> = request
        .query
        .to_lowercase()
        .nfc()
        .filter(|c| !c.is_whitespace())
        .collect();
    Ok(request
        .candidates
        .iter()
        .enumerate()
        .filter_map(|(index, candidate)| {
            let mut cursor = 0;
            // Lowercase whole strings, retaining contextual Unicode case mapping.
            // Separators do not affect the whitespace-free subsequence query.
            for text in &candidate.texts {
                for character in text.to_lowercase().nfc() {
                    if query.get(cursor) == Some(&character) {
                        cursor += 1;
                    }
                    if cursor == query.len() {
                        break;
                    }
                }
                if cursor == query.len() {
                    break;
                }
            }
            (cursor == query.len()).then_some(index)
        })
        .collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fixture_matches_localized_and_original_text_without_reordering() {
        let fixture: serde_json::Value = serde_json::from_str(include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../shared/fixtures/search/actions-v1.json"
        )))
        .unwrap();
        for case in fixture["cases"].as_array().unwrap() {
            let request = serde_json::from_value(case.clone()).unwrap();
            assert_eq!(
                serde_json::to_value(search(request).unwrap()).unwrap(),
                case["indices"],
                "{case}"
            );
        }
    }

    #[test]
    fn oversized_inputs_are_rejected() {
        let request = Request {
            query: "x".repeat(MAX_QUERY_BYTES + 1),
            candidates: vec![],
        };
        assert!(matches!(
            search(request).unwrap_err().code,
            ErrorCode::InvalidRequest
        ));
        let request = Request {
            query: "x".into(),
            candidates: (0..=MAX_CANDIDATES)
                .map(|_| Candidate { texts: vec![] })
                .collect(),
        };
        assert!(search(request).is_err());
        let request = Request {
            query: "x".into(),
            candidates: vec![Candidate {
                texts: vec!["x".repeat(MAX_TEXT_BYTES + 1)],
            }],
        };
        assert!(search(request).is_err());
    }
}
