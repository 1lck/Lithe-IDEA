//! Lithe Core 的 GPUI 宿主客户端。
//!
//! 所有业务能力来自 `../rust/lithe-core`，本 crate 只负责：
//!
//! - 用真实命令名与 camelCase payload 构造请求；
//! - 调用 `lithe_core::execute_json`；
//! - 解析 `{ id, ok, data, error }` 外层；
//! - 把结果映射成工作台可直接消费的类型。
//!
//! # 阻塞约定
//!
//! [`CoreClient`] 的所有方法都是同步阻塞调用。界面代码必须通过
//! `cx.background_spawn` 或独立后台线程调用，不能阻塞 GPUI 渲染线程。

pub mod client;
pub mod command;
pub mod error;
pub mod response;
pub mod types;

pub use client::CoreClient;
pub use command::CoreCommand;
pub use error::CoreError;
pub use response::CoreResponse;
pub use types::{DirectoryListing, FileReadResult, WorkspaceNode, WorkspaceSnapshot};
