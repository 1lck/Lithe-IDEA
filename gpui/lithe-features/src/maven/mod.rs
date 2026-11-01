//! Maven 工具窗：项目树、生命周期执行和构建输出。
//!
//! 交互对齐 Windows/Tauri 的 `features/maven`（Maven 面板的 SSOT）：
//!
//! - **Maven 面板**（右侧停靠）：标题栏下方是动作工具条，主体是
//!   Profiles / 项目 → 源码根 → 生命周期 → 依赖项 → 子模块 的树。
//!   模块节点的右键菜单提供运行 / 测试 / 打包 / 执行 Goal / 打开 pom.xml。
//! - **Maven 输出**（底部停靠）：生命周期任务的进程输出、诊断与测试汇总，
//!   由 Maven 面板的「构建输出」按钮打开。
//!
//! # 数据边界
//!
//! 项目模型、依赖树、诊断与测试结果全部来自共享 Core 的 `maven.scan`、
//! `maven.dependencies`、`maven.diagnostics` 和 `maven.testResults`；本模块
//! 只做 camelCase 反序列化，不复制 Core 的解析规则。Core 不拉起 Maven——
//! `maven.launchPlan` / `maven.dependencyPlan` 只返回启动计划，真实进程由
//! `session.rs` 通过 `lithe-git-host::ProcessTree` 执行。
//!
//! # 异步
//!
//! 所有 Core 调用都是阻塞的，必须放在 `cx.background_spawn` / 后台线程；
//! 结果经 `this.update` 回到视图线程。`generation` 在 `set_root` / 刷新时
//! 递增，丢弃旧工作区仍在飞行中的结果。构造期不发起任务，首次加载由
//! `Render` 里的 `defer_in` 排到当前 App 借用释放之后。

pub mod configuration;
use std::path::{Path, PathBuf};

mod model;
mod output;
mod session;
mod view;

pub use model::{
    DEFAULT_PHASE, Dependency, DependencyLoad, DependencyResolution, LIFECYCLE_PHASES,
    LaunchContext, MavenProject, Module, Profile, ProjectStatus, SourceRoot, SourceRootKind,
    TaskStatus,
};
pub use output::MavenOutputPanel;
pub use session::{Diagnostic, DiagnosticSeverity, SessionEvent, TestFailure, TestResults};
pub use view::{MavenPanel, MavenPanelEvent};

/// 检测本机 Maven 可执行文件（无保存覆盖时的解析结果）。
///
/// 与启动路径使用同一解析（wrapper → 安装 → PATH），保证设置页展示的
/// 「检测到」值与实际启动使用的可执行文件一致。
pub(crate) fn detected_maven_executable(root: &Path, working_directory: &Path) -> Option<String> {
    crate::run::session::resolve_toolchain(root, working_directory, "project-maven", None)
        .ok()
        .map(|path| path.to_string_lossy().into_owned())
}
