//! 快速打开（Quick Open）的纯逻辑层。
//!
//! 工作台的快速打开面板需要一份项目内所有文件的扁平索引，再按输入实时过滤。
//! 这里只做磁盘枚举和字符串匹配，不依赖 GPUI：视图线程可以在
//! `background_spawn` 里调用 [`index_project`]，把结果存进面板状态；输入变化
//! 时调用 [`filter_files`]，返回借用索引的条目，避免每次按键都复制路径。
//!
//! 索引是「打开面板时扫一次」的快照，不监听文件系统变化。文件枚举的真源仍是
//! 项目树（Core），索引过期时重新扫描即可，不需要增量协议。

use std::ffi::{OsStr, OsString};
use std::path::{Component, Path, PathBuf};

/// 索引时整段跳过的目录名（大小写不敏感）。
///
/// 这些目录要么是版本控制/构建工具的内部状态（`.git`、`target`、`build`、
/// `dist`、`.gradle`、`__pycache__`），要么是体积远超源码的第三方依赖
/// （`node_modules`、`.venv`、`vendor`）。它们的文件数常常是源码的几十倍，
/// 参与索引既拖慢首次扫描，又会让快速打开的结果被依赖和产物文件淹没。
const SKIPPED_DIRECTORIES: &[&str] = &[
    ".artifacts",
    ".git",
    ".gradle",
    ".hg",
    ".idea",
    ".mypy_cache",
    ".next",
    ".nuxt",
    ".pytest_cache",
    ".svn",
    ".tox",
    ".venv",
    "Pods",
    "__pycache__",
    "build",
    "coverage",
    "dist",
    "node_modules",
    "obj",
    "out",
    "target",
    "vendor",
    "venv",
];

/// 单次过滤最多检查的候选数。
///
/// 快速打开每次按键都会重新过滤；索引可能有几万条，全部做子序列匹配会让大
/// 项目在输入时掉帧。两万条足够覆盖常见项目，超出部分只在极端大仓库里被
/// 截断，属于可接受的体验取舍。
const MAX_SCAN: usize = 20_000;

/// 单次索引的最大目录深度。
///
/// 符号链接在遍历时已经跳过；这里再兜一层，防止 Windows junction 等重解析
/// 点形成的环让待访问栈无限增长。
const MAX_INDEX_DEPTH: usize = 64;

/// 一个可快速打开的项目文件。
#[derive(Clone, Debug)]
pub struct QuickFile {
    /// 相对项目根的路径，用 `/` 分隔，供显示和匹配。
    pub relative: String,
    /// 磁盘上的绝对路径，打开时直接使用。
    pub absolute: PathBuf,
}

/// 递归索引项目文件。
///
/// - 跳过 `.git`、`node_modules`、`target`、`dist`、`build`、`.idea`、`.gradle`、
///   `.venv`、`__pycache__`、`.artifacts` 等目录；
/// - 只收普通文件，符号链接不跟随（避免环）；
/// - 超过 `limit` 个文件立即停止，保证打开大项目不卡；
/// - 读目录失败只跳过该目录，不 panic；
/// - 返回按 `relative` 排序的结果。
pub fn index_project(root: &Path, limit: usize) -> Vec<QuickFile> {
    // 空路径表示「还没有打开项目」，绝不能退化成扫描当前目录。
    if limit == 0 || root.as_os_str().is_empty() {
        return Vec::new();
    }

    // 只补全成绝对路径，不做 `canonicalize`：后者会解析符号链接且要求路径
    // 存在，而索引期间目录本身可能正被删除或重命名，没必要因此整体失败。
    let root = std::path::absolute(root).unwrap_or_else(|_| root.to_path_buf());

    let mut files = Vec::new();
    // 显式栈代替递归：超深目录不会撑爆调用栈，也便于加深度上限。
    let mut pending = vec![(root.clone(), 0usize)];

    while let Some((directory, depth)) = pending.pop() {
        if files.len() >= limit {
            break;
        }
        let Ok(entries) = std::fs::read_dir(&directory) else {
            // 目录在扫描期间被删除，或当前用户没有权限：只跳过这一层，
            // 其余目录继续索引，快速打开不应因个别目录失败而整个不可用。
            continue;
        };

        let mut children: Vec<(OsString, PathBuf, bool)> = Vec::new();
        for entry in entries {
            let Ok(entry) = entry else { continue };
            // `DirEntry::file_type` 取自目录项本身，不跟随符号链接，
            // 所以这里拿到的是链接自身的类型。
            let Ok(file_type) = entry.file_type() else {
                continue;
            };
            if file_type.is_symlink() {
                continue;
            }
            let is_directory = file_type.is_dir();
            if !is_directory && !file_type.is_file() {
                // 设备、管道、socket 不是可打开的源码文件。
                continue;
            }
            children.push((entry.file_name(), entry.path(), is_directory));
        }

        // 目录项顺序由文件系统决定；先按名字排序，保证 `limit` 截断时
        // 不同平台留下的是同一批文件，索引结果可复现。
        children.sort_by(|left, right| left.0.cmp(&right.0));

        let mut subdirectories = Vec::new();
        for (name, path, is_directory) in children {
            if is_directory {
                if !is_skipped_directory(&name) && depth < MAX_INDEX_DEPTH {
                    subdirectories.push((path, depth + 1));
                }
                continue;
            }
            if files.len() >= limit {
                break;
            }
            let Some(relative) = relative_string(&root, &path) else {
                continue;
            };
            files.push(QuickFile {
                relative,
                absolute: path,
            });
        }

        // 反转后压栈，弹出顺序才与目录内的名字排序一致。
        pending.extend(subdirectories.into_iter().rev());
    }

    files.sort_by(|left, right| left.relative.cmp(&right.relative));
    files
}

/// 按查询过滤，返回最多 `limit` 条。
///
/// 匹配规则（大小写不敏感）：
/// 1. `query` 为空：按原顺序返回前 `limit` 条；
/// 2. 优先子串匹配（文件名命中 > 路径命中）；
/// 3. 其次子序列匹配（例如 `wbr` 命中 `workbench.rs`）；
/// 4. 软上限：单次最多扫描两万条，避免超大项目卡帧。
pub fn filter_files<'a>(files: &'a [QuickFile], query: &str, limit: usize) -> Vec<&'a QuickFile> {
    if limit == 0 || files.is_empty() {
        return Vec::new();
    }

    // 首尾空白多来自输入框误触，直接忽略；空查询保持索引顺序。
    let query = query.trim();
    if query.is_empty() {
        return files.iter().take(limit).collect();
    }

    let needle = query.to_lowercase();
    // 四个桶按优先级从高到低；桶内保持索引顺序（索引本身已按路径排序）。
    let mut name_substring = Vec::new();
    let mut path_substring = Vec::new();
    let mut name_subsequence = Vec::new();
    let mut path_subsequence = Vec::new();

    for file in files.iter().take(MAX_SCAN) {
        let name = file_name(&file.relative);
        if contains_ignore_case(name, &needle) {
            name_substring.push(file);
        } else if contains_ignore_case(&file.relative, &needle) {
            path_substring.push(file);
        } else if is_subsequence(name, &needle) {
            name_subsequence.push(file);
        } else if is_subsequence(&file.relative, &needle) {
            path_subsequence.push(file);
        }

        // 文件名子串是最高层级；凑满 limit 后再扫描也不会改变结果。
        if name_substring.len() >= limit {
            break;
        }
    }

    let mut matches = name_substring;
    append_matches(&mut matches, path_substring, limit);
    append_matches(&mut matches, name_subsequence, limit);
    append_matches(&mut matches, path_subsequence, limit);
    matches
}

/// 把 `source` 中剩余的条目补到 `target`，总数不超过 `limit`。
fn append_matches<'a>(target: &mut Vec<&'a QuickFile>, source: Vec<&'a QuickFile>, limit: usize) {
    if target.len() >= limit {
        return;
    }
    let remaining = limit - target.len();
    target.extend(source.into_iter().take(remaining));
}

/// 目录名是否属于被跳过的构建/依赖目录。
fn is_skipped_directory(name: &OsStr) -> bool {
    let Some(name) = name.to_str() else {
        // 非 UTF-8 目录名不可能命中这些已知名字，按普通目录处理。
        return false;
    };
    SKIPPED_DIRECTORIES
        .iter()
        .any(|skipped| name.eq_ignore_ascii_case(skipped))
}

/// 把 `path` 相对 `root` 的部分转成 `/` 分隔的字符串。
///
/// 非 UTF-8 文件名无法稳定显示和匹配，直接跳过；这类文件在快速打开里也没有
/// 可靠的方式展示给用户。
fn relative_string(root: &Path, path: &Path) -> Option<String> {
    let relative = path.strip_prefix(root).ok()?;
    let mut result = String::new();
    for component in relative.components() {
        let Component::Normal(part) = component else {
            continue;
        };
        let part = part.to_str()?;
        if !result.is_empty() {
            result.push('/');
        }
        result.push_str(part);
    }
    (!result.is_empty()).then_some(result)
}

/// 取相对路径中的文件名部分。
fn file_name(relative: &str) -> &str {
    match relative.rsplit_once('/') {
        Some((_, name)) => name,
        None => relative,
    }
}

/// 大小写不敏感的子串判断。
///
/// `needle_lower` 必须是已经小写化的查询串。ASCII 走字节窗口比较，不分配；
/// 只有非 ASCII 才退化成小写副本，常见代码路径不会触发分配。
fn contains_ignore_case(haystack: &str, needle_lower: &str) -> bool {
    if needle_lower.is_empty() {
        return true;
    }
    if haystack.is_ascii() && needle_lower.is_ascii() {
        if haystack.len() < needle_lower.len() {
            return false;
        }
        // 按字节滑动不会把 UTF-8 多字节序列切成半个字符：非 ASCII 字节
        // 都 >= 0x80，而 ASCII 查询串里没有这样的字节。
        return haystack
            .as_bytes()
            .windows(needle_lower.len())
            .any(|window| window.eq_ignore_ascii_case(needle_lower.as_bytes()));
    }
    haystack.to_lowercase().contains(needle_lower)
}

/// 大小写不敏感的子序列判断，例如 `wbr` 命中 `workbench.rs`。
///
/// `needle_lower` 同样必须已经小写化。
fn is_subsequence(haystack: &str, needle_lower: &str) -> bool {
    if needle_lower.is_empty() {
        return true;
    }
    if haystack.is_ascii() && needle_lower.is_ascii() {
        let mut wanted = needle_lower.bytes();
        let mut next = wanted.next();
        for byte in haystack.bytes() {
            let Some(target) = next else { break };
            if byte.eq_ignore_ascii_case(&target) {
                next = wanted.next();
            }
        }
        return next.is_none();
    }

    let haystack = haystack.to_lowercase();
    let mut candidates = haystack.chars();
    needle_lower
        .chars()
        .all(|target| candidates.any(|candidate| candidate == target))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 构造一个不落到真实磁盘的索引项。
    fn indexed(relative: &str) -> QuickFile {
        QuickFile {
            relative: relative.to_string(),
            absolute: PathBuf::from("project").join(relative),
        }
    }

    fn relatives<'a>(files: &[&'a QuickFile]) -> Vec<&'a str> {
        files.iter().map(|file| file.relative.as_str()).collect()
    }

    #[test]
    fn empty_query_returns_first_entries_in_index_order() {
        let files = vec![indexed("a.rs"), indexed("b.rs"), indexed("src/c.rs")];
        assert_eq!(relatives(&filter_files(&files, "", 2)), ["a.rs", "b.rs"]);
        // 纯空白等同于空查询，避免输入框里一个空格就把结果全部过滤掉。
        assert_eq!(relatives(&filter_files(&files, "   ", 2)), ["a.rs", "b.rs"]);
    }

    #[test]
    fn substring_match_beats_subsequence_match() {
        let files = vec![indexed("src/workbench.rs"), indexed("docs/wbr.txt")];
        // `workbench.rs` 只是子序列命中，`wbr.txt` 是文件名子串命中。
        assert_eq!(
            relatives(&filter_files(&files, "wbr", 10)),
            ["docs/wbr.txt", "src/workbench.rs"]
        );
    }

    #[test]
    fn file_name_substring_beats_path_substring() {
        let files = vec![indexed("src/core/mod.rs"), indexed("core_notes.md")];
        assert_eq!(
            relatives(&filter_files(&files, "core", 10)),
            ["core_notes.md", "src/core/mod.rs"]
        );
    }

    #[test]
    fn matching_is_case_insensitive() {
        let files = vec![indexed("README.md"), indexed("Src/Main.RS")];
        assert_eq!(
            relatives(&filter_files(&files, "readme", 10)),
            ["README.md"]
        );
        assert_eq!(
            relatives(&filter_files(&files, "MAIN", 10)),
            ["Src/Main.RS"]
        );
        // 子序列路径也要坚持大小写不敏感。
        assert_eq!(relatives(&filter_files(&files, "smr", 10)), ["Src/Main.RS"]);
    }

    #[test]
    fn limit_caps_the_returned_matches() {
        let files: Vec<QuickFile> = (0..10)
            .map(|index| indexed(&format!("f{index}.rs")))
            .collect();
        let result = filter_files(&files, "f", 3);
        assert_eq!(relatives(&result), ["f0.rs", "f1.rs", "f2.rs"]);
        // limit 为 0 时不需要任何匹配。
        assert!(filter_files(&files, "f", 0).is_empty());
        assert!(filter_files(&files, "zzz", 3).is_empty());
    }

    #[test]
    fn scan_is_capped_at_the_documented_budget() {
        let mut files: Vec<QuickFile> = (0..MAX_SCAN)
            .map(|index| indexed(&format!("src/module_{index}.rs")))
            .collect();
        // 命中项排在扫描预算之外，不应被返回。
        files.push(indexed("src/zz_target.rs"));
        assert!(filter_files(&files, "zz_target", 10).is_empty());
        // 预算内的命中仍然正常。
        assert_eq!(
            relatives(&filter_files(&files, "module_1", 1)),
            ["src/module_1.rs"]
        );
    }

    #[test]
    fn missing_root_and_zero_limit_produce_no_index() {
        // 两条提前返回路径都不访问磁盘，因此测试不依赖真实目录。
        assert!(index_project(Path::new(""), 100).is_empty());
        assert!(index_project(Path::new("."), 0).is_empty());
    }
}
