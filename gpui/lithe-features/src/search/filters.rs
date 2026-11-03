//! 「在文件中查找」的 include / exclude 路径过滤。
//!
//! Core 的 `SearchRequest` 只有 `fileMask`，没有 include / exclude glob，因此
//! 过滤只能发生在结果侧。匹配语义对齐 Tauri 的 `createPathFilterPredicate`：
//! 支持 `**`、`*`、`?`，其余字符按字面量处理。

use super::SearchFileGroup;

/// 按 include / exclude 过滤分组。
///
/// 路径是工作区相对路径，因此不需要再相对根目录做一次裁剪。
pub(super) fn filter_groups(
    groups: Vec<SearchFileGroup>,
    include: &[PathFilter],
    exclude: &[PathFilter],
) -> Vec<SearchFileGroup> {
    if include.is_empty() && exclude.is_empty() {
        return groups;
    }

    groups
        .into_iter()
        .filter(|group| {
            if !include.is_empty() && !matches_any(&group.path, include) {
                return false;
            }
            if !exclude.is_empty() && matches_any(&group.path, exclude) {
                return false;
            }
            true
        })
        .collect()
}

/// 一个已编译的 include / exclude 规则。
pub(super) struct PathFilter {
    /// `*` / `?` 已展开成正则。
    matcher: Option<WildcardMatcher>,
    /// 正则编译失败时退回大小写不敏感的子串匹配。
    fallback: String,
}

fn matches_any(path: &str, filters: &[PathFilter]) -> bool {
    filters.iter().any(|filter| match &filter.matcher {
        Some(matcher) => matcher.is_match(path),
        None => path.to_lowercase().contains(&filter.fallback),
    })
}

/// 把逗号或换行分隔的过滤表达式编译成规则表。
pub(super) fn parse_path_filters(query: &str) -> Vec<PathFilter> {
    query
        .split([',', '\n'])
        .map(str::trim)
        .filter(|part| !part.is_empty())
        .map(|glob| PathFilter {
            matcher: WildcardMatcher::compile(glob),
            fallback: glob.to_lowercase(),
        })
        .collect()
}

/// 支持 `**`、`*`、`?` 的大小写不敏感通配符匹配。
///
/// 不引入正则依赖：Core 和本 crate 都没有 `regex`，为一段路径过滤新增依赖不
/// 值得，这里用两行动态规划实现教科书式的通配符匹配。
struct WildcardMatcher {
    /// 匹配目标的小写化模式，`/` 是普通字符。
    pattern: Vec<char>,
}

impl WildcardMatcher {
    fn compile(glob: &str) -> Option<Self> {
        Some(Self {
            pattern: glob.to_lowercase().chars().collect(),
        })
    }

    /// 经典通配符匹配，对齐 Tauri 的 `globToRegExp`：
    /// `**` 匹配任意字符（含 `/`），`*` 匹配除 `/` 外的任意字符，
    /// `?` 匹配除 `/` 外的单个字符。
    fn is_match(&self, text: &str) -> bool {
        let text: Vec<char> = text.to_lowercase().chars().collect();
        let pattern = &self.pattern;

        // dp[j] 表示模式前缀能匹配文本前 j 个字符。
        let mut dp = vec![false; text.len() + 1];
        dp[0] = true;

        let mut index = 0;
        while index < pattern.len() {
            let token = pattern[index];
            if token == '*' {
                let cross_slash = pattern.get(index + 1) == Some(&'*');
                if cross_slash {
                    // 折叠连续的 `**` / `***`：匹配任意长度（含 0 和 `/`）。
                    while index < pattern.len() && pattern[index] == '*' {
                        index += 1;
                    }
                    for column in 1..=text.len() {
                        dp[column] = dp[column] || dp[column - 1];
                    }
                } else {
                    index += 1;
                    // `*` 不能跨目录：只有当前字符不是 `/` 才能继续延伸。
                    for column in 1..=text.len() {
                        dp[column] =
                            dp[column] || (dp[column - 1] && text[column - 1] != '/');
                    }
                }
                continue;
            }

            // 非通配符：整体右移一格，只保留能继续匹配的前缀。
            for column in (1..=text.len()).rev() {
                let matches_char = if token == '?' {
                    text[column - 1] != '/'
                } else {
                    text[column - 1] == token
                };
                dp[column] = dp[column - 1] && matches_char;
            }
            dp[0] = false;
            index += 1;
        }

        dp[text.len()]
    }
}
