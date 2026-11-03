//! 搜索面板的替换执行与统计。
//!
//! 匹配语义（大小写、整词、正则捕获组）全部由 Core 的
//! `workspace.replacePreview` 决定；本模块只把预览结果写回磁盘，并按文件累计
//! 成功与失败。视图层因此不需要复制任何匹配规则，替换结果与搜索结果一致。

use std::path::Path;

use lithe_core_client::CoreClient;
use serde_json::{Value, json};

use super::SearchOptions;

/// 一次替换操作的统计数据。
///
/// `matches` 按 Core 返回的 `occurrenceCount` 累加，而不是按行或按文件计数，
/// 与 Tauri 侧「替换了多少处匹配」的口径一致。
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(super) struct ReplaceOutcome {
    /// 实际改写的匹配数。
    pub matches: usize,
    /// 预览、读取或写回失败的文件数。
    pub failed: usize,
}

/// 在后台执行一次替换：用 Core 的预览算出替换后的全文，再写回磁盘。
///
/// `only_line` 为 `Some(line)` 时只应用该行的替换（「替换」按钮），为 `None`
/// 时应用整个文件的预览结果（「替换全部」）。
///
/// 单个文件失败不会中断其它文件，失败数记录在 [`ReplaceOutcome::failed`]；
/// 只有预览本身失败（例如正则非法）才返回 `Err`，此时没有写入任何文件。
/// 阻塞调用，调用方必须放在 `cx.background_spawn` 中。
pub(super) fn replace_paths(
    client: CoreClient,
    root: &Path,
    root_string: &str,
    query: &str,
    replacement: &str,
    options: SearchOptions,
    paths: &[String],
    only_line: Option<u32>,
) -> Result<ReplaceOutcome, String> {
    let payload = json!({
        "root": root_string,
        "query": query,
        "replacement": replacement,
        "caseSensitive": options.case_sensitive,
        "wholeWords": options.whole_words,
        "regularExpression": options.regular_expression,
        "paths": paths,
        "fileMask": "",
    });
    let data = client
        .execute_raw("workspace.replacePreview", payload)
        .map_err(|error| error.to_string())?;

    let Some(files) = data.get("files").and_then(Value::as_array) else {
        return Ok(ReplaceOutcome::default());
    };

    let mut outcome = ReplaceOutcome::default();
    for file in files {
        let Some(path) = file.get("path").and_then(Value::as_str) else {
            outcome.failed += 1;
            continue;
        };
        match only_line {
            Some(target_line) => {
                replace_line(client, root, path, file, target_line, &mut outcome);
            }
            None => replace_file(client, root, path, file, &mut outcome),
        }
    }

    Ok(outcome)
}

/// 「替换」按钮：只改选中行，避免同文件其它匹配一起变化。
fn replace_line(
    client: CoreClient,
    root: &Path,
    path: &str,
    file: &Value,
    target_line: u32,
    outcome: &mut ReplaceOutcome,
) {
    let target = file
        .get("matches")
        .and_then(Value::as_array)
        .and_then(|matches| {
            matches.iter().find(|item| {
                item.get("line")
                    .and_then(Value::as_u64)
                    .map(|line| line as u32 == target_line)
                    .unwrap_or(false)
            })
        });
    let Some(target) = target else {
        // 预览里已经没有该行（例如搜索后文件被外部修改）。
        outcome.failed += 1;
        return;
    };
    let (Some(before_line), Some(after_line)) = (
        target.get("before").and_then(Value::as_str),
        target.get("after").and_then(Value::as_str),
    ) else {
        outcome.failed += 1;
        return;
    };
    if before_line == after_line {
        return;
    }

    let current = match client.read_file(root, path) {
        Ok(read) => read.text,
        Err(_) => {
            outcome.failed += 1;
            return;
        }
    };
    let Some(next) = match_line_replacement(&current, target_line, before_line, after_line) else {
        outcome.failed += 1;
        return;
    };
    if client.write_file(root, path, &next).is_err() {
        outcome.failed += 1;
        return;
    }
    outcome.matches += occurrence_count(target);
}

/// 「替换全部」按钮：写回 Core 为整个文件生成的预览文本。
fn replace_file(
    client: CoreClient,
    root: &Path,
    path: &str,
    file: &Value,
    outcome: &mut ReplaceOutcome,
) {
    let Some(replacement_text) = file.get("replacement_text").and_then(Value::as_str) else {
        outcome.failed += 1;
        return;
    };
    let changed = changed_match_count(file);
    if changed == 0 {
        // 替换文本与原文件等价（例如替换内容等于匹配内容），无需写盘。
        return;
    }
    if client.write_file(root, path, replacement_text).is_err() {
        outcome.failed += 1;
        return;
    }
    outcome.matches += changed;
}

/// 统计预览里真正发生变化的匹配数。
///
/// Core 的每个匹配同时给出 `before` / `after` 整行；两行相同说明该行没有变化，
/// 不计入「已替换」。缺少 `matches` 时按 1 处理，保证预览文本仍会被写回。
fn changed_match_count(file: &Value) -> usize {
    let Some(matches) = file.get("matches").and_then(Value::as_array) else {
        return 1;
    };
    if matches.is_empty() {
        return 1;
    }
    matches
        .iter()
        .filter(|item| {
            let before = item.get("before").and_then(Value::as_str).unwrap_or_default();
            let after = item.get("after").and_then(Value::as_str).unwrap_or_default();
            before != after
        })
        .map(occurrence_count)
        .sum()
}

/// Core 的 `occurrenceCount` 表示同一行里命中的次数；缺失时至少算 1 处。
fn occurrence_count(item: &Value) -> usize {
    item.get("occurrenceCount")
        .and_then(Value::as_u64)
        .map(|count| count as usize)
        .unwrap_or(1)
}

/// 把源文本里的 `target_line` 整行替换成 `after_line`。
///
/// 只有该行内容仍等于预览时的 `before_line` 才替换，避免文件在预览与写回之间
/// 被外部修改后覆盖用户的新内容。行号缺失或越界时返回 `None`。
fn match_line_replacement(
    text: &str,
    target_line: u32,
    before_line: &str,
    after_line: &str,
) -> Option<String> {
    let target_index = usize::try_from(target_line.checked_sub(1)?).ok()?;
    let mut lines: Vec<&str> = text.split('\n').collect();
    let current = lines.get(target_index)?;
    // Core 的 `before` 是原始行（未 trim），这里要求逐字节相等才覆盖。
    if *current != before_line {
        return None;
    }
    lines[target_index] = after_line;
    Some(lines.join("\n"))
}
