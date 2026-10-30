//! Bounded keyset pages over the existing search indexes, without retaining sessions.

use super::files::{
    compare_search_matches, search_everywhere, search_everywhere_with_page, SearchRequest,
};
use crate::protocol::{CoreError, ErrorCode, SearchMatch, SearchResponse};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::cmp::Ordering;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
/// Optional paging fields leave the existing synchronous request contract unchanged.
pub(crate) struct SearchPageRequest {
    #[serde(flatten)]
    search: SearchRequest,
    page_size: Option<usize>,
    cursor: Option<String>,
    result_kinds: Option<Vec<String>>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct PageResponse {
    #[serde(flatten)]
    results: SearchResponse,
    next_cursor: Option<String>,
}

#[derive(Clone, Deserialize, Serialize)]
// A source has one hit per path/line/symbol; long preview text is not cursor state.
struct Position {
    degree: Option<i32>,
    path: String,
    line: Option<usize>,
    symbol: Option<String>,
}

impl Position {
    fn of(item: &SearchMatch) -> Self {
        Self {
            degree: item.matching_degree,
            path: item.path.clone(),
            line: item.line,
            symbol: item.symbol_name.clone(),
        }
    }
    fn compare(&self, other: &SearchMatch) -> Ordering {
        other
            .matching_degree
            .cmp(&self.degree)
            .then_with(|| self.path.cmp(&other.path))
            .then_with(|| self.line.cmp(&other.line))
            .then_with(|| self.symbol.cmp(&other.symbol_name))
    }
}

#[derive(Deserialize, Serialize)]
/// The query fingerprint prevents a continuation from crossing roots, hosts or options.
pub(crate) struct SearchPage {
    fingerprint: String,
    after: [Option<Position>; 4],
    exhausted: [bool; 4],
}

fn bucket(kind: &str) -> usize {
    match kind {
        "file" => 0,
        "type" => 1,
        "symbol" => 2,
        _ => 3,
    }
}

impl SearchPage {
    pub(crate) fn exhausted(&self, kind: &str) -> bool {
        self.exhausted[bucket(kind)]
    }

    pub(crate) fn accepts(&self, item: &SearchMatch) -> bool {
        let index = bucket(&item.kind);
        !self.exhausted[index]
            && self.after[index]
                .as_ref()
                .is_none_or(|after| after.compare(item) == Ordering::Less)
    }

    pub(crate) fn accepts_path(&self, path: &str) -> bool {
        self.after[3]
            .as_ref()
            .is_none_or(|after| path >= after.path.as_str())
    }

    pub(crate) fn push(&self, items: &mut Vec<SearchMatch>, item: SearchMatch, cap: usize) {
        if cap == 0 || !self.accepts(&item) {
            return;
        }
        let index = items
            .binary_search_by(|candidate| compare_search_matches(candidate, &item))
            .unwrap_or_else(|index| index);
        // ponytail: sorted insertion moves at most 201 items per candidate. Use a
        // bounded heap if larger page sizes become a measured requirement.
        if index <= cap {
            items.insert(index, item);
            items.truncate(cap + 1);
        }
    }

    pub(crate) fn finish(&mut self, kind: &str, items: &mut Vec<SearchMatch>, cap: usize) {
        let index = bucket(kind);
        self.exhausted[index] = items.len() <= cap;
        items.truncate(cap);
        if let Some(last) = items.last() {
            self.after[index] = Some(Position::of(last));
        }
    }
}

/// Executes legacy requests unchanged, or bounded pages with a query-bound continuation.
pub(crate) fn search_page(request: SearchPageRequest) -> Result<serde_json::Value, CoreError> {
    let Some(size) = request.page_size else {
        return search_everywhere(request.search)
            .map(|response| serde_json::to_value(response).unwrap());
    };
    if !(1..=200).contains(&size) {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Search page size must be between 1 and 200",
        ));
    }
    let identity =
        crate::remote::workspace::identity_key(std::path::Path::new(&request.search.root));
    let fingerprint = format!(
        "{:x}",
        Sha256::digest(
            serde_json::to_vec(&(1, &request.search, &request.result_kinds, size, identity))
                .unwrap()
        )
    );
    let mut page = if let Some(cursor) = request.cursor {
        if cursor.len() > 65536 {
            return Err(CoreError::new(
                ErrorCode::InvalidRequest,
                "Search cursor is too large",
            ));
        }
        let page: SearchPage = serde_json::from_str(&cursor)
            .map_err(|_| CoreError::new(ErrorCode::InvalidRequest, "Invalid search cursor"))?;
        if page.fingerprint != fingerprint {
            return Err(CoreError::new(
                ErrorCode::InvalidRequest,
                "Search cursor belongs to another query",
            ));
        }
        page
    } else {
        SearchPage {
            fingerprint,
            after: [None, None, None, None],
            exhausted: [false; 4],
        }
    };
    if let Some(kinds) = &request.result_kinds {
        let names = ["file", "type", "symbol", "content"];
        if kinds.iter().any(|kind| !names.contains(&kind.as_str())) {
            return Err(CoreError::new(
                ErrorCode::InvalidRequest,
                "Invalid search result kind",
            ));
        }
        for (index, name) in names.iter().enumerate() {
            page.exhausted[index] |= !kinds.iter().any(|kind| kind == name);
        }
    }
    if request.search.query.trim().is_empty() {
        page.exhausted = [true; 4];
    }
    let mut search = request.search;
    search.max_results = size * 4;
    search.max_file_results = Some(search.max_file_results.unwrap_or(size).min(size));
    search.max_symbol_results = Some(search.max_symbol_results.unwrap_or(size).min(size));
    search.max_content_results = Some(search.max_content_results.unwrap_or(size).min(size));
    let results = search_everywhere_with_page(search, Some(&mut page))?;
    let next_cursor = if page.exhausted.iter().all(|done| *done) {
        None
    } else {
        Some(serde_json::to_string(&page).unwrap())
    };
    Ok(serde_json::to_value(PageResponse {
        results,
        next_cursor,
    })
    .unwrap())
}
