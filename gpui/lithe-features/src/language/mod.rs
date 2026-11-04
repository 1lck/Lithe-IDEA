//! 语言服务：Java 语言服务器会话与应用级准备状态。
//!
//! 结构与 macOS 一致：会话负责启动/轮询 Core，模型持有每个工作区的快照，
//! 状态栏与 Run 面板只消费同一份快照。

pub mod java;
pub mod problems;
pub mod status;

mod diagnostics;

pub use java::{
    JavaBuildFailure, JavaBuildReport, JavaLanguageServiceEvent, JavaLanguageServiceModel,
    JavaLaunchTarget,
};
pub use problems::{PreviewFailure, ProblemPreview, ProblemsPanelState, ProblemsScope};
