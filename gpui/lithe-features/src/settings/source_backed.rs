//! Source-backed 设置的公共助手。
//!
//! Tauri 的 Git 执行/身份、用户级 Maven、Project 冲突保护都遵循同一模式：
//! 「发现 → 回显 → 草稿 → 确认写入 → 回读」，并在写入前校验来源没有并发
//! 变化（expectedValues / revision）。这里抽出一个不做过度泛化的通用形状，
//! 各页允许在它之上微调。
//!
//! 写入口一律经 `CoreClient::execute_raw` / 文件读写 + `background_spawn`，
//! 用调用方的 generation 丢弃过期结果（见 plan-00 §5.1）。

use std::path::Path;

/// 一个 Source-backed 字段的草稿状态。
///
/// - `loaded`：从真实来源读到的当前生效值；`None` 表示来源缺失或尚未发现
///   （例如仓库未初始化、settings.xml 不存在）。
/// - `draft`：用户正在编辑的值。
/// - `dirty`：草稿与生效值不同，允许应用。
/// - `revision`：并发保护令牌。Git 执行设置用「生效 fetch 选项 + 配置值」
///   快照，用户级 Maven 用「文件 mtime + 内容 hash」；apply 前重读来源，
///   不一致即视为冲突。
/// - `error`：读取或写入错误。
#[derive(Clone, Debug, Default)]
pub(super) struct SourceDraft {
    loaded: Option<String>,
    draft: String,
    dirty: bool,
    revision: Option<String>,
    error: Option<String>,
}

impl SourceDraft {
    pub(super) fn new() -> Self {
        Self::default()
    }

    /// 用发现结果整体替换：回显生效值并重置草稿。
    pub(super) fn replace_loaded(&mut self, loaded: Option<String>, revision: Option<String>) {
        self.loaded = loaded.clone();
        self.draft = loaded.unwrap_or_default();
        self.dirty = false;
        self.revision = revision;
        self.error = None;
    }

    /// 只更新草稿；与生效值相同则视为不脏。
    pub(super) fn set_draft(&mut self, value: String) {
        self.draft = value;
        self.dirty = self.draft.trim() != self.loaded.as_deref().unwrap_or("").trim();
    }

    pub(super) fn loaded(&self) -> Option<&str> {
        self.loaded.as_deref()
    }

    pub(super) fn draft(&self) -> &str {
        &self.draft
    }

    pub(super) fn dirty(&self) -> bool {
        self.dirty
    }

    pub(super) fn revision(&self) -> Option<&str> {
        self.revision.as_deref()
    }

    pub(super) fn error(&self) -> Option<&str> {
        self.error.as_deref()
    }

    pub(super) fn set_error(&mut self, error: Option<String>) {
        self.error = error;
    }

    /// apply 前校验：来源令牌仍然是发现时的值才算干净。
    pub(super) fn check_revision(&mut self, current_revision: Option<&str>) -> Result<(), String> {
        if self.revision.as_deref() == current_revision {
            Ok(())
        } else {
            Err(CONFLICT_MESSAGE.to_string())
        }
    }

    /// 写入成功后的回读收尾：把新值当作生效值。
    pub(super) fn commit_applied(&mut self, applied: String, revision: Option<String>) {
        self.loaded = Some(applied.clone());
        self.draft = applied;
        self.dirty = false;
        self.revision = revision;
        self.error = None;
    }
}

/// 冲突提示文案的英文 key；调用方负责 `tr`。
pub(super) const CONFLICT_MESSAGE: &str =
    "The source changed since it was loaded. Reload and try again.";

/// 「文件 mtime 秒 + 内容长度」级别的轻量 revision；用于用户级 settings.xml。
///
/// 不引入哈希依赖：同秒内的并发写冲突概率极低，且 apply 前还会比对内容
/// 长度变化；更严格的校验交给调用方按需扩展。
pub(super) fn file_revision(path: &Path) -> Option<String> {
    let metadata = std::fs::metadata(path).ok()?;
    let modified = metadata
        .modified()
        .ok()
        .and_then(|time| time.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|duration| duration.as_secs())
        .unwrap_or(0);
    Some(format!("{}:{}", modified, metadata.len()))
}

/// 从文本中提取一个 `mtime:len` revision，配合 [`file_revision`] 使用。
pub(super) fn text_revision(text: &str) -> String {
    format!("len:{}", text.len())
}
