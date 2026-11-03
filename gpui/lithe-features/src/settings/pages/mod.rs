//! 设置页的逐页渲染与写入方法。
//!
//! 每个文件对应一个（或一组 closely 相关的）设置页：渲染函数 + 该页专属的
//! 设置写入方法。页面只访问 [`SettingsView`](super::super::SettingsView) 的
//! 私有字段——子模块对 defining module 的字段保持可见，与拆分前行为一致。

pub(super) mod ai;
pub(super) mod ai_commit;
pub(super) mod agents;
pub(super) mod declarative;
pub(super) mod editor;
pub(super) mod general;
pub(super) mod git;
pub(super) mod hooks;
pub(super) mod keymap;
pub(super) mod lsp;
pub(super) mod logs;
pub(super) mod mcp;
pub(super) mod plugins;
pub(super) mod process;
pub(super) mod project;
pub(super) mod run;
pub(super) mod terminal;
pub(super) mod updates;
