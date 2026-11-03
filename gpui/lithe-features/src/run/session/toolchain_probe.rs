//! 本机工具链候选探测。
//!
//! 读取项目 `.lithe/toolchains/requirements.json`，只为声明过的工具链探测
//! 版本，随 `runConfig.resolve` 一起上报给 Core。

use std::path::Path;
use std::process::{Command, Stdio};

use serde_json::{Value, json};

use super::resolve_toolchain;

/// 一种工具链的探测方式。
///
/// `id` 必须和 Core `.lithe/toolchains/requirements.json` 里的 id 完全一致：Core 只在
/// 候选里找到「同 id + 同 type」的条目时才认为该工具链已选择，否则对每条
/// requirement 都报 `missingToolchain`。`type` 始终取 requirement 声明的值。
struct ToolchainProbe {
    id: &'static str,
    command: &'static str,
    version_arguments: &'static [&'static str],
}

/// 宿主能上报的工具链候选，覆盖 Core 生成 requirement 时会用到的 id。
const TOOLCHAIN_PROBES: &[ToolchainProbe] = &[
    ToolchainProbe {
        id: "project-jdk",
        command: "java",
        version_arguments: &["-version"],
    },
    ToolchainProbe {
        id: "project-maven",
        command: "mvn",
        version_arguments: &["-v"],
    },
    ToolchainProbe {
        id: "project-gradle",
        command: "gradle",
        version_arguments: &["--version"],
    },
    ToolchainProbe {
        id: "project-node",
        command: "node",
        version_arguments: &["--version"],
    },
    ToolchainProbe {
        id: "project-python",
        command: "python",
        version_arguments: &["--version"],
    },
    ToolchainProbe {
        id: "project-rust",
        command: "cargo",
        version_arguments: &["--version"],
    },
    ToolchainProbe {
        id: "project-go",
        command: "go",
        version_arguments: &["version"],
    },
];

/// 本机工具链候选，随 `runConfig.resolve` 一起上报。
///
/// Core 只把「候选里存在同 id + 同 type」的 requirement 视为已选择；宿主不报候选
/// 时，即使机器上装了 JDK，每个 Java 配置都会报 “No local java toolchain is
/// selected”。这里读取 `.lithe/toolchains/requirements.json`，只为声明过的工具链
/// 探测，避免每次刷新都为全部工具拉起子进程；requirements 不存在时 Core 本来也
/// 不会产出工具链诊断。
pub(crate) fn toolchain_candidates(root: &Path) -> Vec<Value> {
    let Some(requirements) = read_toolchain_requirements(root) else {
        return Vec::new();
    };

    let mut candidates = Vec::new();
    for (id, kind, needs_version) in requirements {
        let Some((command, version_arguments)) = probe_for(&id) else {
            continue;
        };
        let Ok(executable) = resolve_toolchain(root, root, &id, Some(command.as_str())) else {
            continue;
        };
        // 版本只在 requirement 声明了版本约束时探测：没有约束时 Core 不比较版本。
        let version = if needs_version {
            toolchain_version(&executable, &kind, version_arguments)
        } else {
            String::new()
        };
        candidates.push(json!({
            "id": id,
            "type": kind,
            "version": version,
            "vendor": "",
        }));
    }
    candidates
}

/// 读取 requirements 里的 `(id, type, 是否声明版本约束)`。
fn read_toolchain_requirements(root: &Path) -> Option<Vec<(String, String, bool)>> {
    let path = root
        .join(".lithe")
        .join("toolchains")
        .join("requirements.json");
    let text = std::fs::read_to_string(path).ok()?;
    let document: Value = serde_json::from_str(&text).ok()?;
    let toolchains = document.get("toolchains")?.as_object()?;

    let mut entries = Vec::new();
    for (id, requirement) in toolchains {
        let Some(kind) = requirement.get("type").and_then(Value::as_str) else {
            continue;
        };
        let has_version_constraint = ["minimumVersion", "version"].iter().any(|field| {
            requirement
                .get(*field)
                .and_then(Value::as_str)
                .is_some_and(|value| !value.trim().is_empty())
        });
        entries.push((id.clone(), kind.to_string(), has_version_constraint));
    }
    Some(entries)
}

/// 按 requirement id 找探测方式；未知 id 退化成 `project-<tool>` + `--version`。
fn probe_for(id: &str) -> Option<(String, &'static [&'static str])> {
    if let Some(probe) = TOOLCHAIN_PROBES.iter().find(|probe| probe.id == id) {
        return Some((probe.command.to_string(), probe.version_arguments));
    }
    let tool = id.strip_prefix("project-")?;
    if tool.is_empty() {
        return None;
    }
    Some((tool.to_string(), &["--version"]))
}

/// 探测工具链版本；探测不出来时返回空串，让 Core 自己决定如何诊断。
fn toolchain_version(executable: &Path, kind: &str, arguments: &[&str]) -> String {
    // JDK 的 `bin/java` 上一级总有 `release`，读它比拉起 `java -version` 便宜。
    if kind == "java" {
        if let Some(version) = java_release_version(executable) {
            return version;
        }
    }
    let Ok(output) = Command::new(executable)
        .args(arguments)
        .stdin(Stdio::null())
        .output()
    else {
        return String::new();
    };
    let text = format!(
        "{}\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    first_version_token(&text).unwrap_or_default()
}

/// 读 `<jdk>/release` 里的 `JAVA_VERSION`。
fn java_release_version(executable: &Path) -> Option<String> {
    let release = executable.parent()?.parent()?.join("release");
    let text = std::fs::read_to_string(release).ok()?;
    text.lines().find_map(|line| {
        let value = line.strip_prefix("JAVA_VERSION=")?.trim().trim_matches('"');
        (!value.is_empty()).then(|| value.to_string())
    })
}

/// 取输出里第一个形如 `21.0.1` / `3.9.9` / `1.22` 的版本号。
fn first_version_token(text: &str) -> Option<String> {
    for raw in text.split_whitespace() {
        let token = raw.trim_matches(|character: char| !character.is_ascii_digit());
        if token.contains('.')
            && token
                .chars()
                .all(|character| character.is_ascii_digit() || character == '.')
        {
            return Some(token.to_string());
        }
    }
    None
}
