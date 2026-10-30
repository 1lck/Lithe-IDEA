//! 运行工具窗：配置发现、进程会话和 Run 面板。
//!
//! 业务规则来自 Core 的 `runConfig.*` 命令；本模块只负责把配置呈现给用户、
//! 启动/停止本机进程，并把输出与状态同步回视图。

mod config;
mod model;
mod session;
mod view;

pub use model::{RunConfiguration, RunDiagnostic, RunExecution, RunScope};
pub use session::SessionEvent;
pub use view::{RunPanel, RunPanelEvent};
