use std::path::{Component, Path, PathBuf};

use gpui_kit::{
    AnyElement, AppContext as _, ClickEvent, Context, InteractiveElement as _, IntoElement,
    ParentElement as _, SharedString, StatefulInteractiveElement as _, Styled as _, Window, div, px,
};
use lithe_ui::components::prompt::{LithePrompt, PromptEvent, PromptSpec};
use lithe_ui::i18n::tr;
use lithe_ui::{current_tokens, LitheMetrics};

use super::super::notifications::NotificationKind;
use super::super::{Workbench, OVERLAY_CONTEXT};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum PromptAction {
    NewFile,
    NewFolder,
    NewProject,
    NewJavaType,
    NewJavaPackage,
}

impl Workbench {
    pub(crate) fn render_prompt_overlay(&self, _window: &mut Window, cx: &mut Context<Self>) -> AnyElement {
        let tokens = current_tokens(cx);
        let backdrop_owner = cx.weak_entity();

        let Some(prompt) = self.prompt.clone() else {
            return div().into_any_element();
        };

        div()
            .id("lithe-prompt-overlay")
            .absolute()
            .inset_0()
            .size_full()
            .flex()
            .items_center()
            .justify_center()
            .occlude()
            .track_focus(&self.overlay_focus)
            .key_context(OVERLAY_CONTEXT)
            .on_action(cx.listener(Self::on_action_dismiss_overlay))
            .child(
                div()
                    .id("lithe-prompt-backdrop")
                    .absolute()
                    .inset_0()
                    .size_full()
                    .occlude()
                    .bg(tokens.window.alpha(0.62))
                    .on_click(move |_event: &ClickEvent, _window, cx| {
                        let _ = backdrop_owner.update(cx, |this, cx| this.close_prompt(cx));
                    }),
            )
            .child(
                div()
                    .id("lithe-prompt-panel")
                    .occlude()
                    .w(px(420.))
                    .rounded(px(LitheMetrics::PANE_RADIUS))
                    .overflow_hidden()
                    .bg(tokens.raised)
                    .border_1()
                    .border_color(tokens.panel_border)
                    .p(px(16.))
                    .child(prompt),
            )
            .into_any_element()
    }

    pub(crate) fn open_prompt(
        &mut self,
        spec: PromptSpec,
        action: PromptAction,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.settings_visible = false;
        self.palette_visible = false;
        self.notifications_visible = false;
        self.pending_close_tab = None;
        self.project_menu_visible = false;
        self.branch_menu_visible = false;

        let prompt = cx.new(|prompt_cx| LithePrompt::new(spec, window, prompt_cx));
        cx.subscribe_in(
            &prompt,
            window,
            |this, _prompt, event: &PromptEvent, window, cx| match event {
                PromptEvent::Confirm(value) => {
                    this.confirm_prompt(value.clone().into(), window, cx);
                }
                PromptEvent::Cancel => this.close_prompt(cx),
            },
        )
        .detach();

        self.prompt = Some(prompt);
        self.prompt_action = Some(action);
        cx.notify();
    }

    pub(crate) fn open_new_file_prompt(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.open_prompt(
            PromptSpec::new(tr("New File"), tr("File name")).confirm_label(tr("Create")),
            PromptAction::NewFile,
            window,
            cx,
        );
    }

    pub(crate) fn open_new_folder_prompt(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.open_prompt(
            PromptSpec::new(tr("New Folder"), tr("Folder name")).confirm_label(tr("Create")),
            PromptAction::NewFolder,
            window,
            cx,
        );
    }

    pub(crate) fn open_new_java_type_prompt(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.open_prompt(
            PromptSpec::new(tr("New Java Type"), tr("Name")).confirm_label(tr("Create")),
            PromptAction::NewJavaType,
            window,
            cx,
        );
    }

    pub(crate) fn open_new_java_package_prompt(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.open_prompt(
            PromptSpec::new(tr("New Java Package"), tr("Package name")).confirm_label(tr("Create")),
            PromptAction::NewJavaPackage,
            window,
            cx,
        );
    }

    pub(crate) fn close_prompt(&mut self, cx: &mut Context<Self>) {
        let was_open = self.prompt.take().is_some();
        self.prompt_action = None;
        self.pending_new_project_parent = None;
        if was_open {
            cx.notify();
        }
    }

    pub(super) fn confirm_prompt(&mut self, value: SharedString, window: &mut Window, cx: &mut Context<Self>) {
        let Some(action) = self.prompt_action else {
            self.close_prompt(cx);
            return;
        };
        let parent = self.pending_new_project_parent.take();
        let name = value.trim().to_string();
        self.close_prompt(cx);

        if name.is_empty() {
            return;
        }

        let relative = Path::new(&name);
        if relative.is_absolute()
            || relative
                .components()
                .any(|component| matches!(component, Component::ParentDir))
        {
            self.status_message = Some(tr("File is outside the project").into());
            cx.notify();
            return;
        }

        match action {
            PromptAction::NewFile | PromptAction::NewFolder => {
                let Some(root) = self.project_root.clone() else {
                    return;
                };
                let target = root.join(relative);
                let create_folder = action == PromptAction::NewFolder;
                let create_target = target.clone();
                cx.spawn_in(window, async move |this, cx| {
                    let result = cx
                        .background_spawn(
                            async move { create_entry(&create_target, create_folder) },
                        )
                        .await;
                    let _ = this.update_in(cx, move |this, window, cx| match result {
                        Ok(()) => {
                            this.refresh_project_tree(window, cx);
                            if create_folder {
                                this.status_message = Some(tr("Saved").into());
                                cx.notify();
                            } else {
                                this.open_file_from_tree(target, window, cx);
                            }
                        }
                        Err(error) => {
                            let title = if create_folder {
                                tr("New Folder")
                            } else {
                                tr("New File")
                            };
                            this.push_notification(
                                title,
                                SharedString::from(error.to_string()),
                                NotificationKind::Error,
                            );
                            cx.notify();
                        }
                    });
                })
                .detach();
            }
            PromptAction::NewJavaType => {
                let Some(root) = self.project_root.clone() else {
                    return;
                };
                let base = java_source_root(&root);
                let mut target_relative = relative.to_path_buf();
                if target_relative
                    .extension()
                    .map_or(true, |extension| extension != "java")
                {
                    target_relative.set_extension("java");
                }
                let Some(class_name) = target_relative
                    .file_stem()
                    .and_then(|stem| stem.to_str())
                    .map(str::to_string)
                else {
                    self.status_message = Some(tr("Invalid name").into());
                    cx.notify();
                    return;
                };
                if !is_valid_java_name(&class_name) || !is_safe_relative_path(&target_relative) {
                    self.status_message = Some(tr("Invalid name").into());
                    cx.notify();
                    return;
                }
                let source = java_type_source(&java_package_for(&target_relative), &class_name);
                let target = base.join(&target_relative);
                let create_target = target.clone();
                cx.spawn_in(window, async move |this, cx| {
                    let result = cx
                        .background_spawn(async move { create_java_file(&create_target, &source) })
                        .await;
                    let _ = this.update_in(cx, move |this, window, cx| match result {
                        Ok(()) => {
                            this.refresh_project_tree(window, cx);
                            this.open_file_from_tree(target, window, cx);
                        }
                        Err(error) => {
                            this.push_notification(
                                tr("New Java Type"),
                                SharedString::from(error.to_string()),
                                NotificationKind::Error,
                            );
                            cx.notify();
                        }
                    });
                })
                .detach();
            }
            PromptAction::NewJavaPackage => {
                let Some(root) = self.project_root.clone() else {
                    return;
                };
                let segments: Vec<&str> = name
                    .split(|ch| ch == '.' || ch == '/' || ch == '\\')
                    .collect();
                if segments.is_empty()
                    || segments.iter().any(|segment| !is_valid_java_name(segment))
                {
                    self.status_message = Some(tr("Invalid name").into());
                    cx.notify();
                    return;
                }
                let mut target = java_source_root(&root);
                for segment in &segments {
                    target.push(segment);
                }
                let create_target = target.clone();
                cx.spawn_in(window, async move |this, cx| {
                    let result = cx
                        .background_spawn(async move { std::fs::create_dir_all(&create_target) })
                        .await;
                    let _ = this.update_in(cx, move |this, window, cx| match result {
                        Ok(()) => {
                            this.refresh_project_tree(window, cx);
                            this.status_message = Some(tr("Saved").into());
                            cx.notify();
                        }
                        Err(error) => {
                            this.push_notification(
                                tr("New Java Package"),
                                SharedString::from(error.to_string()),
                                NotificationKind::Error,
                            );
                            cx.notify();
                        }
                    });
                })
                .detach();
            }
            PromptAction::NewProject => {
                let Some(parent) = parent else {
                    return;
                };
                let target = parent.join(relative);
                let create_target = target.clone();
                cx.spawn_in(window, async move |this, cx| {
                    let result = cx
                        .background_spawn(async move { create_entry(&create_target, true) })
                        .await;
                    let _ = this.update_in(cx, move |this, window, cx| match result {
                        Ok(()) => this.open_project(target, window, cx),
                        Err(error) => {
                            this.push_notification(
                                tr("New Project"),
                                SharedString::from(error.to_string()),
                                NotificationKind::Error,
                            );
                            cx.notify();
                        }
                    });
                })
                .detach();
            }
        }
    }

    pub(crate) fn pick_new_project_parent(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let platform = self.platform.clone();
        let title = tr("New Project").to_string();
        cx.spawn_in(window, async move |this, cx| {
            let Some(parent) = platform.pick_folder(title).await else {
                return;
            };
            let _ = this.update_in(cx, |this, window, cx| {
                this.pending_new_project_parent = Some(parent);
                this.open_prompt(
                    PromptSpec::new(tr("New Project"), tr("Name")).confirm_label(tr("Create")),
                    PromptAction::NewProject,
                    window,
                    cx,
                );
            });
        })
        .detach();
    }
}

pub(super) fn java_source_root(root: &Path) -> PathBuf {
    let java_root = root.join("src").join("main").join("java");
    if java_root.is_dir() {
        java_root
    } else {
        root.to_path_buf()
    }
}

pub(super) fn java_package_for(relative: &Path) -> String {
    relative
        .parent()
        .map(|parent| {
            parent
                .components()
                .filter_map(|component| match component {
                    Component::Normal(part) => part.to_str(),
                    _ => None,
                })
                .collect::<Vec<_>>()
                .join(".")
        })
        .unwrap_or_default()
}

pub(super) fn java_type_source(package: &str, class_name: &str) -> String {
    if package.is_empty() {
        format!("public class {class_name} {{\n}}\n")
    } else {
        format!("package {package};\n\npublic class {class_name} {{\n}}\n")
    }
}

pub(super) fn is_safe_relative_path(path: &Path) -> bool {
    path.components().all(|component| match component {
        Component::Normal(part) => part.to_str().is_some_and(|part| {
            !part.is_empty()
                && !part.chars().any(|ch| {
                    ch.is_whitespace()
                        || ch.is_control()
                        || matches!(ch, '<' | '>' | ':' | '"' | '|' | '?' | '*')
                })
        }),
        _ => false,
    })
}

pub(super) fn is_valid_java_name(name: &str) -> bool {
    !name.is_empty()
        && !name.chars().any(|ch| {
            ch.is_whitespace()
                || ch.is_control()
                || matches!(
                    ch,
                    '/' | '\\' | '.' | '<' | '>' | ':' | '"' | '|' | '?' | '*'
                )
        })
}

pub(super) fn create_java_file(target: &Path, contents: &str) -> std::io::Result<()> {
    use std::io::Write as _;

    if let Some(parent) = target.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(target)?;
    file.write_all(contents.as_bytes())
}

pub(super) fn create_entry(target: &Path, folder: bool) -> std::io::Result<()> {
    if let Some(parent) = target.parent() {
        std::fs::create_dir_all(parent)?;
    }
    if folder {
        std::fs::create_dir_all(target)
    } else {
        std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(target)
            .map(|_| ())
    }
}
