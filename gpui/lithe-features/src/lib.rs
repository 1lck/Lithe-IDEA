//! Phase 0 工作台功能视图。
//!
//! 本 crate 只负责「视图 + 交互」：项目树、编辑器 WebView、欢迎页。业务规则
//! （文件枚举、读写）来自 `lithe-core-client`，平台能力来自 `lithe-platform`，
//! 颜色/字号/图标来自 `lithe-ui`。布局组装在 `lithe-workbench`，这里不感知
//! 顶栏、活动栏或分栏。
//!
//! 所有 Core 调用都是阻塞的，必须在 `cx.background_spawn` 里执行；视图线程
//! 只负责合并结果并 `notify`。

pub mod agent;
pub mod editor;
pub mod git;
pub mod local_history;
pub mod markdown_preview;
pub mod memory;
pub mod quick_open;
pub mod run;
pub mod search;
pub mod settings;
pub mod terminal;
pub mod welcome;
pub mod workspace;

pub use agent::AgentPanel;
pub use editor::EditorSurface;
pub use git::GitPanel;
pub use markdown_preview::MarkdownPreview;
pub use memory::{format_memory, process_memory_bytes};
pub use quick_open::{QuickFile, filter_files, index_project};
pub use run::{RunPanel, RunPanelEvent};
pub use search::SearchPanel;
pub use settings::{AppSettings, SettingsView};
pub use terminal::TerminalPanel;
pub use welcome::WelcomeView;
pub use workspace::ProjectTree;
