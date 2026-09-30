//! 分支管理器（仓库 / 分支 / 工作树）的纯逻辑层：排序、过滤、标签与建名规则。
//!
//! 真源对应关系（1:1 复刻 Windows，不臆造语义）：
//! - `filtered_branches` / `create_branch_name` 抄自
//!   `windows/tauri/src/features/git/components/git-branch-manager.tsx` 的
//!   `getFilteredBranches` / `getCreateBranchName`（当前分支置顶，其余
//!   `localeCompare`；查询用 `matchesSearchQuery`）。
//! - `filtered_worktrees` / `is_openable_worktree` / `worktree_label` 抄自
//!   同文件的 `getFilteredWorktrees` / `getBranchLabel` 与
//!   `windows/tauri/src/features/git/utils/git-worktree-open.ts`。
//! - `filtered_repositories` 抄自 `getFilteredRepositoryPaths`。
//! - 查询匹配抄自 `windows/tauri/src/utils/search-match.ts` 的
//!   `matchesSearchQuery`：NFKD 去音标 + 小写 + 非字母数字折叠为空格，
//!   再按“规范化包含”或“压缩包含”（去空格）匹配。
//!
//! 这里不触碰 gpui 与 IO，便于用确定性单测锁定行为。

/// `clampCommandListIndex`：把下标夹紧到 `[0, itemCount-1]`（空列表为 0）。
pub fn clamp_index(index: usize, item_count: usize) -> usize {
    index.min(item_count.saturating_sub(1))
}

/// `moveCommandListIndex`：上下移动一格并夹紧，不循环。
pub fn move_index(index: usize, item_count: usize, forward: bool) -> usize {
    let current = clamp_index(index, item_count);
    if forward {
        clamp_index(current.saturating_add(1), item_count)
    } else {
        current.saturating_sub(1)
    }
}

/// `collectFileTreeSearchHits` 之类的查询工具模块入口（供 view 复用同一套匹配）。
pub fn query_matches(query: &str, candidates: &[&str]) -> bool {
    matches_search_query(query, candidates)
}

/// 工作树列表项（字段形状对齐 core `git.worktrees` 的 camelCase 返回）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorktreeInfo {
    pub path: String,
    pub head: String,
    pub branch: Option<String>,
    pub is_current: bool,
    pub is_primary: bool,
    pub is_bare: bool,
    pub is_detached: bool,
    pub is_locked: bool,
    pub is_prunable: bool,
}

/// 路径最后一段（`getFolderName` 的简化版：只按 `/` 切分）。
pub fn folder_name(path: &str) -> String {
    let trimmed = path.trim_end_matches('/');
    trimmed
        .rsplit('/')
        .next()
        .filter(|s| !s.is_empty())
        .unwrap_or(trimmed)
        .to_string()
}

/// `getRelativePath`：`path` 在 `root` 之下时返回相对路径，否则返回原串。
pub fn relative_path(path: &str, root: &str) -> String {
    if root.is_empty() {
        return path.to_string();
    }
    let path_trimmed = path.trim_end_matches('/');
    let root_trimmed = root.trim_end_matches('/');
    if path_trimmed == root_trimmed {
        return String::new();
    }
    let prefix = format!("{root_trimmed}/");
    match path_trimmed.strip_prefix(&prefix) {
        Some(rest) => rest.to_string(),
        None => path.to_string(),
    }
}

/// `normalizeSearchText`：NFKD 去音标、小写、非字母数字折叠为空格、去首尾空格。
fn normalize_search_text(value: &str) -> String {
    // Rust 标准库没有 NFKD；这里做等价的可打印折叠：小写后把非
    // ASCII 字母数字与 ASCII 字母数字以外的字符统一替换为空格。
    // 对仓库/分支/路径这类标识符，迁移音标（é→e）退化到“保留原字符”，
    // 再折叠为空格，行为与 Windows 在纯 ASCII 输入上一致。
    let lowered = value.to_lowercase();
    let mut out = String::with_capacity(lowered.len());
    let mut last_space = false;
    for ch in lowered.chars() {
        if ch.is_ascii_alphanumeric() || ch.is_alphanumeric() {
            out.push(ch);
            last_space = false;
        } else if !last_space {
            out.push(' ');
            last_space = true;
        }
    }
    out.trim().to_string()
}

/// `compactSearchText`：规范化后去掉所有空格。
fn compact_search_text(value: &str) -> String {
    normalize_search_text(value).replace(' ', "")
}

/// `matchesSearchQuery`：查询为空恒真；否则任一候选字段规范化/压缩后包含查询。
pub fn matches_search_query(query: &str, candidates: &[&str]) -> bool {
    let normalized = normalize_search_text(query);
    if normalized.is_empty() {
        return true;
    }
    let compact = compact_search_text(query);
    candidates.iter().any(|candidate| {
        normalize_search_text(candidate).contains(&normalized)
            || compact_search_text(candidate).contains(&compact)
    })
}

/// `getFilteredBranches`：当前分支置顶，其余按大小写不敏感名称排序（模拟
/// `localeCompare`），再按查询过滤。
pub fn filtered_branches(branches: &[String], current: &str, query: &str) -> Vec<String> {
    let mut sorted = branches.to_vec();
    sorted.sort_by(|a, b| {
        if a == current {
            return std::cmp::Ordering::Less;
        }
        if b == current {
            return std::cmp::Ordering::Greater;
        }
        a.to_lowercase().cmp(&b.to_lowercase())
    });
    sorted.dedup();

    let normalized = query.trim();
    if normalized.is_empty() {
        return sorted;
    }
    sorted
        .into_iter()
        .filter(|branch| matches_search_query(normalized, &[branch.as_str()]))
        .collect()
}

/// `getCreateBranchName`：查询非空、不等于当前分支、且不存在同名分支时返回建名。
pub fn create_branch_name(branches: &[String], current: &str, query: &str) -> Option<String> {
    let trimmed = query.trim();
    if trimmed.is_empty() || trimmed == current {
        return None;
    }
    if branches
        .iter()
        .any(|branch| branch.to_lowercase() == trimmed.to_lowercase())
    {
        return None;
    }
    Some(trimmed.to_string())
}

/// `isOpenableGitWorktree`：非 bare、非 prunable 才可打开。
pub fn is_openable_worktree(worktree: &WorktreeInfo) -> bool {
    !worktree.is_bare && !worktree.is_prunable
}

/// `getBranchLabel`：分支名；无分支时按 detached / no branch 显示。
pub fn worktree_label(
    worktree: &WorktreeInfo,
    detached_text: &str,
    no_branch_text: &str,
) -> String {
    match &worktree.branch {
        Some(branch) if !branch.is_empty() => branch.clone(),
        _ => {
            if worktree.is_detached {
                detached_text.to_string()
            } else {
                no_branch_text.to_string()
            }
        }
    }
}

/// `getFilteredWorktrees`：过滤掉不可打开的项，当前工作树置顶，其余按目录名
/// 排序，再按目录名/路径/分支/短 head 过滤。
pub fn filtered_worktrees(
    worktrees: &[WorktreeInfo],
    repo_path: &str,
    query: &str,
) -> Vec<WorktreeInfo> {
    let mut sorted: Vec<WorktreeInfo> = worktrees
        .iter()
        .filter(|worktree| is_openable_worktree(worktree))
        .cloned()
        .collect();
    sorted.sort_by(|a, b| {
        if a.path == repo_path {
            return std::cmp::Ordering::Less;
        }
        if b.path == repo_path {
            return std::cmp::Ordering::Greater;
        }
        folder_name(&a.path)
            .to_lowercase()
            .cmp(&folder_name(&b.path).to_lowercase())
    });

    let normalized = query.trim();
    if normalized.is_empty() {
        return sorted;
    }
    sorted
        .into_iter()
        .filter(|worktree| {
            let short_head: String = worktree.head.chars().take(7).collect();
            let branch = worktree.branch.clone().unwrap_or_default();
            matches_search_query(
                normalized,
                &[
                    &folder_name(&worktree.path),
                    &worktree.path,
                    &branch,
                    &short_head,
                ],
            )
        })
        .collect()
}

/// `getCreateWorktreePath`：查询非空且不与现有工作树路径重复时返回建路径。
pub fn create_worktree_path(worktrees: &[WorktreeInfo], query: &str) -> Option<String> {
    let trimmed = query.trim();
    if trimmed.is_empty() {
        return None;
    }
    if worktrees.iter().any(|worktree| worktree.path == trimmed) {
        return None;
    }
    Some(trimmed.to_string())
}

/// `getFilteredRepositoryPaths`：当前仓库置顶，其余按目录名排序，再按目录名/路径过滤。
pub fn filtered_repositories(
    repositories: &[String],
    active_repo_path: Option<&str>,
    query: &str,
) -> Vec<String> {
    let mut sorted = repositories.to_vec();
    sorted.sort_by(|a, b| {
        if Some(a.as_str()) == active_repo_path {
            return std::cmp::Ordering::Less;
        }
        if Some(b.as_str()) == active_repo_path {
            return std::cmp::Ordering::Greater;
        }
        folder_name(a)
            .to_lowercase()
            .cmp(&folder_name(b).to_lowercase())
    });
    sorted.dedup();

    let normalized = query.trim();
    if normalized.is_empty() {
        return sorted;
    }
    sorted
        .into_iter()
        .filter(|path| matches_search_query(normalized, &[&folder_name(path), path.as_str()]))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn worktree(path: &str, branch: Option<&str>) -> WorktreeInfo {
        WorktreeInfo {
            path: path.to_string(),
            head: "abcdef1234567890".to_string(),
            branch: branch.map(|b| b.to_string()),
            is_current: false,
            is_primary: false,
            is_bare: false,
            is_detached: false,
            is_locked: false,
            is_prunable: false,
        }
    }

    fn branches(items: &[&str]) -> Vec<String> {
        items.iter().map(|s| s.to_string()).collect()
    }

    /// 当前分支置顶，其余按名称排序（对齐 `getFilteredBranches`）。
    #[test]
    fn branches_put_current_first_then_name_order() {
        let list = branches(&["zeta", "main", "alpha", "beta"]);
        let result = filtered_branches(&list, "main", "");
        assert_eq!(result, branches(&["main", "alpha", "beta", "zeta"]));
    }

    /// 分支查询用规范化包含匹配（大小写不敏感）。
    #[test]
    fn branches_filter_is_case_insensitive() {
        let list = branches(&["feature/login", "main", "Feature/Logout"]);
        let result = filtered_branches(&list, "main", "FEATURE");
        assert_eq!(result, branches(&["feature/login", "Feature/Logout"]));
    }

    /// 查询等于当前分支时不提供建分支名。
    #[test]
    fn create_name_rejects_current_and_existing() {
        let list = branches(&["main", "dev"]);
        assert_eq!(create_branch_name(&list, "main", "main"), None);
        assert_eq!(create_branch_name(&list, "main", "DEV"), None);
        assert_eq!(create_branch_name(&list, "main", "  "), None);
        assert_eq!(
            create_branch_name(&list, "main", " feature/x "),
            Some("feature/x".to_string())
        );
    }

    /// bare / prunable 工作树不可打开（对齐 `isOpenableGitWorktree`）。
    #[test]
    fn worktree_openable_filters_bare_and_prunable() {
        let mut bare = worktree("/w/bare", Some("main"));
        bare.is_bare = true;
        let mut prunable = worktree("/w/gone", Some("dev"));
        prunable.is_prunable = true;
        assert!(!is_openable_worktree(&bare));
        assert!(!is_openable_worktree(&prunable));
        assert!(is_openable_worktree(&worktree("/w/ok", Some("main"))));
    }

    /// 无分支工作树按 detached / no branch 显示。
    #[test]
    fn worktree_label_falls_back_when_branch_missing() {
        let mut detached = worktree("/w/d", None);
        detached.is_detached = true;
        assert_eq!(
            worktree_label(&detached, "Detached HEAD", "No branch"),
            "Detached HEAD"
        );
        let plain = worktree("/w/p", None);
        assert_eq!(
            worktree_label(&plain, "Detached HEAD", "No branch"),
            "No branch"
        );
        assert_eq!(
            worktree_label(&worktree("/w/m", Some("main")), "d", "n"),
            "main"
        );
    }

    /// 工作树当前项置顶，其余按目录名排序，bare 被过滤。
    #[test]
    fn worktrees_sort_and_filter() {
        let mut list = vec![
            worktree("/w/zeta", Some("zeta")),
            worktree("/w/alpha", Some("alpha")),
            worktree("/w/current", Some("main")),
        ];
        let mut bare = worktree("/w/bare", Some("bare"));
        bare.is_bare = true;
        list.push(bare);
        let result = filtered_worktrees(&list, "/w/current", "");
        let paths: Vec<&str> = result.iter().map(|w| w.path.as_str()).collect();
        assert_eq!(paths, vec!["/w/current", "/w/alpha", "/w/zeta"]);
    }

    /// 工作树查询能按目录名 / 路径 / 分支 / 短 head 命中。
    #[test]
    fn worktrees_filter_by_multiple_fields() {
        let list = vec![
            worktree("/w/alpha-one", Some("feature/x")),
            worktree("/w/beta", Some("dev")),
        ];
        assert_eq!(filtered_worktrees(&list, "", "alpha").len(), 1);
        assert_eq!(filtered_worktrees(&list, "", "feature").len(), 1);
        assert_eq!(filtered_worktrees(&list, "", "abcdef1").len(), 2);
    }

    /// 建工作树路径：非空且不重复时才返回。
    #[test]
    fn create_worktree_path_rejects_duplicates() {
        let list = vec![worktree("/w/alpha", Some("alpha"))];
        assert_eq!(create_worktree_path(&list, ""), None);
        assert_eq!(create_worktree_path(&list, "/w/alpha"), None);
        assert_eq!(
            create_worktree_path(&list, " /w/new "),
            Some("/w/new".to_string())
        );
    }

    /// 仓库当前项置顶，其余按目录名排序并可按名称过滤。
    #[test]
    fn repositories_sort_and_filter() {
        let list = branches(&["/ws/zeta", "/ws/alpha", "/ws/current"]);
        let result = filtered_repositories(&list, Some("/ws/current"), "");
        assert_eq!(result, branches(&["/ws/current", "/ws/alpha", "/ws/zeta"]));
        assert_eq!(
            filtered_repositories(&list, Some("/ws/current"), "zeta"),
            branches(&["/ws/zeta"])
        );
    }

    /// 相对路径与目录名工具函数。
    #[test]
    fn path_helpers_match_windows_semantics() {
        assert_eq!(folder_name("/a/b/c"), "c");
        assert_eq!(folder_name("/a/b/c/"), "c");
        assert_eq!(relative_path("/ws/sub/repo", "/ws"), "sub/repo");
        assert_eq!(relative_path("/ws", "/ws"), "");
        assert_eq!(relative_path("/other/repo", "/ws"), "/other/repo");
    }

    /// 命令列表下标夹紧与移动（对齐 `clampCommandListIndex` / `moveCommandListIndex`）。
    #[test]
    fn command_index_clamps_and_moves_without_wrapping() {
        // 夹紧：越界回到边界，空列表恒为 0。
        assert_eq!(clamp_index(5, 3), 2);
        assert_eq!(clamp_index(0, 0), 0);
        // 向下到底停在最后一项，向上到顶停在第一项，不循环。
        assert_eq!(move_index(2, 3, true), 2);
        assert_eq!(move_index(0, 3, false), 0);
        assert_eq!(move_index(0, 3, true), 1);
        assert_eq!(move_index(2, 3, false), 1);
    }
}
