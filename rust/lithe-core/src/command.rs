use serde::Deserialize;
use serde_json::Value;

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CoreRequest {
    #[serde(default)]
    pub id: Option<String>,
    pub command: String,
    #[serde(default)]
    pub payload: Value,
}

#[derive(Debug, Clone)]
pub enum CoreCommand {
    Ping,
    WorkspaceSnapshot,
    WorkspaceSearch,
    FileRead,
    FileWrite,
    GitStatus,
}

impl CoreCommand {
    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "core.ping" => Some(Self::Ping),
            "workspace.snapshot" => Some(Self::WorkspaceSnapshot),
            "workspace.search" => Some(Self::WorkspaceSearch),
            "file.read" => Some(Self::FileRead),
            "file.write" => Some(Self::FileWrite),
            "git.status" => Some(Self::GitStatus),
            _ => None,
        }
    }
}
