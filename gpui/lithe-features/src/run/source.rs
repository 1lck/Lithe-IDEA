//! Java 启动源文件解析。
//!
//! 与 macOS `DebugLaunchSourceResolver` 对齐：配置里的 `sourcePath` 是首选，
//! 其次按 Maven 模块和主类后缀在工作区 Java 文件里定位，最后才回退到当前
//! 编辑器文件或第一个候选。宿主不扫描源码里的 `main` 方法，主类只来自 Core。

use std::path::{Path, PathBuf};

use super::model::RunConfiguration;

/// 解析一次 Java 启动要交给 JDT 的源文件。
pub fn resolve(
    configuration: &RunConfiguration,
    active_document: Option<&Path>,
    project_files: &[PathBuf],
    workspace: &Path,
) -> Option<PathBuf> {
    if configuration.uses_current_editor_file() {
        return active_document.map(Path::to_path_buf);
    }

    if let Some(source_path) = configuration.source_path() {
        let source = resolve_relative(workspace, source_path);
        if project_files.iter().any(|file| same_path(file, &source)) {
            return Some(source);
        }
    }

    let mut java_files: Vec<PathBuf> = project_files
        .iter()
        .filter(|file| is_java(file))
        .cloned()
        .collect();
    java_files.sort();
    if java_files.is_empty() {
        // 调用方可能只传了活动文档；这里仍然允许它作为启动锚点。
        return active_document.filter(|file| is_java(file)).map(Path::to_path_buf);
    }

    let reactor = configuration
        .maven_reactor_path()
        .map(|path| resolve_relative(workspace, path))
        .unwrap_or_else(|| workspace.to_path_buf());
    let module_files = files_in_selected_module(
        &java_files,
        configuration.module_path(),
        &reactor,
    );
    // 有明确 Maven 归属时绝不回退到另一个反应堆的类。
    let is_owned = configuration.maven_reactor_path().is_some();
    let preferred = if module_files.is_empty() && !is_owned {
        &java_files
    } else {
        &module_files
    };

    if let Some(suffix) = source_suffix(configuration.main_class()) {
        let exact = preferred
            .iter()
            .find(|file| path_ends_with(file, &suffix))
            .or_else(|| {
                if is_owned {
                    None
                } else {
                    java_files.iter().find(|file| path_ends_with(file, &suffix))
                }
            });
        if let Some(file) = exact {
            return Some(file.clone());
        }
    }

    if let Some(active) = active_document {
        if preferred.iter().any(|file| same_path(file, active)) {
            return Some(active.to_path_buf());
        }
    }
    preferred.first().cloned()
}

/// 收集工作区里的 Java 文件。
///
/// 工作区快照在 GPUI 里没有常驻缓存，启动前按 macOS 的 `projectFiles` 语义
/// 扫描磁盘；构建产物与版本库元数据不参与候选。
pub fn collect_java_files(root: &Path) -> Vec<PathBuf> {
    const MAX_FILES: usize = 20_000;
    let mut files = Vec::new();
    let mut stack = vec![root.to_path_buf()];
    while let Some(directory) = stack.pop() {
        let Ok(entries) = std::fs::read_dir(&directory) else {
            continue;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            let Ok(file_type) = entry.file_type() else {
                continue;
            };
            if file_type.is_dir() {
                let name = entry.file_name();
                let name = name.to_string_lossy();
                if is_ignored_directory(&name) {
                    continue;
                }
                stack.push(path);
            } else if is_java(&path) {
                files.push(path);
                if files.len() >= MAX_FILES {
                    files.sort();
                    return files;
                }
            }
        }
    }
    files.sort();
    files
}

fn is_java(path: &Path) -> bool {
    path.extension()
        .and_then(|extension| extension.to_str())
        .is_some_and(|extension| extension.eq_ignore_ascii_case("java"))
}

fn is_ignored_directory(name: &str) -> bool {
    matches!(
        name,
        ".git"
            | ".lithe"
            | ".gradle"
            | ".idea"
            | ".vscode"
            | "target"
            | "build"
            | "out"
            | "bin"
            | "node_modules"
    )
}

fn resolve_relative(root: &Path, value: &str) -> PathBuf {
    let trimmed = value.trim();
    if trimmed.is_empty() || trimmed == "." {
        return root.to_path_buf();
    }
    let path = Path::new(trimmed);
    if path.is_absolute() {
        path.to_path_buf()
    } else {
        root.join(path)
    }
}

fn files_in_selected_module(
    files: &[PathBuf],
    module_path: Option<&str>,
    reactor: &Path,
) -> Vec<PathBuf> {
    let module = module_path.unwrap_or(".").trim();
    let module_root = if module.is_empty() || module == "." {
        reactor.to_path_buf()
    } else {
        reactor.join(module)
    };
    files
        .iter()
        .filter(|file| same_path(file, &module_root) || is_within(file, &module_root))
        .cloned()
        .collect()
}

fn is_within(path: &Path, directory: &Path) -> bool {
    let normalize = |value: &Path| {
        let mut text = value.to_string_lossy().replace('\\', "/");
        while text.ends_with('/') {
            text.pop();
        }
        if cfg!(windows) {
            text.to_lowercase()
        } else {
            text
        }
    };
    let directory = normalize(directory);
    let path = normalize(path);
    path.len() > directory.len()
        && path.starts_with(&directory)
        && path.as_bytes()[directory.len()] == b'/'
}

fn same_path(left: &Path, right: &Path) -> bool {
    let normalize = |value: &Path| {
        let text = value.to_string_lossy().replace('\\', "/");
        if cfg!(windows) {
            text.to_lowercase()
        } else {
            text
        }
    };
    normalize(left) == normalize(right)
}

/// macOS 的 `sourceSuffix`：`module/` 前缀和嵌套类后缀都不参与匹配。
fn source_suffix(main_class: Option<&str>) -> Option<String> {
    let mut main_class = main_class?.trim();
    if let Some((_, rest)) = main_class.rsplit_once('/') {
        main_class = rest;
    }
    if let Some((head, _)) = main_class.split_once('$') {
        main_class = head;
    }
    if main_class.is_empty() {
        return None;
    }
    Some(format!("/{}.java", main_class.replace('.', "/")))
}

fn path_ends_with(path: &Path, suffix: &str) -> bool {
    let normalize = |value: &str| {
        let text = value.replace('\\', "/");
        if cfg!(windows) {
            text.to_lowercase()
        } else {
            text
        }
    };
    normalize(&path.to_string_lossy()).ends_with(&normalize(suffix))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn configuration(provider: &str, source: Option<&str>, main_class: Option<&str>) -> RunConfiguration {
        let mut value = json!({
            "id": "demo",
            "name": "Demo",
            "provider": provider,
            "execution": "application",
            "toolchains": { "java": "project-jdk", "maven": "project-maven" },
            "extensions": {
                "maven": { "mainClass": main_class, "reactorPath": ".", "module": "." },
                "java": { "source": source }
            }
        });
        if source.is_none() {
            value["extensions"]["java"] = json!({});
        }
        if main_class.is_none() {
            value["extensions"]["maven"] = json!({ "reactorPath": ".", "module": "." });
        }
        RunConfiguration::from_json(&value).expect("configuration should parse")
    }

    #[test]
    fn current_file_uses_the_active_document() {
        let active = PathBuf::from("workspace/src/App.java");
        let resolved = resolve(
            &configuration("java.current-file", None, None),
            Some(&active),
            &[],
            Path::new("workspace"),
        );
        assert_eq!(resolved, Some(active));
    }

    #[test]
    fn source_path_wins_when_the_file_exists() {
        let files = vec![
            PathBuf::from("workspace/other/App.java"),
            PathBuf::from("workspace/src/App.java"),
        ];
        let resolved = resolve(
            &configuration("java.main", Some("src/App.java"), Some("demo.App")),
            None,
            &files,
            Path::new("workspace"),
        );
        assert_eq!(resolved, Some(PathBuf::from("workspace/src/App.java")));
    }

    #[test]
    fn main_class_suffix_matches_the_java_file() {
        let files = vec![
            PathBuf::from("workspace/demo/Helper.java"),
            PathBuf::from("workspace/demo/App.java"),
        ];
        let resolved = resolve(
            &configuration("java.main", None, Some("demo.App")),
            None,
            &files,
            Path::new("workspace"),
        );
        assert_eq!(resolved, Some(PathBuf::from("workspace/demo/App.java")));
    }

    #[test]
    fn nested_and_module_qualified_main_classes_still_match() {
        let files = vec![PathBuf::from("workspace/app/src/demo/App.java")];
        let resolved = resolve(
            &configuration("java.main", None, Some("app/demo.App$Nested")),
            None,
            &files,
            Path::new("workspace"),
        );
        assert_eq!(resolved, Some(files[0].clone()));
    }

    #[test]
    fn ignored_directories_are_not_scanned() {
        assert!(is_ignored_directory("target"));
        assert!(is_ignored_directory(".git"));
        assert!(!is_ignored_directory("src"));
    }
}
