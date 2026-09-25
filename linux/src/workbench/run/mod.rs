//! Linux Run 与 Maven 执行边界。
//!
//! Core 负责配置文档、工具链需求和平台无关启动计划；本模块只负责
//! Linux 宿主侧的文档落盘、工具链解析和进程会话生命周期。

pub mod config;
pub mod process;

pub use config::{
    create_launch_plan_request, default_generated_configuration_id, list_java_sources,
    maven_context_for_configuration, parse_resolved_configurations, read_toolchain_paths,
    sequence_is_current, toolchain_candidates, write_generated_documents, write_toolchain_paths,
    LaunchPlan, RunConfigItem, ToolchainPaths,
};
pub use process::{ProcessEvent, ProcessManager};
