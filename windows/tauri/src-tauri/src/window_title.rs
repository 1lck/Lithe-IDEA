//! Windows 原生窗口标题的展示投影、跨窗口重名处理和生命周期同步。

use crate::project_window_registry::{RegisteredTitleIdentity, RegisteredTitleProject};
use crate::project_windows::ProjectWindows;
use serde::Deserialize;
use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tauri::{AppHandle, Manager, WebviewWindow};

const APPLICATION_NAME: &str = "Lithe";
const TITLE_SEPARATOR: &str = " – ";
const TITLE_APPLY_TIMEOUT: Duration = Duration::from_secs(5);
const INITIAL_WORKSPACE_ID: &str = "initial-project";

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WindowTitleProject {
    workspace_id: String,
    display_name: String,
    path: String,
}

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WindowTitleContext {
    projects: Vec<WindowTitleProject>,
    active_workspace_id: Option<String>,
    file_name: Option<String>,
}

#[derive(Debug, Eq, Hash, PartialEq)]
enum ProjectIdentity {
    Local(RegisteredTitleIdentity),
    Other(String),
}

struct ResolvedProject {
    workspace_id: String,
    display_name: String,
    path: String,
    identity: ProjectIdentity,
}

#[derive(Default)]
struct ResolvedContext {
    projects: Vec<ResolvedProject>,
    active_workspace_id: Option<String>,
    file_name: Option<String>,
}

struct WindowProjection {
    context: ResolvedContext,
    provisional: bool,
    applied_title: Option<String>,
}

#[derive(Default)]
struct TitleRegistry {
    windows: BTreeMap<String, WindowProjection>,
    next_request: u64,
    requests: HashMap<String, u64>,
}

impl TitleRegistry {
    fn begin_request(&mut self, label: &str) -> u64 {
        self.next_request += 1;
        self.requests.insert(label.to_owned(), self.next_request);
        self.next_request
    }

    fn check_request(&self, label: &str, sequence: u64, deadline: Instant) -> Result<(), String> {
        if Instant::now() >= deadline {
            return Err("Window title update timed out".into());
        }
        if self.requests.get(label) != Some(&sequence) {
            return Err("Window title update was superseded or cancelled".into());
        }
        Ok(())
    }

    fn update(&mut self, label: &str, context: ResolvedContext, provisional: bool) {
        let applied_title = self
            .windows
            .get_mut(label)
            .and_then(|window| window.applied_title.take());
        self.windows.insert(
            label.to_owned(),
            WindowProjection {
                context,
                provisional,
                applied_title,
            },
        );
    }

    fn remove(&mut self, label: &str) {
        self.windows.remove(label);
        self.requests.remove(label);
    }

    fn update_frontend(&mut self, label: &str, context: ResolvedContext) {
        let initial_welcome = context.projects.is_empty()
            && context.active_workspace_id.is_none()
            && context.file_name.is_none();
        if initial_welcome
            && self
                .windows
                .get(label)
                .is_some_and(|window| window.provisional)
        {
            // 前端挂载时先产生欢迎态，打开目标尚未恢复；显式失败清理仍会撤销临时标题。
            return;
        }
        self.update(label, context, false);
    }

    fn update_open_window(
        &mut self,
        label: &str,
        context: ResolvedContext,
        sequence: u64,
        deadline: Instant,
        exists: impl FnOnce(&str) -> bool,
    ) -> Result<(), String> {
        self.check_request(label, sequence, deadline)?;
        if !exists(label) {
            return Err("Window is no longer available".into());
        }
        self.update_frontend(label, context);
        Ok(())
    }

    fn release_pending(&mut self, label: &str) {
        if self
            .windows
            .get(label)
            .is_some_and(|window| window.provisional)
        {
            self.update(label, ResolvedContext::default(), false);
        }
    }

    fn titles(&self) -> BTreeMap<String, String> {
        let mut identities_by_name: HashMap<&str, HashSet<&ProjectIdentity>> = HashMap::new();
        for window in self.windows.values() {
            for project in &window.context.projects {
                identities_by_name
                    .entry(&project.display_name)
                    .or_default()
                    .insert(&project.identity);
            }
        }
        self.windows
            .iter()
            .map(|(label, window)| {
                let project = window.context.active_workspace_id.as_ref().and_then(|id| {
                    window
                        .context
                        .projects
                        .iter()
                        .find(|project| &project.workspace_id == id)
                });
                let mut parts = Vec::new();
                if let Some(project) = project {
                    let duplicated = identities_by_name
                        .get(project.display_name.as_str())
                        .is_some_and(|identities| identities.len() > 1);
                    parts.push(if duplicated {
                        format!("{} [{}]", project.display_name, project.path)
                    } else {
                        project.display_name.clone()
                    });
                }
                if let Some(file_name) = &window.context.file_name {
                    parts.push(file_name.clone());
                }
                parts.push(APPLICATION_NAME.to_owned());
                (label.clone(), parts.join(TITLE_SEPARATOR))
            })
            .collect()
    }

    fn apply(
        &mut self,
        mut set_title: impl FnMut(&str, &str) -> Result<bool, String>,
    ) -> Result<(), String> {
        let mut failures = Vec::new();
        for (label, title) in self.titles() {
            let window = self
                .windows
                .get_mut(&label)
                .expect("Window title projection exists");
            if window.applied_title.as_ref() == Some(&title) {
                continue;
            }
            match set_title(&label, &title) {
                Ok(true) => window.applied_title = Some(title),
                Ok(false) => {}
                Err(error) => failures.push(format!("{label}: {error}")),
            }
        }
        if failures.is_empty() {
            Ok(())
        } else {
            Err(format!(
                "Could not update window title: {}",
                failures.join("; ")
            ))
        }
    }
}

#[derive(Default)]
pub struct WindowTitles(Mutex<TitleRegistry>);

fn report_error(app: &AppHandle, message: &str) {
    eprintln!("[window-title] {message}");
    if let Some(manager) = app.try_state::<Arc<crate::logging::LogManager>>() {
        manager.emit_json("warn", "window-title".into(), message.into(), None);
    }
}

fn single_line(value: &str) -> String {
    value
        .chars()
        .map(|character| {
            if character.is_control() || matches!(character, '\u{2028}' | '\u{2029}') {
                ' '
            } else {
                character
            }
        })
        .collect::<String>()
        .trim()
        .to_owned()
}

fn optional_name(value: Option<String>) -> Option<String> {
    value
        .map(|value| single_line(&value))
        .filter(|value| !value.is_empty())
}

fn resolve_context(
    context: WindowTitleContext,
    registered: &[RegisteredTitleProject],
    label: &str,
    provisional: bool,
) -> ResolvedContext {
    let projects = context
        .projects
        .into_iter()
        .filter_map(|project| {
            let display_name = single_line(&project.display_name);
            if display_name.is_empty() || project.workspace_id.is_empty() || project.path.is_empty()
            {
                return None;
            }
            let registration = registered.iter().find(|entry| {
                entry.owner.workspace_id.as_deref() == Some(&project.workspace_id)
                    || (provisional
                        && entry.owner.label == label
                        && entry.owner.workspace_id.is_none())
            });
            if registration.is_some_and(|entry| entry.owner.label != label) {
                return None;
            }
            // 未登记标签仅按明确的展示路径区分，不尝试访问 UNC 或猜测目录别名。
            let identity = registration
                .map(|entry| ProjectIdentity::Local(entry.identity.clone()))
                .unwrap_or_else(|| ProjectIdentity::Other(project.path.clone()));
            Some(ResolvedProject {
                workspace_id: project.workspace_id,
                display_name,
                path: single_line(&project.path),
                identity,
            })
        })
        .collect();
    ResolvedContext {
        projects,
        active_workspace_id: context.active_workspace_id,
        file_name: optional_name(context.file_name),
    }
}

fn apply_latest(app: &AppHandle) -> Result<(), String> {
    let state = app.state::<WindowTitles>();
    let mut registry = state
        .0
        .lock()
        .map_err(|_| "Window title state is unavailable")?;
    // 原生调用在 UI 线程读取最新快照；缓存与设置处于同一短临界区，旧回调不能覆盖新标题。
    registry.apply(|label, title| {
        let Some(window) = app.get_webview_window(label) else {
            return Ok(false);
        };
        window
            .set_title(title)
            .map(|()| true)
            .map_err(|error| error.to_string())
    })
}

fn apply_context(
    app: &AppHandle,
    label: &str,
    context: ResolvedContext,
    sequence: u64,
    deadline: Instant,
) -> Result<(), String> {
    {
        let state = app.state::<WindowTitles>();
        let mut registry = state
            .0
            .lock()
            .map_err(|_| "Window title state is unavailable")?;
        // 生存检查与更新一起在 UI 回调内完成，销毁事件不能在二者之间插入。
        registry.update_open_window(label, context, sequence, deadline, |label| {
            app.get_webview_window(label).is_some()
        })?;
    }
    apply_latest(app)
}

async fn before_deadline<T>(
    deadline: Instant,
    future: impl std::future::Future<Output = T>,
) -> Result<T, String> {
    tokio::time::timeout_at(tokio::time::Instant::from_std(deadline), future)
        .await
        .map_err(|_| "Window title update timed out".to_owned())
}

fn schedule_apply(app: &AppHandle) {
    let current_app = app.clone();
    if let Err(error) = app.run_on_main_thread(move || {
        if let Err(error) = apply_latest(&current_app) {
            report_error(&current_app, &error);
        }
    }) {
        report_error(app, &format!("Could not schedule title update: {error}"));
    }
}

#[tauri::command]
pub async fn update_window_title_context(
    app: AppHandle,
    window: WebviewWindow,
    context: WindowTitleContext,
) -> Result<(), String> {
    let deadline = Instant::now() + TITLE_APPLY_TIMEOUT;
    let sequence = {
        let state = app.state::<WindowTitles>();
        let mut registry = state
            .0
            .lock()
            .map_err(|_| "Window title state is unavailable")?;
        registry.begin_request(window.label())
    };
    let registered = {
        let state = app.state::<ProjectWindows>();
        let registry = before_deadline(deadline, state.0.lock()).await?;
        registry.title_snapshot()
    };
    let context = resolve_context(context, &registered, window.label(), false);
    let (sender, receiver) = tokio::sync::oneshot::channel();
    let current_app = app.clone();
    let label = window.label().to_owned();
    app.run_on_main_thread(move || {
        if sender.is_closed() {
            return;
        }
        let result = apply_context(&current_app, &label, context, sequence, deadline);
        if let Err(error) = &result {
            report_error(&current_app, error);
        }
        if sender.send(result).is_err() {
            report_error(&current_app, "Title update caller is no longer available");
        }
    })
    .map_err(|error| error.to_string())?;
    before_deadline(deadline, receiver)
        .await?
        .map_err(|_| "Window title update was cancelled".to_owned())?
}

pub fn prepare_initial_title(
    app: &AppHandle,
    label: &str,
    path: Option<&str>,
    is_directory: bool,
    registered: &[RegisteredTitleProject],
) -> String {
    let context = match path.filter(|path| !path.contains("://")) {
        Some(path) => {
            let name = Path::new(path)
                .file_name()
                .unwrap_or_else(|| Path::new(path).as_os_str())
                .to_string_lossy()
                .into_owned();
            if is_directory {
                WindowTitleContext {
                    projects: vec![WindowTitleProject {
                        workspace_id: INITIAL_WORKSPACE_ID.into(),
                        display_name: name,
                        path: path.to_owned(),
                    }],
                    active_workspace_id: Some(INITIAL_WORKSPACE_ID.into()),
                    file_name: None,
                }
            } else {
                WindowTitleContext {
                    file_name: Some(name),
                    ..Default::default()
                }
            }
        }
        None => WindowTitleContext::default(),
    };
    let context = resolve_context(context, registered, label, true);
    let state = app.state::<WindowTitles>();
    let Ok(mut registry) = state.0.lock() else {
        report_error(app, "Initial title state is unavailable");
        return APPLICATION_NAME.into();
    };
    registry.update(label, context, true);
    registry
        .titles()
        .remove(label)
        .unwrap_or_else(|| APPLICATION_NAME.into())
}

pub fn window_created(app: &AppHandle) {
    schedule_apply(app);
}

pub fn remove_window(app: &AppHandle, label: &str) {
    if let Some(state) = app.try_state::<WindowTitles>() {
        match state.0.lock() {
            Ok(mut registry) => registry.remove(label),
            Err(_) => report_error(app, "Could not remove closed window title"),
        }
        schedule_apply(app);
    }
}

pub fn release_pending(app: &AppHandle, label: &str) {
    if let Some(state) = app.try_state::<WindowTitles>() {
        match state.0.lock() {
            Ok(mut registry) => registry.release_pending(label),
            Err(_) => report_error(app, "Could not release pending window title"),
        }
        schedule_apply(app);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU64, Ordering};

    static NEXT_ROOT: AtomicU64 = AtomicU64::new(0);

    struct TestDirectory(PathBuf);

    impl TestDirectory {
        fn new() -> Self {
            let path = std::env::temp_dir().join(format!(
                "lithe-window-title-{}-{}",
                std::process::id(),
                NEXT_ROOT.fetch_add(1, Ordering::Relaxed)
            ));
            fs::create_dir(&path).unwrap();
            Self(path)
        }

        fn path(&self) -> String {
            self.0.to_string_lossy().into_owned()
        }
    }

    impl Drop for TestDirectory {
        fn drop(&mut self) {
            if let Err(error) = fs::remove_dir_all(&self.0) {
                eprintln!("Could not remove window-title test directory: {error}");
            }
        }
    }

    fn project(id: &str, name: &str, path: &str) -> ResolvedProject {
        ResolvedProject {
            workspace_id: id.into(),
            display_name: single_line(name),
            path: single_line(path),
            identity: ProjectIdentity::Other(path.into()),
        }
    }

    fn context(
        projects: Vec<ResolvedProject>,
        active: &str,
        file: Option<&str>,
    ) -> ResolvedContext {
        ResolvedContext {
            projects,
            active_workspace_id: Some(active.into()),
            file_name: optional_name(file.map(str::to_owned)),
        }
    }

    #[test]
    fn formats_welcome_project_file_alias_and_standalone_file() {
        let mut registry = TitleRegistry::default();
        registry.update("main", ResolvedContext::default(), false);
        assert_eq!(registry.titles()["main"], "Lithe");
        registry.update(
            "main",
            context(vec![project("a", "demo", r"D:\work\demo")], "a", None),
            false,
        );
        assert_eq!(registry.titles()["main"], "demo – Lithe");
        registry.update(
            "main",
            context(
                vec![project("a", "demo (后端)", r"D:\work\demo")],
                "a",
                Some("Application.java"),
            ),
            false,
        );
        assert_eq!(
            registry.titles()["main"],
            "demo (后端) – Application.java – Lithe"
        );
        registry.update(
            "main",
            ResolvedContext {
                file_name: Some("notes.md".into()),
                ..Default::default()
            },
            false,
        );
        assert_eq!(registry.titles()["main"], "notes.md – Lithe");
    }

    #[test]
    fn updates_both_duplicate_windows_and_restores_after_close() {
        let mut registry = TitleRegistry::default();
        registry.update(
            "a",
            context(
                vec![project("a", "demo", r"D:\work\demo")],
                "a",
                Some("Main.java"),
            ),
            false,
        );
        registry.update(
            "b",
            context(vec![project("b", "demo", r"E:\sample\demo")], "b", None),
            false,
        );
        assert_eq!(
            registry.titles()["a"],
            r"demo [D:\work\demo] – Main.java – Lithe"
        );
        assert_eq!(registry.titles()["b"], r"demo [E:\sample\demo] – Lithe");
        registry.remove("b");
        assert_eq!(registry.titles()["a"], "demo – Main.java – Lithe");
    }

    #[test]
    fn counts_background_tabs_and_uses_final_display_name() {
        let mut registry = TitleRegistry::default();
        registry.update(
            "main",
            context(
                vec![
                    project("a", "demo", r"D:\demo"),
                    project("b", "demo", r"E:\demo"),
                ],
                "a",
                None,
            ),
            false,
        );
        assert_eq!(registry.titles()["main"], r"demo [D:\demo] – Lithe");
        registry.update(
            "main",
            context(
                vec![
                    project("a", "demo", r"D:\demo"),
                    project("b", "demo (实验)", r"E:\demo"),
                ],
                "a",
                None,
            ),
            false,
        );
        assert_eq!(registry.titles()["main"], "demo – Lithe");
    }

    fn frontend_context(id: &str, path: &str) -> WindowTitleContext {
        WindowTitleContext {
            projects: vec![WindowTitleProject {
                workspace_id: id.into(),
                display_name: "demo".into(),
                path: path.into(),
            }],
            active_workspace_id: Some(id.into()),
            file_name: Some("Main.java".into()),
        }
    }

    #[test]
    fn registry_snapshot_reuses_native_alias_entry_and_copies_owner() {
        use crate::project_window_registry::ProjectWindowRegistry;
        let root = TestDirectory::new();
        let mut owners = ProjectWindowRegistry::default();
        owners.claim(
            ProjectWindowRegistry::identity(&root.0).unwrap(),
            "main",
            Some("a"),
        );
        let first = owners.title_snapshot();
        let alias_owner = owners.claim(
            ProjectWindowRegistry::identity(&root.0.join(".")).unwrap(),
            "other",
            Some("alias"),
        );
        assert_eq!(alias_owner.label, "main");
        let second = owners.title_snapshot();
        assert_eq!(second.len(), 1);
        assert_eq!(first[0].identity, second[0].identity);
        owners.release("main", Some("a"));
        assert!(owners.title_snapshot().is_empty());
        assert_eq!(first[0].owner.workspace_id.as_deref(), Some("a"));
    }

    #[test]
    fn registered_identity_is_reused_without_reopening_display_path() {
        use crate::project_window_registry::ProjectWindowRegistry;
        let root = TestDirectory::new();
        let mut owners = ProjectWindowRegistry::default();
        owners.claim(
            ProjectWindowRegistry::identity(&root.0).unwrap(),
            "main",
            Some("a"),
        );
        let snapshot = owners.title_snapshot();
        let resolved = resolve_context(
            frontend_context("a", r"\\offline\share\demo"),
            &snapshot,
            "main",
            false,
        );
        assert_eq!(
            resolved.projects[0].identity,
            ProjectIdentity::Local(snapshot[0].identity.clone())
        );
        let alias = resolve_context(
            frontend_context("a", r"C:\missing\alias"),
            &snapshot,
            "main",
            false,
        );
        assert_eq!(resolved.projects[0].identity, alias.projects[0].identity);
    }

    #[test]
    fn unregistered_paths_remain_distinct_until_initialization_refresh() {
        use crate::project_window_registry::ProjectWindowRegistry;
        let root = TestDirectory::new();
        let input = frontend_context("a", r"\\offline\share\demo");
        let unresolved = resolve_context(input, &[], "main", false);
        assert_eq!(
            unresolved.projects[0].identity,
            ProjectIdentity::Other(r"\\offline\share\demo".into())
        );
        let mut registry = TitleRegistry::default();
        registry.update("main", unresolved, false);
        registry.update(
            "other",
            context(vec![project("b", "demo", r"C:\missing\demo")], "b", None),
            false,
        );
        assert!(registry.titles()["main"].contains(r"[\\offline\share\demo]"));
        let mut owners = ProjectWindowRegistry::default();
        owners.claim(
            ProjectWindowRegistry::identity(&root.0).unwrap(),
            "main",
            Some("a"),
        );
        let refreshed = resolve_context(
            frontend_context("a", r"\\offline\share\demo"),
            &owners.title_snapshot(),
            "main",
            false,
        );
        assert!(matches!(
            refreshed.projects[0].identity,
            ProjectIdentity::Local(_)
        ));
        registry.update("main", refreshed, false);
        assert!(registry.titles()["main"].contains(r"[\\offline\share\demo]"));
    }

    #[test]
    fn snapshot_filters_other_owners_and_reads_initial_reservation() {
        use crate::project_window_registry::ProjectWindowRegistry;
        let root = TestDirectory::new();
        let mut owners = ProjectWindowRegistry::default();
        owners.claim(
            ProjectWindowRegistry::identity(&root.0).unwrap(),
            "other",
            Some("a"),
        );
        let snapshot = owners.title_snapshot();
        assert!(resolve_context(
            frontend_context("a", &root.path()),
            &snapshot,
            "main",
            false
        )
        .projects
        .is_empty());
        assert_eq!(
            resolve_context(
                frontend_context("a", &root.path()),
                &snapshot,
                "other",
                false
            )
            .projects
            .len(),
            1
        );
        owners.release("other", Some("a"));
        owners.claim(
            ProjectWindowRegistry::identity(&root.0).unwrap(),
            "new",
            None,
        );
        let snapshot = owners.title_snapshot();
        let initial = resolve_context(
            frontend_context(INITIAL_WORKSPACE_ID, &root.path()),
            &snapshot,
            "new",
            true,
        );
        assert_eq!(
            initial.projects[0].identity,
            ProjectIdentity::Local(snapshot[0].identity.clone())
        );
    }

    #[tokio::test(flavor = "current_thread")]
    async fn one_deadline_bounds_registry_lock_and_ui_acknowledgement() {
        let owners = tokio::sync::Mutex::new(());
        let held = owners.lock().await;
        let deadline = Instant::now();
        assert_eq!(
            before_deadline(deadline, owners.lock()).await.unwrap_err(),
            "Window title update timed out"
        );
        drop(held);
        let (_sender, receiver) = tokio::sync::oneshot::channel::<()>();
        assert_eq!(
            before_deadline(deadline, receiver).await.unwrap_err(),
            "Window title update timed out"
        );
    }

    #[test]
    fn expired_or_superseded_callbacks_cannot_mutate_projection() {
        let mut registry = TitleRegistry::default();
        let expired = Instant::now();
        let old = registry.begin_request("main");
        let latest = registry.begin_request("main");
        let deadline = Instant::now() + TITLE_APPLY_TIMEOUT;
        assert!(registry
            .update_open_window("main", ResolvedContext::default(), old, deadline, |_| true)
            .unwrap_err()
            .contains("superseded"));
        assert!(registry
            .update_open_window("main", ResolvedContext::default(), latest, expired, |_| {
                true
            })
            .unwrap_err()
            .contains("timed out"));
        assert!(registry.titles().is_empty());
        registry
            .update_open_window(
                "main",
                context(vec![project("a", "demo", r"D:\demo")], "a", None),
                latest,
                deadline,
                |_| true,
            )
            .unwrap();
        assert_eq!(registry.titles()["main"], "demo – Lithe");
        registry.remove("main");
        assert!(registry
            .update_open_window("main", ResolvedContext::default(), latest, deadline, |_| {
                true
            })
            .is_err());
        assert!(registry.titles().is_empty());
    }

    #[test]
    fn preserves_unicode_and_unc_paths_and_cleans_control_characters() {
        let mut registry = TitleRegistry::default();
        registry.update(
            "a",
            context(
                vec![project(
                    "a",
                    " 项目\n😀\u{2028}后端 ",
                    r"\\server\share\demo",
                )],
                "a",
                Some("中文\0文件.ts"),
            ),
            false,
        );
        registry.update(
            "b",
            context(vec![project("b", "项目 😀 后端", r"D:\demo")], "b", None),
            false,
        );
        assert_eq!(
            registry.titles()["a"],
            r"项目 😀 后端 [\\server\share\demo] – 中文 文件.ts – Lithe"
        );
    }

    #[test]
    fn failed_creation_and_initial_open_release_only_provisional_projection() {
        let mut registry = TitleRegistry::default();
        registry.update(
            "a",
            context(vec![project("a", "demo", r"D:\demo")], "a", None),
            false,
        );
        registry.update(
            "b",
            context(vec![project("b", "demo", r"E:\demo")], "b", None),
            true,
        );
        registry.release_pending("b");
        assert_eq!(registry.titles()["a"], "demo – Lithe");
        assert_eq!(registry.titles()["b"], "Lithe");
        registry.release_pending("a");
        assert_eq!(registry.titles()["a"], "demo – Lithe");
        registry.remove("b");
        assert!(!registry.titles().contains_key("b"));
    }

    #[test]
    fn applies_latest_snapshot_and_caches_only_successful_native_updates() {
        let mut registry = TitleRegistry::default();
        registry.update(
            "main",
            context(vec![project("a", "old", r"D:\demo")], "a", None),
            false,
        );
        registry.update(
            "main",
            context(
                vec![project("a", "latest", r"D:\demo")],
                "a",
                Some("Main.java"),
            ),
            false,
        );
        let mut calls = Vec::new();
        let result = registry.apply(|label, title| {
            calls.push((label.to_owned(), title.to_owned()));
            Err("native failure".into())
        });
        assert!(result.unwrap_err().contains("native failure"));
        assert_eq!(
            calls,
            vec![("main".into(), "latest – Main.java – Lithe".into())]
        );
        registry
            .apply(|_, title| {
                calls.push(("main".into(), title.into()));
                Ok(true)
            })
            .unwrap();
        assert_eq!(calls.len(), 2);
        registry
            .apply(|_, _| panic!("Successful identical title must not be applied again"))
            .unwrap();
    }

    #[test]
    fn pending_native_window_is_not_cached_before_creation() {
        let mut registry = TitleRegistry::default();
        registry.update(
            "pending",
            context(vec![project("a", "demo", r"D:\demo")], "a", None),
            true,
        );
        registry.apply(|_, _| Ok(false)).unwrap();
        let mut calls = Vec::new();
        registry
            .apply(|label, title| {
                calls.push((label.to_owned(), title.to_owned()));
                Ok(true)
            })
            .unwrap();
        assert_eq!(calls, vec![("pending".into(), "demo – Lithe".into())]);
        registry.update(
            "pending",
            context(
                vec![project("actual", "demo (别名)", r"D:\demo")],
                "actual",
                None,
            ),
            false,
        );
        registry.release_pending("pending");
        assert_eq!(registry.titles()["pending"], "demo (别名) – Lithe");
    }

    #[test]
    fn initial_welcome_does_not_clear_provisional_open_target() {
        let mut registry = TitleRegistry::default();
        registry.update(
            "pending",
            context(
                vec![project("initial", "demo", r"D:\demo")],
                "initial",
                None,
            ),
            true,
        );
        registry.update_frontend("pending", ResolvedContext::default());
        assert_eq!(registry.titles()["pending"], "demo – Lithe");
        registry.release_pending("pending");
        assert_eq!(registry.titles()["pending"], "Lithe");
        registry.update(
            "pending",
            ResolvedContext {
                file_name: Some("notes.md".into()),
                ..Default::default()
            },
            true,
        );
        registry.update_frontend("pending", ResolvedContext::default());
        assert_eq!(registry.titles()["pending"], "notes.md – Lithe");
        registry.update_frontend(
            "pending",
            context(
                vec![project("actual", "demo (别名)", r"D:\demo")],
                "actual",
                None,
            ),
        );
        registry.release_pending("pending");
        assert_eq!(registry.titles()["pending"], "demo (别名) – Lithe");
        registry.update_frontend("pending", ResolvedContext::default());
        assert_eq!(registry.titles()["pending"], "Lithe");
    }

    #[test]
    fn queued_update_after_destruction_does_not_restore_a_ghost_project() {
        let mut registry = TitleRegistry::default();
        registry.update(
            "main",
            context(vec![project("a", "demo", r"D:\demo")], "a", None),
            false,
        );
        registry.update(
            "closing",
            context(vec![project("b", "demo", r"E:\demo")], "b", None),
            false,
        );
        let queued_context = context(vec![project("b", "demo", r"E:\demo")], "b", None);
        let sequence = registry.begin_request("closing");
        registry.remove("closing");
        let result = registry.update_open_window(
            "closing",
            queued_context,
            sequence,
            Instant::now() + TITLE_APPLY_TIMEOUT,
            |_| false,
        );
        assert!(result.unwrap_err().contains("cancelled"));
        assert!(!registry.titles().contains_key("closing"));
        assert_eq!(registry.titles()["main"], "demo – Lithe");
        let sequence = registry.begin_request("main");
        registry
            .update_open_window(
                "main",
                context(
                    vec![project("a", "demo", r"D:\demo")],
                    "a",
                    Some("Main.java"),
                ),
                sequence,
                Instant::now() + TITLE_APPLY_TIMEOUT,
                |_| true,
            )
            .unwrap();
        assert_eq!(registry.titles()["main"], "demo – Main.java – Lithe");
    }

    #[test]
    fn deserializes_the_frontend_camel_case_contract() {
        let context: WindowTitleContext = serde_json::from_value(serde_json::json!({
            "projects": [{ "workspaceId": "a", "displayName": "demo", "path": "D:\\demo" }],
            "activeWorkspaceId": "a", "fileName": null
        }))
        .unwrap();
        assert_eq!(context.projects[0].workspace_id, "a");
        assert_eq!(context.projects[0].display_name, "demo");
        assert_eq!(context.active_workspace_id.as_deref(), Some("a"));
        assert!(context.file_name.is_none());
    }
}
