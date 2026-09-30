//! Explorer 文件树搜索的纯逻辑层：常量、全树命中收集与命中子树过滤。
//!
//! 真源对应关系（1:1 复刻 Windows，不臆造语义）：
//! - `FILE_TREE_SEARCH_RESULT_LIMIT` / `FILE_TREE_SEARCH_DEBOUNCE_DELAY` 抄自
//!   `windows/tauri/src/features/file-explorer/components/file-explorer-tree.tsx`。
//! - 命中收集抄自 `windows/tauri/src/features/file-explorer/lib/visible-file-tree-rows.ts`
//!   的 `collectFileTreeSearchHits`（`"${name} ${path}".toLowerCase()` 子串匹配）。
//! - 命中子树过滤抄自同文件的 `filterFileTreeForFffHits`：命中项连同其祖先目录
//!   保留，祖先目录标记为展开，匹配顺序保持树的深度优先顺序。
//!
//! 这里不触碰 gpui 与 IO，便于用确定性单测锁定行为。

use super::sidebar::FileEntry;

/// 文件树搜索结果上限（`FILE_TREE_SEARCH_RESULT_LIMIT`）。
pub const TREE_SEARCH_RESULT_LIMIT: usize = 500;
/// 文件树搜索输入防抖延迟（`FILE_TREE_SEARCH_DEBOUNCE_DELAY`，毫秒）。
///
/// Linux 侧当前在按键时同步重算，保留常量用于对齐语义与后续接入防抖。
#[allow(dead_code)]
pub const TREE_SEARCH_DEBOUNCE_DELAY_MS: u64 = 80;

/// 收集全树命中路径（对齐 `collectFileTreeSearchHits`）。
///
/// 遍历完整递归树（不限于已展开节点），对每个节点的 `"name path"` 做
/// 大小写不敏感子串匹配；命中顺序即树的深度优先顺序，达到 `limit` 即停止。
pub fn collect_hits(root: &FileEntry, query: &str, limit: usize) -> Vec<String> {
    let normalized = query.trim().to_lowercase();
    if normalized.is_empty() || limit == 0 {
        return Vec::new();
    }

    let mut hits = Vec::new();
    collect_hits_inner(root, &normalized, limit, &mut hits);
    hits
}

fn collect_hits_inner(node: &FileEntry, query: &str, limit: usize, hits: &mut Vec<String>) {
    if hits.len() >= limit {
        return;
    }

    // `searchableText` 同时包含名称与路径：Windows 用空格连接，便于路径片段命中。
    let searchable = format!("{} {}", node.name, node.path).to_lowercase();
    if searchable.contains(query) {
        hits.push(node.path.clone());
    }

    if let Some(children) = &node.children {
        for child in children {
            if hits.len() >= limit {
                return;
            }
            collect_hits_inner(child, query, limit, hits);
        }
    }
}

/// 命中子树的过滤结果。
#[derive(Debug, Clone, Default)]
pub struct TreeSearchResult {
    /// 命中项及其祖先目录组成的新树；`root` 本身不计入（由调用方拼接）。
    pub children: Vec<FileEntry>,
    /// 命中项自身的路径集合（用于回车跳转与高亮）。
    pub matched_paths: Vec<String>,
    /// 需要展开的目录路径集合（命中项的祖先目录）。
    pub expanded_paths: Vec<String>,
    /// 命中项数量（`matched_paths.len()`，与 Windows `matchCount` 对齐）。
    pub match_count: usize,
}

/// 按命中路径过滤子树（对齐 `filterFileTreeForFffHits`）。
///
/// 保留规则：命中项及其祖先目录；命中项或其子树含命中时保留，其余节点丢弃。
/// 含命中子节点的目录加入 `expanded_paths`（渲染时强制展开），命中项自身
/// 保持原始展开态；命中项若无命中子节点则保留其原始 `children`，与 Windows
/// `children: matchingChildren.length > 0 ? matchingChildren : item.children` 一致。
pub fn filter_for_hits(root: &FileEntry, hit_paths: &[String]) -> TreeSearchResult {
    let mut result = TreeSearchResult::default();
    if hit_paths.is_empty() {
        return result;
    }

    let hit_set: std::collections::HashSet<&str> = hit_paths.iter().map(|p| p.as_str()).collect();
    let children = root.children.as_deref().unwrap_or(&[]);
    for child in children {
        if let Some(filtered) = filter_node(child, &hit_set, &mut result) {
            result.children.push(filtered);
        }
    }
    result.match_count = result.matched_paths.len();
    result
}

/// 递归过滤单个节点：命中或子树含命中时返回保留节点，否则返回 `None`。
fn filter_node(
    node: &FileEntry,
    hit_set: &std::collections::HashSet<&str>,
    result: &mut TreeSearchResult,
) -> Option<FileEntry> {
    let mut kept_children = Vec::new();
    if let Some(children) = &node.children {
        for child in children {
            if let Some(filtered) = filter_node(child, hit_set, result) {
                kept_children.push(filtered);
            }
        }
    }

    let is_match = hit_set.contains(node.path.as_str());
    if !is_match && kept_children.is_empty() {
        return None;
    }

    if is_match {
        result.matched_paths.push(node.path.clone());
    }
    if node.is_directory && !kept_children.is_empty() {
        result.expanded_paths.push(node.path.clone());
    }

    Some(FileEntry {
        path: node.path.clone(),
        name: node.name.clone(),
        is_directory: node.is_directory,
        size: node.size,
        children: if kept_children.is_empty() {
            node.children.clone()
        } else {
            Some(kept_children)
        },
        is_expanded: node.is_expanded,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn file(path: &str, name: &str) -> FileEntry {
        FileEntry {
            path: path.to_string(),
            name: name.to_string(),
            is_directory: false,
            size: None,
            children: None,
            is_expanded: false,
        }
    }

    fn dir(path: &str, name: &str, children: Vec<FileEntry>) -> FileEntry {
        FileEntry {
            path: path.to_string(),
            name: name.to_string(),
            is_directory: true,
            size: None,
            children: Some(children),
            is_expanded: true,
        }
    }

    fn sample_root() -> FileEntry {
        dir(
            "/w",
            "w",
            vec![
                dir(
                    "/w/src",
                    "src",
                    vec![
                        file("/w/src/main.rs", "main.rs"),
                        file("/w/src/lib.rs", "lib.rs"),
                    ],
                ),
                dir(
                    "/w/docs",
                    "docs",
                    vec![file("/w/docs/readme.md", "readme.md")],
                ),
                file("/w/Cargo.toml", "Cargo.toml"),
            ],
        )
    }

    /// 命中收集应遍历未展开/嵌套节点，并按深度优先顺序返回。
    #[test]
    fn collect_hits_walks_full_tree_in_depth_first_order() {
        let hits = collect_hits(&sample_root(), "rs", TREE_SEARCH_RESULT_LIMIT);
        assert_eq!(
            hits,
            vec!["/w/src/main.rs".to_string(), "/w/src/lib.rs".to_string()]
        );
    }

    /// 空查询返回空结果（不展开全树）。
    #[test]
    fn collect_hits_returns_empty_for_blank_query() {
        assert!(collect_hits(&sample_root(), "   ", TREE_SEARCH_RESULT_LIMIT).is_empty());
        assert!(collect_hits(&sample_root(), "", TREE_SEARCH_RESULT_LIMIT).is_empty());
    }

    /// 匹配串同时包含名称与路径，路径片段应能命中。
    #[test]
    fn collect_hits_matches_path_segments_too() {
        let hits = collect_hits(&sample_root(), "docs", TREE_SEARCH_RESULT_LIMIT);
        assert_eq!(
            hits,
            vec!["/w/docs".to_string(), "/w/docs/readme.md".to_string()]
        );
    }

    /// 大小写不敏感匹配（对齐 Windows 的 `toLowerCase`）。
    #[test]
    fn collect_hits_is_case_insensitive() {
        let hits = collect_hits(&sample_root(), "MAIN", TREE_SEARCH_RESULT_LIMIT);
        assert_eq!(hits, vec!["/w/src/main.rs".to_string()]);
    }

    /// 命中上限生效，超出后停止收集。
    #[test]
    fn collect_hits_respects_limit() {
        let hits = collect_hits(&sample_root(), "/w", 2);
        assert_eq!(hits.len(), 2);
    }

    /// 过滤应保留命中项及其祖先目录，并标记祖先展开、记录命中路径。
    #[test]
    fn filter_keeps_hit_and_ancestors() {
        let hits = vec!["/w/src/main.rs".to_string()];
        let result = filter_for_hits(&sample_root(), &hits);

        assert_eq!(result.children.len(), 1);
        let src = &result.children[0];
        assert_eq!(src.path, "/w/src");
        assert_eq!(src.children.as_ref().unwrap().len(), 1);
        assert_eq!(src.children.as_ref().unwrap()[0].path, "/w/src/main.rs");

        assert_eq!(result.matched_paths, vec!["/w/src/main.rs".to_string()]);
        assert_eq!(result.expanded_paths, vec!["/w/src".to_string()]);
    }

    /// 命中目录自身时记录命中，但不因命中而强制展开（对齐 Windows：
    /// 仅含命中子节点的目录才进 `expandedPaths`）。
    #[test]
    fn filter_matched_directory_keeps_original_children() {
        let hits = vec!["/w/docs".to_string()];
        let result = filter_for_hits(&sample_root(), &hits);

        assert_eq!(result.children.len(), 1);
        assert_eq!(result.children[0].path, "/w/docs");
        assert!(result.expanded_paths.is_empty());
        // 命中目录无命中子节点，保留原始 children（与 Windows 一致）。
        assert_eq!(result.children[0].children.as_ref().unwrap().len(), 1);
        assert_eq!(result.matched_paths, vec!["/w/docs".to_string()]);
        assert_eq!(result.match_count, 1);
    }

    /// 无命中时返回空结果，不保留任何节点。
    #[test]
    fn filter_returns_empty_without_hits() {
        let result = filter_for_hits(&sample_root(), &[]);
        assert!(result.children.is_empty());
        assert!(result.matched_paths.is_empty());
        assert!(result.expanded_paths.is_empty());
    }
}
