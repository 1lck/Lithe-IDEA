//! 运行配置的读取、生成与解析。
//!
//! Core 的 `runConfig.*` 命令是纯函数：`generate` 返回文档，宿主负责原子写入
//! `.lithe`。本模块只处理这类文件 I/O 和 JSON 映射，视图层不直接碰 Core。

use std::fs;
use std::path::{Path, PathBuf};

use lithe_core_client::CoreClient;
use serde_json::{Value, json};

use super::model::{RunConfiguration, RunDiagnostic};
use super::session;

/// 一次加载得到的最终配置。
pub struct LoadedRunConfigurations {
    pub configurations: Vec<RunConfiguration>,
    pub default_id: Option<String>,
    pub diagnostics: Vec<RunDiagnostic>,
}

/// 读取工作区运行配置；需要时先让 Core 重新生成。
pub fn load_configurations(
    client: &CoreClient,
    root: &Path,
) -> Result<LoadedRunConfigurations, String> {
    let root_text = root.to_string_lossy().to_string();
    let snapshot = client
        .execute_raw(
            "workspace.snapshot",
            json!({ "root": root_text, "includeTree": false }),
        )
        .map_err(|error| {
            format!(
                "{}: {error}",
                lithe_ui::i18n::tr("Could not scan the project")
            )
        })?;
    let paths: Vec<String> = snapshot
        .get("files")
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter_map(Value::as_str)
                .map(str::to_string)
                .collect()
        })
        .unwrap_or_default();

    // 损坏的 generated.json 不应让项目永久无法运行：inspect 失败时按缺失处理，
    // 下面的 generate 会用新文档覆盖它。其它错误仍会在 generate 阶段报告。
    let inspected = client
        .execute_raw("runConfig.inspect", json!({ "root": root_text }))
        .unwrap_or_else(|_| json!({ "status": "missing" }));

    let needs_generation = inspected
        .get("status")
        .and_then(Value::as_str)
        .is_none_or(|status| status != "ready")
        || inspected
            .get("diagnostics")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .any(|diagnostic| {
                matches!(
                    diagnostic.get("code").and_then(Value::as_str),
                    Some("staleFingerprint" | "staleJavaEntrypoint")
                )
            });

    if needs_generation {
        let generated = client
            .execute_raw(
                "runConfig.generate",
                json!({ "root": root_text, "paths": paths }),
            )
            .map_err(|error| {
                format!(
                    "{}: {error}",
                    lithe_ui::i18n::tr("Could not read run configuration")
                )
            })?;
        write_generated_documents(root, &generated)?;
    }

    // 工具链候选必须随请求上报：Core 只在候选里找到「同 id + 同 type」的条目时
    // 才把 requirements 声明的工具链视为已选择，否则即使机器上装了 JDK，每个
    // Java 配置都会被判成 “No local java toolchain is selected”。
    let toolchain_candidates = session::toolchain_candidates(root);
    let resolved = client
        .execute_raw(
            "runConfig.resolve",
            json!({
                "root": root_text,
                "toolchainCandidates": toolchain_candidates,
            }),
        )
        .map_err(|error| {
            format!(
                "{}: {error}",
                lithe_ui::i18n::tr("Could not read run configuration")
            )
        })?;

    // `resolve` 可能在 `inspect` 之后发现新生成的 Java 入口缺少主类。
    // 已经生成过就不再循环；第二次仍失败时把诊断交给界面。
    let configurations = parse_configurations(&resolved);
    let diagnostics = parse_diagnostics(&resolved);
    let default_id = resolved
        .get("defaultRunConfiguration")
        .and_then(Value::as_str)
        .map(str::to_string);

    Ok(LoadedRunConfigurations {
        configurations,
        default_id,
        diagnostics,
    })
}

fn parse_configurations(resolved: &Value) -> Vec<RunConfiguration> {
    resolved
        .get("configurations")
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter_map(RunConfiguration::from_json)
                .collect()
        })
        .unwrap_or_default()
}

fn parse_diagnostics(resolved: &Value) -> Vec<RunDiagnostic> {
    resolved
        .get("diagnostics")
        .and_then(Value::as_array)
        .map(|items| items.iter().filter_map(RunDiagnostic::from_json).collect())
        .unwrap_or_default()
}

/// 原子写入 Core 生成的两份文档，并维护 `.lithe/.gitignore`。
fn write_generated_documents(root: &Path, generated: &Value) -> Result<(), String> {
    let run_directory = root.join(".lithe").join("run");
    let toolchain_directory = root.join(".lithe").join("toolchains");
    fs::create_dir_all(&run_directory).map_err(|error| {
        format!(
            "{}: {error}",
            lithe_ui::i18n::tr("Could not save run configuration")
        )
    })?;
    fs::create_dir_all(&toolchain_directory).map_err(|error| {
        format!(
            "{}: {error}",
            lithe_ui::i18n::tr("Could not save run configuration")
        )
    })?;

    let document = generated
        .get("generated")
        .cloned()
        .ok_or_else(|| lithe_ui::i18n::tr("Could not read run configuration").to_string())?;
    write_json(&run_directory.join("generated.json"), &document)?;

    let requirements = generated
        .get("toolchainRequirements")
        .cloned()
        .unwrap_or_else(|| json!({ "version": 1, "toolchains": {} }));
    write_json(
        &toolchain_directory.join("requirements.json"),
        &requirements,
    )?;

    update_gitignore(root)?;
    Ok(())
}

fn write_json(path: &Path, value: &Value) -> Result<(), String> {
    let text = serde_json::to_string_pretty(value).map_err(|error| {
        format!(
            "{}: {error}",
            lithe_ui::i18n::tr("Could not save run configuration")
        )
    })?;
    atomic_write(path, &text)
}

fn atomic_write(path: &Path, text: &str) -> Result<(), String> {
    let temporary = path.with_extension(format!("{}.tmp", std::process::id()));
    fs::write(&temporary, text).map_err(|error| {
        format!(
            "{}: {error}",
            lithe_ui::i18n::tr("Could not save run configuration")
        )
    })?;
    fs::rename(&temporary, path).map_err(|error| {
        let _ = fs::remove_file(&temporary);
        format!(
            "{}: {error}",
            lithe_ui::i18n::tr("Could not save run configuration")
        )
    })
}

/// `.lithe` 下只有生成物与本地层；本地层和临时文件不应进入版本库。
fn update_gitignore(root: &Path) -> Result<(), String> {
    const ENTRIES: [&str; 4] = [
        "run/local.json",
        "toolchains/local.json",
        "run/classes/",
        "**/*.tmp",
    ];
    let directory = root.join(".lithe");
    let path = directory.join(".gitignore");
    let mut existing = fs::read_to_string(&path).unwrap_or_default();
    let mut changed = false;
    for entry in ENTRIES {
        if !existing.lines().any(|line| line.trim() == entry) {
            if !existing.is_empty() && !existing.ends_with('\n') {
                existing.push('\n');
            }
            existing.push_str(entry);
            existing.push('\n');
            changed = true;
        }
    }
    if changed {
        fs::write(&path, existing).map_err(|error| {
            format!(
                "{}: {error}",
                lithe_ui::i18n::tr("Could not save run configuration")
            )
        })?;
    }
    Ok(())
}

/// 工作区根目录，空路径表示未打开项目。
pub fn normalize_root(root: PathBuf) -> Option<PathBuf> {
    if root.as_os_str().is_empty() {
        None
    } else {
        Some(root)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    fn generates_configuration_from_package_scripts() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("clock should be after epoch")
            .as_nanos();
        let root =
            std::env::temp_dir().join(format!("lithe-run-config-{}-{unique}", std::process::id()));
        fs::create_dir_all(&root).expect("temp project should be created");
        fs::write(root.join("package.json"), r#"{"scripts":{"dev":"vite"}}"#)
            .expect("package.json should be written");
        let generated = load_configurations(&CoreClient::new(), &root);
        let _ = fs::remove_dir_all(&root);
        let loaded = generated.expect("run configuration should load");
        assert!(
            loaded
                .configurations
                .iter()
                .any(|configuration| configuration.provider == "npm.script")
        );
    }
}
