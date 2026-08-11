use serde::{Deserialize, Serialize};

/// How a configuration behaves once started.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Execution {
    Application,
    Service,
    Task,
    Group,
}

impl Default for Execution {
    fn default() -> Self {
        Self::Application
    }
}

/// How the configuration was discovered. Higher values win deduplication.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Confidence {
    Heuristic,
    Declared,
    Native,
}

impl Default for Confidence {
    fn default() -> Self {
        Self::Declared
    }
}
