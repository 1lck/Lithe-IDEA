//! 运行工具窗：配置发现、进程会话和 Run 面板。
//!
//! 业务规则来自 Core 的 `runConfig.*` 命令；本模块只负责把配置呈现给用户、
//! 启动/停止本机进程，并把输出与状态同步回视图。

pub(crate) mod config;
pub(crate) mod model;
/// 供 Maven 工具窗复用 `project-maven` 工具链与 Windows 命令包装。
pub(crate) mod session;
pub(crate) mod toolchain;
mod view;

pub use model::{
    PreparationPhase, PreparationStatus, ProjectPreparation, RunConfiguration, RunDiagnostic,
    RunEditorOptions, RunExecution, RunLanguage, RunSaveScope, RunScope, RunToolchainPaths,
};
pub use session::SessionEvent;
pub use view::{RunPanel, RunPanelEvent};
