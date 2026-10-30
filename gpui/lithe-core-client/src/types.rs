//! 项目树与文件操作的客户端数据类型。
//!
//! 字段形状来自 Core 响应契约（`rust/lithe-core/src/protocol/contracts.rs`），
//! 所有结构体都带 `#[serde(rename_all = "camelCase")]`。其中
//! `WorkspaceNode` 的 `children` 在 Core 里是 `Option<Vec<WorkspaceNode>>`：
//! 未加载的目录/文件为 `null`（实际序列化时省略），已知空目录是 `[]`。
//! 公开 API 要求 `children: Vec<WorkspaceNode>`，因此用私有标志保留二者区别。

use serde::Deserialize;

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(from = "RawWorkspaceNode")]
/// 项目树中的一个文件或目录。
pub struct WorkspaceNode {
    /// 工作区相对路径，使用 `/` 分隔；根节点的 `path` 为空字符串。
    pub path: String,
    /// 展示名。
    pub name: String,
    /// 是否为目录。
    pub is_directory: bool,
    /// 子节点。未加载时为已说明的空列表，需配合 [`WorkspaceNode::children_loaded`]。
    pub children: Vec<WorkspaceNode>,
    /// `children` 是否来自 Core 的实际枚举结果。
    children_loaded: bool,
}

impl WorkspaceNode {
    /// 返回 Core 是否已经枚举过该节点的子项。
    ///
    /// `true` 表示 `children` 是可信结果：空列表代表“已知空目录”。
    /// `false` 表示子项尚未加载或该节点是文件，调用方应发起
    /// `workspace.listDirectories`。
    pub fn children_loaded(&self) -> bool {
        self.children_loaded
    }
}

/// Core 中 `children` 为 `Option` 的原始形状，用来区分 `null` 与 `[]`。
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawWorkspaceNode {
    #[serde(default)]
    path: String,
    #[serde(default)]
    name: String,
    #[serde(default)]
    is_directory: bool,
    #[serde(default)]
    children: Option<Vec<RawWorkspaceNode>>,
}

impl From<RawWorkspaceNode> for WorkspaceNode {
    fn from(raw: RawWorkspaceNode) -> Self {
        let children_loaded = raw.children.is_some();
        let children = raw
            .children
            .unwrap_or_default()
            .into_iter()
            .map(WorkspaceNode::from)
            .collect();
        Self {
            path: raw.path,
            name: raw.name,
            is_directory: raw.is_directory,
            children,
            children_loaded,
        }
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
/// `workspace.snapshot` 的完整结果。
pub struct WorkspaceSnapshot {
    /// 树根。`includeTree=false` 时 `root.children_loaded()` 为 false。
    pub root: WorkspaceNode,
    /// 扁平化的可见文件路径列表。
    #[serde(default)]
    pub files: Vec<String>,
    /// 位于自身仓库内部、被排除在树和文件列表之外的 linked worktree。
    #[serde(default)]
    pub nested_worktrees: Vec<String>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
/// `workspace.listDirectories` 中单个目录的结果。
///
/// Core 还会返回 `nestedWorktrees`；本轮公开契约不需要它，serde 默认忽略未知字段。
pub struct DirectoryListing {
    /// 规范化后的工作区相对路径；根目录为空字符串。
    pub path: String,
    /// 直接子项，目录在前、文件在后。
    pub children: Vec<WorkspaceNode>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
/// `file.read` 的结果。
pub struct FileReadResult {
    /// 规范化后的工作区相对路径。
    pub path: String,
    /// UTF-8 文本内容。
    pub text: String,
}

/// `workspace.listDirectories` 的响应外层：`{ "directories": [...] }`。
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct DirectoryListingResponse {
    pub(crate) directories: Vec<DirectoryListing>,
}

/// `file.write` 的响应外层；客户端只暴露写入字节数。
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct FileWriteResponse {
    pub(crate) bytes_written: usize,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn distinguishes_unloaded_children_from_known_empty_directory() {
        let node: WorkspaceNode =
            serde_json::from_str(r#"{"path":"src","name":"src","isDirectory":true,"children":[]}"#)
                .expect("node should decode");
        assert!(node.children_loaded());
        assert!(node.children.is_empty());

        let node: WorkspaceNode =
            serde_json::from_str(r#"{"path":"src","name":"src","isDirectory":true}"#)
                .expect("node should decode");
        assert!(!node.children_loaded());
        assert!(node.children.is_empty());
    }

    #[test]
    fn decodes_nested_snapshot() {
        let snapshot: WorkspaceSnapshot = serde_json::from_value(serde_json::json!({
            "root": {
                "path": "",
                "name": "project",
                "isDirectory": true,
                "children": [
                    {
                        "path": "src",
                        "name": "src",
                        "isDirectory": true
                    }
                ]
            },
            "files": ["src/Main.java"],
            "nestedWorktrees": []
        }))
        .expect("snapshot should decode");
        assert!(snapshot.root.children_loaded());
        assert_eq!(snapshot.root.children.len(), 1);
        assert!(!snapshot.root.children[0].children_loaded());
    }

    #[test]
    fn decodes_directory_listing_response() {
        let response: DirectoryListingResponse = serde_json::from_value(serde_json::json!({
            "directories": [
                {
                    "path": "src",
                    "children": [
                        {"path": "src/Main.java", "name": "Main.java", "isDirectory": false}
                    ],
                    "nestedWorktrees": []
                }
            ]
        }))
        .expect("listing should decode");
        assert_eq!(response.directories.len(), 1);
        assert_eq!(response.directories[0].children[0].path, "src/Main.java");
        assert!(!response.directories[0].children[0].is_directory);
    }
}
