//! 全局内容搜索的纯逻辑层：常量、匹配选项、结果分组、路径过滤、摘录构建。
//!
//! 真源对应关系（1:1 复刻 Windows，不臆造语义）：
//! - 常量抄自 `windows/tauri/src/features/global-search/constants/limits.ts`
//!   与 `hooks/use-content-search.ts`（`CONTEXT_LINES`）。
//! - 结果分组与分页语义抄自
//!   `windows/tauri/src/features/file-search/lib/file-search-api.ts` 的
//!   `searchFilesContent`。
//! - 路径 include/exclude 过滤抄自
//!   `windows/tauri/src/features/global-search/utils/path-filters.ts`。
//! - 摘录（上下文合并、`...` 省略、行号映射、高亮区间）抄自
//!   `windows/tauri/src/features/global-search/utils/search-excerpts.ts`。
//!
//! 这里不触碰 gpui 与 IO，便于用确定性单测锁定行为。

use std::collections::HashMap;

use regex::Regex;

/// 每页内容搜索结果数（`CONTENT_SEARCH_PAGE_SIZE`）。
pub const CONTENT_SEARCH_PAGE_SIZE: usize = 140;
/// 每个文件摘录默认携带的上下文行数（`CONTEXT_LINES`）。
pub const CONTEXT_LINES: usize = 2;
/// 展开上下文时携带的行数（`EXPANDED_CONTEXT_LINES`）。
pub const EXPANDED_CONTEXT_LINES: usize = 7;
/// 搜索输入防抖延迟（`SEARCH_DEBOUNCE_DELAY`，毫秒）。
pub const SEARCH_DEBOUNCE_DELAY_MS: u64 = 200;
/// 首次渲染的结果条数（`CONTENT_SEARCH_INITIAL_RENDER_LIMIT`）。
pub const CONTENT_SEARCH_INITIAL_RENDER_LIMIT: usize = 40;
/// 每次增量渲染追加的结果条数（`CONTENT_SEARCH_RENDER_INCREMENT`）。
pub const CONTENT_SEARCH_RENDER_INCREMENT: usize = 40;

/// 三个搜索开关，对应 Windows `ContentSearchOptions`。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct ContentSearchOptions {
    pub case_sensitive: bool,
    pub whole_word: bool,
    pub use_regex: bool,
}

impl ContentSearchOptions {
    /// 搜索会话标识：把选项编译进 key，用于丢弃过期响应。
    pub fn cache_key(&self) -> String {
        format!(
            "{}{}{}",
            u8::from(self.case_sensitive),
            u8::from(self.whole_word),
            u8::from(self.use_regex)
        )
    }
}

/// core `workspace.search` 返回的单条匹配。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CoreSearchMatch {
    pub kind: String,
    pub path: String,
    pub line: Option<usize>,
    pub preview: String,
}

/// 一行内的匹配区间。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MatchRange {
    pub start: usize,
    pub end: usize,
}

/// 文件中一行的匹配，对应 Windows `SearchMatch`。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SearchMatch {
    pub line_number: usize,
    pub line_content: String,
    pub column_start: usize,
    pub column_end: usize,
    pub match_ranges: Vec<MatchRange>,
    pub context_before: Vec<String>,
    pub context_after: Vec<String>,
}

/// 一个文件的全部匹配，对应 Windows `FileSearchResult`。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileSearchResult {
    pub file_path: String,
    pub matches: Vec<SearchMatch>,
    pub total_matches: usize,
}

/// `searchFilesContent` 的输出，对应 Windows `SearchFilesResponse`。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SearchFilesResponse {
    pub results: Vec<FileSearchResult>,
    pub total_files: usize,
    pub searched_files: usize,
    pub searchable_files: usize,
    pub files_with_matches: usize,
    pub next_file_offset: usize,
    pub has_more: bool,
}

/// 在 `line` 上找出 `regex` 的全部匹配区间（抄自 `findLineMatchRanges`）。
#[allow(dead_code)]
fn find_line_match_ranges(line: &str, regex: &Regex) -> Vec<MatchRange> {
    regex
        .find_iter(line)
        .map(|m| MatchRange {
            start: m.start(),
            end: m.end(),
        })
        .collect()
}

/// 依据匹配选项构建内容搜索正则；`use_regex=false` 时对查询做字面量转义。
/// 对应 Windows `buildSearchRegex`。
#[allow(dead_code)]
pub fn build_search_regex(query: &str, options: ContentSearchOptions) -> Option<Regex> {
    if query.is_empty() {
        return None;
    }

    let pattern = if options.use_regex {
        query.to_string()
    } else {
        let escaped = regex::escape(query);
        if options.whole_word {
            format!(r"\b{}\b", escaped)
        } else {
            escaped
        }
    };

    // 全字匹配在正则模式下用零宽边界包裹，与 Windows 的头尾 `\b` 语义一致。
    let pattern = if options.use_regex && options.whole_word {
        format!(r"\b(?:{})\b", pattern)
    } else {
        pattern
    };

    regex::RegexBuilder::new(&pattern)
        .case_insensitive(!options.case_sensitive)
        .build()
        .ok()
}

/// 把一个文件的内容按查询切分成匹配行（抄自 `buildFileSearchResult`）。
///
/// 含 NUL 的二进制内容返回 `None`；无匹配返回 `None`。
#[allow(dead_code)]
pub fn build_file_search_result(
    file_path: &str,
    content: &str,
    regex: &Regex,
    context_lines: usize,
) -> Option<FileSearchResult> {
    if content.contains('\0') {
        return None;
    }

    let lines: Vec<&str> = content.split('\n').collect();
    let mut matches = Vec::new();

    for (index, line) in lines.iter().enumerate() {
        let ranges = find_line_match_ranges(line, regex);
        if ranges.is_empty() {
            continue;
        }

        let line_number = index + 1;
        let first = ranges
            .first()
            .copied()
            .unwrap_or(MatchRange { start: 0, end: 0 });
        matches.push(SearchMatch {
            line_number,
            line_content: (*line).to_string(),
            column_start: first.start,
            column_end: first.end,
            match_ranges: ranges,
            context_before: lines[index.saturating_sub(context_lines)..index]
                .iter()
                .map(|l| (*l).to_string())
                .collect(),
            context_after: lines[index + 1..(index + 1 + context_lines).min(lines.len())]
                .iter()
                .map(|l| (*l).to_string())
                .collect(),
        });
    }

    if matches.is_empty() {
        return None;
    }

    Some(FileSearchResult {
        file_path: file_path.to_string(),
        total_matches: matches.len(),
        matches,
    })
}

/// 合并两批按文件分组的结果（抄自 `mergeSearchResults`）。
pub fn merge_search_results(
    previous: &[FileSearchResult],
    next: Vec<FileSearchResult>,
) -> Vec<FileSearchResult> {
    if previous.is_empty() {
        return next;
    }
    if next.is_empty() {
        return previous.to_vec();
    }

    let mut merged: Vec<FileSearchResult> = previous.to_vec();
    let mut index_by_path: HashMap<String, usize> = merged
        .iter()
        .enumerate()
        .map(|(index, result)| (result.file_path.clone(), index))
        .collect();

    for result in next {
        match index_by_path.get(&result.file_path).copied() {
            Some(index) => {
                let existing = &mut merged[index];
                existing.matches.extend(result.matches);
                existing.total_matches += result.total_matches;
            }
            None => {
                index_by_path.insert(result.file_path.clone(), merged.len());
                merged.push(result);
            }
        }
    }

    merged
}

/// 把 core 返回的扁平匹配列表转成分页、按文件分组的结果。
///
/// 语义对齐 `searchFilesContent`：只保留 `kind == "content"`，
/// `max_results` 截断文件数，`has_more` 表示还有文件未返回。
pub fn group_content_matches(
    root: &str,
    matches: Vec<CoreSearchMatch>,
    max_results: usize,
) -> SearchFilesResponse {
    let mut grouped: Vec<FileSearchResult> = Vec::new();
    let mut index_by_path: HashMap<String, usize> = HashMap::new();

    for item in matches {
        if item.kind != "content" {
            continue;
        }

        let file_path = join_path(root, &item.path);
        let line_number = item.line.unwrap_or(1);
        let line_content = item.preview.clone();
        let column_start = 0;
        let column_end = line_content.len();

        let entry = match index_by_path.get(&file_path).copied() {
            Some(index) => &mut grouped[index],
            None => {
                index_by_path.insert(file_path.clone(), grouped.len());
                grouped.push(FileSearchResult {
                    file_path: file_path.clone(),
                    matches: Vec::new(),
                    total_matches: 0,
                });
                grouped.last_mut().expect("just pushed")
            }
        };

        entry.matches.push(SearchMatch {
            line_number,
            line_content,
            column_start,
            column_end,
            match_ranges: Vec::new(),
            context_before: Vec::new(),
            context_after: Vec::new(),
        });
        entry.total_matches += 1;
    }

    let total_files = grouped.len();
    let has_more = total_files > max_results;
    grouped.truncate(max_results);

    SearchFilesResponse {
        results: grouped,
        total_files,
        searched_files: total_files,
        searchable_files: total_files,
        files_with_matches: total_files,
        next_file_offset: total_files.min(max_results),
        has_more,
    }
}

/// 用平台无关的方式拼接根目录与相对路径。
pub fn join_path(root: &str, relative: &str) -> String {
    if root.is_empty() {
        return relative.to_string();
    }
    if relative.is_empty() {
        return root.to_string();
    }
    let separator = if root.contains('\\') && !root.contains('/') {
        '\\'
    } else {
        '/'
    };
    if root.ends_with(separator) {
        format!("{}{}", root, relative)
    } else {
        format!("{}{}{}", root, separator, relative)
    }
}

/// 取相对路径（用于展示与过滤），抄自 `getRelativePath` 的宽松语义。
pub fn relative_path(path: &str, root: Option<&str>) -> String {
    let Some(root) = root else {
        return path.to_string();
    };
    if root.is_empty() {
        return path.to_string();
    }
    let normalized_root = root.trim_end_matches(['/', '\\']);
    let prefix = format!("{}/", normalized_root);
    if let Some(rest) = path.strip_prefix(&prefix) {
        return rest.to_string();
    }
    let prefix_backslash = format!("{}\\", normalized_root);
    if let Some(rest) = path.strip_prefix(&prefix_backslash) {
        return rest.to_string();
    }
    path.to_string()
}

/// 输入行距：全局搜索面板内部使用的文件过滤器，支持 glob 与逗号/换行分隔。
///
/// 抄自 `path-filters.ts`。
#[derive(Debug, Clone)]
pub struct PathFilter {
    matcher: Option<Regex>,
    fallback: String,
}

impl PathFilter {
    fn compile(glob: &str) -> Option<Self> {
        let trimmed = glob.trim();
        if trimmed.is_empty() {
            return None;
        }

        let mut source = String::new();
        let chars: Vec<char> = trimmed.chars().collect();
        let mut index = 0;
        while index < chars.len() {
            let current = chars[index];
            let next = chars.get(index + 1).copied();
            match (current, next) {
                ('*', Some('*')) => {
                    source.push_str(".*");
                    index += 2;
                    continue;
                }
                ('*', _) => source.push_str("[^/]*"),
                ('?', _) => source.push_str("[^/]"),
                _ => {
                    if "|\\{}()[]^$+?.".contains(current) {
                        source.push('\\');
                    }
                    source.push(current);
                }
            }
            index += 1;
        }

        Some(Self {
            matcher: Regex::new(&source).ok(),
            fallback: trimmed.to_lowercase(),
        })
    }

    fn matches(&self, path: &str) -> bool {
        match &self.matcher {
            Some(matcher) => matcher.is_match(path),
            None => path.to_lowercase().contains(&self.fallback),
        }
    }
}

/// 把 include/exclude 查询编译成过滤器列表（按逗号或换行分隔）。
pub fn compile_path_filters(query: &str) -> Vec<PathFilter> {
    query
        .split([',', '\n'])
        .filter_map(PathFilter::compile)
        .collect()
}

/// 是否命中 include/exclude 过滤（抄自 `createPathFilterPredicate`）。
pub fn matches_path_filters(
    path: &str,
    root: Option<&str>,
    include: &[PathFilter],
    exclude: &[PathFilter],
) -> bool {
    if include.is_empty() && exclude.is_empty() {
        return true;
    }

    let relative = relative_path(path, root);

    if !include.is_empty() && !include.iter().any(|filter| filter.matches(&relative)) {
        return false;
    }

    if !exclude.is_empty() && exclude.iter().any(|filter| filter.matches(&relative)) {
        return false;
    }

    true
}

/// 摘录中的一段高亮区间。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ExcerptHighlight {
    pub item_key: String,
    pub start: usize,
    pub end: usize,
}

/// 摘录中的一个可跳转匹配。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ExcerptMatch {
    pub item_key: String,
    pub file_path: String,
    pub target_line: usize,
    pub target_column: usize,
    pub highlight_indexes: Vec<usize>,
}

/// 一个文件的摘录（合并上下文后的文本、行号映射、高亮）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SearchExcerpt {
    pub id: String,
    pub file_path: String,
    pub display_path: String,
    pub content: String,
    pub line_number_map: Vec<Option<usize>>,
    pub matches: Vec<ExcerptMatch>,
    pub match_count: usize,
    pub highlights: Vec<ExcerptHighlight>,
}

fn fallback_range(item: &SearchMatch) -> MatchRange {
    MatchRange {
        start: item.column_start,
        end: item.column_end.max(item.column_start + 1),
    }
}

fn match_ranges(item: &SearchMatch) -> Vec<MatchRange> {
    let ranges = if item.match_ranges.is_empty() {
        vec![fallback_range(item)]
    } else {
        item.match_ranges.clone()
    };

    ranges
        .into_iter()
        .map(|range| MatchRange {
            start: range.start,
            end: range.end.max(range.start + 1),
        })
        .filter(|range| range.end > range.start)
        .collect()
}

/// 为单个文件构建摘录（抄自 `buildSearchExcerpt`）。
fn build_search_excerpt(
    result: &FileSearchResult,
    root: Option<&str>,
    match_limit: usize,
    context_lines: Option<usize>,
    source_content: Option<&str>,
) -> Option<SearchExcerpt> {
    let display_path = relative_path(&result.file_path, root);
    let source_lines: Option<Vec<&str>> = source_content.map(|c| c.split('\n').collect());
    let mut line_text_by_number: HashMap<usize, String> = HashMap::new();
    let mut context_ranges: Vec<(usize, usize)> = Vec::new();
    let mut included: Vec<(String, SearchMatch, Vec<MatchRange>)> = Vec::new();

    for (index, item) in result.matches.iter().enumerate() {
        if index >= match_limit {
            break;
        }

        // 展开上下文时优先按源文件行数取行（与 Windows `sourceLines` 分支一致）；
        // 否则回退到 core 附带的上下文字符串。
        let expanded_with_source = source_lines.is_some() && context_lines.is_some();
        let context_before_length = if expanded_with_source {
            context_lines
                .unwrap_or(0)
                .min(item.line_number.saturating_sub(1))
        } else {
            item.context_before.len()
        };
        let context_after_length = if expanded_with_source {
            let total = source_lines.as_ref().map(|l| l.len()).unwrap_or(0);
            context_lines
                .unwrap_or(0)
                .min(total.saturating_sub(item.line_number))
        } else {
            item.context_after.len()
        };
        let start_line = item
            .line_number
            .saturating_sub(context_before_length)
            .max(1);
        let end_line = item.line_number + context_after_length;
        let item_key = format!("{}:{}:{}", result.file_path, item.line_number, index);

        if let Some(lines) = source_lines.as_ref() {
            for line_number in start_line..=end_line {
                line_text_by_number.insert(
                    line_number,
                    lines
                        .get(line_number - 1)
                        .copied()
                        .unwrap_or("")
                        .to_string(),
                );
            }
        } else {
            for (offset, line) in item.context_before.iter().enumerate() {
                line_text_by_number.insert(start_line + offset, line.clone());
            }
            line_text_by_number.insert(item.line_number, item.line_content.clone());
            for (offset, line) in item.context_after.iter().enumerate() {
                line_text_by_number.insert(item.line_number + offset + 1, line.clone());
            }
        }

        context_ranges.push((start_line, end_line));
        included.push((item_key, item.clone(), match_ranges(item)));
    }

    if included.is_empty() {
        return None;
    }

    // 合并相邻/重叠的上下文区间，区间之间插入 `...` 分隔（抄自 `mergedRanges`）。
    context_ranges.sort_by_key(|range| range.0);
    let mut merged_ranges: Vec<(usize, usize)> = Vec::new();
    for range in context_ranges {
        match merged_ranges.last_mut() {
            Some(previous) if range.0 <= previous.1 + 1 => {
                previous.1 = previous.1.max(range.1);
            }
            _ => merged_ranges.push(range),
        }
    }

    let mut context_lines_out: Vec<String> = Vec::new();
    let mut line_number_map: Vec<Option<usize>> = Vec::new();
    for (range_index, (start, end)) in merged_ranges.iter().enumerate() {
        if range_index > 0 {
            context_lines_out.push("...".to_string());
            line_number_map.push(None);
        }
        for line_number in *start..=*end {
            context_lines_out.push(
                line_text_by_number
                    .get(&line_number)
                    .cloned()
                    .unwrap_or_default(),
            );
            line_number_map.push(Some(line_number));
        }
    }

    // 行号 → 摘录行索引，用于把匹配位置换算成高亮偏移。
    let mut line_index_by_number: HashMap<usize, usize> = HashMap::new();
    for (index, line_number) in line_number_map.iter().enumerate() {
        if let Some(line_number) = line_number {
            line_index_by_number.entry(*line_number).or_insert(index);
        }
    }

    let mut line_offsets: Vec<usize> = Vec::new();
    let mut next_offset = 0usize;
    for line in &context_lines_out {
        line_offsets.push(next_offset);
        next_offset += line.chars().count() + 1;
    }

    let mut highlights: Vec<ExcerptHighlight> = Vec::new();
    let mut matches: Vec<ExcerptMatch> = Vec::new();
    for (item_key, item, ranges) in included {
        let mut highlight_indexes = Vec::new();
        if let Some(line_index) = line_index_by_number.get(&item.line_number).copied() {
            let base = line_offsets.get(line_index).copied().unwrap_or(0);
            for range in ranges {
                highlight_indexes.push(highlights.len());
                highlights.push(ExcerptHighlight {
                    item_key: item_key.clone(),
                    start: base + range.start,
                    end: base + range.end,
                });
            }
        }

        matches.push(ExcerptMatch {
            item_key,
            file_path: result.file_path.clone(),
            target_line: item.line_number,
            target_column: item.column_start + 1,
            highlight_indexes,
        });
    }

    Some(SearchExcerpt {
        id: result.file_path.clone(),
        file_path: result.file_path.clone(),
        display_path,
        content: context_lines_out.join("\n"),
        line_number_map,
        matches,
        match_count: result.total_matches,
        highlights,
    })
}

/// 按文件顺序构建摘录，直到用满 `limit` 个匹配（抄自 `buildSearchExcerpts`）。
///
/// `context_lines_by_file` 给出「已展开上下文」的文件 → 行数覆盖。
pub fn build_search_excerpts(
    results: &[FileSearchResult],
    root: Option<&str>,
    limit: usize,
    context_lines_by_file: &HashMap<String, usize>,
    source_content_by_path: &HashMap<String, String>,
) -> Vec<SearchExcerpt> {
    let mut excerpts = Vec::new();
    let mut remaining = limit;

    for result in results {
        if remaining == 0 {
            break;
        }

        let context_lines = context_lines_by_file.get(&result.file_path).copied();
        let source = source_content_by_path
            .get(&result.file_path)
            .map(|s| s.as_str());
        let Some(excerpt) = build_search_excerpt(result, root, remaining, context_lines, source)
        else {
            continue;
        };

        remaining = remaining.saturating_sub(excerpt.matches.len());
        excerpts.push(excerpt);
    }

    excerpts
}

#[cfg(test)]
mod tests {
    use super::*;

    fn default_options() -> ContentSearchOptions {
        ContentSearchOptions::default()
    }

    /// 普通查询做字面量匹配，大小写不敏感（默认选项）。
    #[test]
    fn literal_regex_is_case_insensitive_by_default() {
        let regex = build_search_regex("hello", default_options()).expect("regex");
        assert!(regex.is_match("Hello World"));
        assert!(regex.is_match("say hello"));
        assert!(!regex.is_match("shell"));
    }

    /// 区分大小写时不再忽略大小写。
    #[test]
    fn case_sensitive_option_is_honored() {
        let options = ContentSearchOptions {
            case_sensitive: true,
            ..default_options()
        };
        let regex = build_search_regex("hello", options).expect("regex");
        assert!(regex.is_match("hello"));
        assert!(!regex.is_match("Hello"));
    }

    /// 全字匹配不应命中更长单词内部。
    #[test]
    fn whole_word_option_requires_word_boundaries() {
        let options = ContentSearchOptions {
            whole_word: true,
            ..default_options()
        };
        let regex = build_search_regex("cat", options).expect("regex");
        assert!(regex.is_match("a cat here"));
        assert!(!regex.is_match("concatenate"));
    }

    /// 正则模式使用查询原样，并尊重全字边界。
    #[test]
    fn regex_option_uses_pattern_verbatim() {
        let options = ContentSearchOptions {
            use_regex: true,
            ..default_options()
        };
        let regex = build_search_regex(r"a\d+", options).expect("regex");
        assert!(regex.is_match("a123"));
        assert!(!regex.is_match("ab"));

        let whole = ContentSearchOptions {
            use_regex: true,
            whole_word: true,
            ..default_options()
        };
        let regex = build_search_regex("cat", whole).expect("regex");
        assert!(regex.is_match("a cat"));
        assert!(!regex.is_match("concatenate"));
    }

    /// 非法正则返回 `None` 而不是 panic（面板应回退为字面量或报错）。
    #[test]
    fn invalid_regex_returns_none() {
        let options = ContentSearchOptions {
            use_regex: true,
            ..default_options()
        };
        assert!(build_search_regex("([unclosed", options).is_none());
    }

    /// 空查询不构建正则。
    #[test]
    fn empty_query_yields_no_regex() {
        assert!(build_search_regex("", default_options()).is_none());
    }

    /// 单文件摘录：行号、多区间高亮与上下文都要正确。
    #[test]
    fn build_file_result_tracks_ranges_and_context() {
        let regex = build_search_regex("needle", default_options()).expect("regex");
        let content = "one\ntwo needle needle\nthree\nneedle\nfive";
        let result = build_file_search_result("/tmp/a.txt", content, &regex, 1)
            .expect("result should exist");

        assert_eq!(result.total_matches, 2);
        assert_eq!(result.matches[0].line_number, 2);
        assert_eq!(result.matches[0].match_ranges.len(), 2);
        assert_eq!(result.matches[0].context_before, vec!["one"]);
        assert_eq!(result.matches[0].context_after, vec!["three"]);

        assert_eq!(result.matches[1].line_number, 4);
        assert_eq!(result.matches[1].context_before, vec!["three"]);
        assert_eq!(result.matches[1].context_after, vec!["five"]);
    }

    /// 含 NUL 的内容视为二进制，直接跳过。
    #[test]
    fn binary_content_is_skipped() {
        let regex = build_search_regex("needle", default_options()).expect("regex");
        assert!(build_file_search_result("/tmp/bin", "need\0le", &regex, 2).is_none());
    }

    /// 无匹配返回 `None`。
    #[test]
    fn no_match_returns_none() {
        let regex = build_search_regex("absent", default_options()).expect("regex");
        assert!(build_file_search_result("/tmp/a", "nothing here", &regex, 2).is_none());
    }

    /// 分页合并：同文件追加、新文件追加，顺序稳定。
    #[test]
    fn merge_results_dedupes_by_path_and_appends() {
        let make = |path: &str, count: usize| FileSearchResult {
            file_path: path.to_string(),
            matches: vec![
                SearchMatch {
                    line_number: 1,
                    line_content: "x".to_string(),
                    column_start: 0,
                    column_end: 1,
                    match_ranges: Vec::new(),
                    context_before: Vec::new(),
                    context_after: Vec::new(),
                };
                count
            ],
            total_matches: count,
        };

        let previous = vec![make("/a", 1), make("/b", 1)];
        let merged = merge_search_results(&previous, vec![make("/a", 2), make("/c", 1)]);
        let paths: Vec<&str> = merged.iter().map(|r| r.file_path.as_str()).collect();
        assert_eq!(paths, vec!["/a", "/b", "/c"]);
        assert_eq!(merged[0].total_matches, 3);
        assert_eq!(merged[2].total_matches, 1);
    }

    /// core 扁平结果按 `kind == "content"` 分组，并按 maxResults 截断 + 标记 has_more。
    #[test]
    fn group_matches_filters_kind_and_limits_files() {
        let matches = vec![
            CoreSearchMatch {
                kind: "content".to_string(),
                path: "src/a.rs".to_string(),
                line: Some(3),
                preview: "alpha".to_string(),
            },
            CoreSearchMatch {
                kind: "path".to_string(),
                path: "src/ignore.rs".to_string(),
                line: None,
                preview: String::new(),
            },
            CoreSearchMatch {
                kind: "content".to_string(),
                path: "src/b.rs".to_string(),
                line: Some(7),
                preview: "beta".to_string(),
            },
            CoreSearchMatch {
                kind: "content".to_string(),
                path: "src/c.rs".to_string(),
                line: Some(1),
                preview: "gamma".to_string(),
            },
        ];

        let response = group_content_matches("/root", matches, 2);
        assert_eq!(response.results.len(), 2);
        assert_eq!(response.results[0].file_path, "/root/src/a.rs");
        assert_eq!(response.results[0].matches[0].line_number, 3);
        assert_eq!(response.next_file_offset, 2);
        assert!(response.has_more);
    }

    /// glob 过滤：`*` 不跨目录、`**` 跨目录、`?` 单字符。
    #[test]
    fn path_filters_support_globs() {
        let include = compile_path_filters("**.rs");
        assert!(matches_path_filters(
            "/root/src/deep/a.rs",
            Some("/root"),
            &include,
            &[]
        ));
        assert!(!matches_path_filters(
            "/root/src/a.ts",
            Some("/root"),
            &include,
            &[]
        ));

        let single = compile_path_filters("src/?.rs");
        assert!(matches_path_filters(
            "/root/src/a.rs",
            Some("/root"),
            &single,
            &[]
        ));
        assert!(!matches_path_filters(
            "/root/src/ab.rs",
            Some("/root"),
            &single,
            &[]
        ));

        let shallow = compile_path_filters("src/*.rs");
        assert!(matches_path_filters(
            "/root/src/a.rs",
            Some("/root"),
            &shallow,
            &[]
        ));
        assert!(!matches_path_filters(
            "/root/src/deep/a.rs",
            Some("/root"),
            &shallow,
            &[]
        ));
    }

    /// exclude 优先于 include：命中 exclude 即排除。
    #[test]
    fn path_filters_exclude_wins() {
        let include = compile_path_filters("**.rs");
        let exclude = compile_path_filters("**/tests/**");
        assert!(!matches_path_filters(
            "/root/src/tests/a.rs",
            Some("/root"),
            &include,
            &exclude
        ));
        assert!(matches_path_filters(
            "/root/src/lib.rs",
            Some("/root"),
            &include,
            &exclude
        ));
    }

    /// 未提供过滤时全部命中。
    #[test]
    fn path_filters_empty_accepts_everything() {
        assert!(matches_path_filters("/root/a.rs", Some("/root"), &[], &[]));
    }

    /// 摘录：相邻上下文合并、远处匹配用 `...` 分隔并保留行号映射。
    #[test]
    fn excerpts_merge_context_and_insert_ellipsis() {
        let regex = build_search_regex("hit", default_options()).expect("regex");
        let content = "hit a\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nhit b";
        let result = build_file_search_result("/root/a.txt", content, &regex, 1).expect("result");
        let excerpts = build_search_excerpts(
            &[result],
            Some("/root"),
            10,
            &HashMap::new(),
            &HashMap::new(),
        );

        assert_eq!(excerpts.len(), 1);
        let excerpt = &excerpts[0];
        assert!(excerpt.content.contains("..."), "should insert ellipsis");
        assert_eq!(excerpt.matches.len(), 2);
        assert_eq!(excerpt.matches[0].target_line, 1);
        assert_eq!(excerpt.matches[1].target_line, 10);
        assert!(!excerpt.highlights.is_empty());
    }

    /// 摘录限制匹配条数：超出 `limit` 的文件不再产出。
    #[test]
    fn excerpts_respect_match_limit() {
        let regex = build_search_regex("x", default_options()).expect("regex");
        let first = build_file_search_result("/root/a", "x\nx", &regex, 0).expect("a");
        let second = build_file_search_result("/root/b", "x", &regex, 0).expect("b");
        let excerpts = build_search_excerpts(
            &[first, second],
            Some("/root"),
            1,
            &HashMap::new(),
            &HashMap::new(),
        );
        assert_eq!(excerpts.len(), 1);
        assert_eq!(excerpts[0].file_path, "/root/a");
    }

    /// 展开上下文：按文件覆盖上下文行数后，摘录包含更多行。
    #[test]
    fn expanded_context_includes_more_lines() {
        let regex = build_search_regex("hit", default_options()).expect("regex");
        let content = "a\nb\nc\nhit\nd\ne\nf";
        let result = build_file_search_result("/root/a.txt", content, &regex, 0).expect("result");

        let mut expanded = HashMap::new();
        expanded.insert("/root/a.txt".to_string(), EXPANDED_CONTEXT_LINES);
        let mut sources = HashMap::new();
        sources.insert("/root/a.txt".to_string(), content.to_string());
        let excerpts = build_search_excerpts(&[result], Some("/root"), 10, &expanded, &sources);

        assert!(excerpts[0].content.starts_with("a\nb\nc\nhit"));
        assert!(excerpts[0].content.ends_with("d\ne\nf"));
    }

    /// 相对路径在有无根目录两种情况下都稳定。
    #[test]
    fn relative_path_strips_root() {
        assert_eq!(relative_path("/root/src/a.rs", Some("/root")), "src/a.rs");
        assert_eq!(relative_path("/root/src/a.rs", None), "/root/src/a.rs");
        assert_eq!(
            relative_path("/elsewhere/a.rs", Some("/root")),
            "/elsewhere/a.rs"
        );
    }

    /// 路径拼接在 POSIX 与 Windows 风格根目录下都正确。
    #[test]
    fn join_path_handles_both_separators() {
        assert_eq!(join_path("/root", "a.rs"), "/root/a.rs");
        assert_eq!(join_path("C:\\root", "a.rs"), "C:\\root\\a.rs");
        assert_eq!(join_path("/root/", "a.rs"), "/root/a.rs");
        assert_eq!(join_path("", "a.rs"), "a.rs");
    }
}
