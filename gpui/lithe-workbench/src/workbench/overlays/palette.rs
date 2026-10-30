use gpui_kit::component::command::{Command, CommandItem};
use gpui_kit::{
    AnyElement, AppContext as _, ClickEvent, Context, InteractiveElement as _, IntoElement,
    ParentElement as _, StatefulInteractiveElement as _, Styled as _, Window, div, px,
};
use lithe_features::local_history::format_time;
use lithe_features::quick_open::{filter_files, index_project};
use lithe_ui::i18n::tr;
use lithe_ui::icons::{icon, LitheIcon};
use lithe_ui::{current_tokens, LitheMetrics};

use super::super::notifications::NotificationKind;
use super::super::tabs::file_icon;
use super::super::{
    OpenProject, OpenQuickFile, RestoreHistorySnapshot, ShowGit, ShowSearch, ToggleSettings,
    ToggleTheme, ToggleWrap, Workbench, OVERLAY_CONTEXT,
};
use crate::layout;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum PaletteMode {
    Commands,
    Files,
    History,
}

impl Workbench {
    pub(crate) fn render_palette_overlay(&self, _window: &mut Window, cx: &mut Context<Self>) -> AnyElement {
        let tokens = current_tokens(cx);
        let backdrop_owner = cx.weak_entity();
        let cancel_owner = cx.weak_entity();

        let Some(palette) = self.palette.clone() else {
            return div().into_any_element();
        };

        let query_owner = cx.weak_entity();
        let command = match self.palette_mode {
            PaletteMode::Commands => Command::new(&palette)
                .bordered(false)
                .placeholder(tr("Command Palette"))
                .max_h(layout::COMMAND_PALETTE_MAX_HEIGHT)
                .item(
                    CommandItem::new()
                        .label(tr("Open Project"))
                        .keywords(["open", "project", "folder"])
                        .icon(icon(LitheIcon::Project))
                        .action(Box::new(OpenProject)),
                )
                .item(
                    CommandItem::new()
                        .label(tr("Settings"))
                        .keywords(["settings", "preferences"])
                        .icon(icon(LitheIcon::Settings))
                        .action(Box::new(ToggleSettings)),
                )
                .item(
                    CommandItem::new()
                        .label(tr("Git"))
                        .keywords(["git", "changes"])
                        .icon(icon(LitheIcon::Changes))
                        .action(Box::new(ShowGit)),
                )
                .item(
                    CommandItem::new()
                        .label(tr("Search"))
                        .keywords(["search", "find"])
                        .icon(icon(LitheIcon::Search))
                        .action(Box::new(ShowSearch)),
                )
                .separator()
                .item(
                    CommandItem::new()
                        .label(tr("Toggle Dark"))
                        .keywords(["theme", "dark", "light"])
                        .checked(self.settings.dark)
                        .action(Box::new(ToggleTheme)),
                )
                .item(
                    CommandItem::new()
                        .label(tr("Toggle Wrap"))
                        .keywords(["wrap", "editor"])
                        .checked(self.settings.editor_wrap)
                        .action(Box::new(ToggleWrap)),
                )
                .on_cancel(move |_window, cx| {
                    let _ = cancel_owner.update(cx, |this, cx| this.close_palette(cx));
                }),
            PaletteMode::Files => {
                let mut items: Vec<CommandItem> = Vec::new();
                if self.project_root.is_none() {
                    items.push(
                        CommandItem::new()
                            .label(tr("Open a project first"))
                            .icon(icon(LitheIcon::Project)),
                    );
                } else if self.quick_files.is_empty() {
                    items.push(
                        CommandItem::new()
                            .label(if self.quick_index_running {
                                tr("Indexing project files…")
                            } else {
                                tr("No files found")
                            })
                            .icon(icon(LitheIcon::Search)),
                    );
                } else {
                    let query = palette.read(cx).query(cx);
                    items.extend(
                        filter_files(&self.quick_files, query.as_ref(), 50)
                            .into_iter()
                            .map(|file| {
                                CommandItem::new()
                                    .label(file.relative.clone())
                                    .keywords([file.relative.clone()])
                                    .icon(icon(file_icon(&file.absolute)))
                                    .action(Box::new(OpenQuickFile(file.absolute.clone())))
                            }),
                    );
                }

                Command::new(&palette)
                    .bordered(false)
                    .placeholder(tr("Quick Open"))
                    .max_h(layout::COMMAND_PALETTE_MAX_HEIGHT)
                    .items(items)
                    .filterable(false)
                    .on_query(move |_query, _window, cx| {
                        let _ = query_owner.update(cx, |_this, cx| cx.notify());
                    })
                    .on_cancel(move |_window, cx| {
                        let _ = cancel_owner.update(cx, |this, cx| this.close_palette(cx));
                    })
            }
            PaletteMode::History => {
                let query = palette.read(cx).query(cx).to_lowercase();
                let items: Vec<CommandItem> = self
                    .history_snapshots
                    .iter()
                    .filter(|snapshot| {
                        query.is_empty()
                            || format_time(snapshot.recorded)
                                .to_lowercase()
                                .contains(query.as_str())
                    })
                    .take(50)
                    .map(|snapshot| {
                        let label = format_time(snapshot.recorded);
                        CommandItem::new()
                            .label(label.clone())
                            .keywords([label])
                            .icon(icon(LitheIcon::Changes))
                            .action(Box::new(RestoreHistorySnapshot(snapshot.path.clone())))
                    })
                    .collect();

                Command::new(&palette)
                    .bordered(false)
                    .placeholder(tr("Local History…"))
                    .max_h(layout::COMMAND_PALETTE_MAX_HEIGHT)
                    .items(items)
                    .filterable(false)
                    .on_query(move |_query, _window, cx| {
                        let _ = query_owner.update(cx, |_this, cx| cx.notify());
                    })
                    .on_cancel(move |_window, cx| {
                        let _ = cancel_owner.update(cx, |this, cx| this.close_palette(cx));
                    })
            }
        };

        div()
            .id("lithe-command-palette-overlay")
            .absolute()
            .inset_0()
            .size_full()
            .flex()
            .items_start()
            .justify_center()
            .pt(layout::COMMAND_PALETTE_TOP)
            .occlude()
            .track_focus(&self.overlay_focus)
            .key_context(OVERLAY_CONTEXT)
            .on_action(cx.listener(Self::on_action_dismiss_overlay))
            .child(
                div()
                    .id("lithe-command-palette-backdrop")
                    .absolute()
                    .inset_0()
                    .size_full()
                    .occlude()
                    .bg(tokens.window.alpha(0.55))
                    .on_click(move |_event: &ClickEvent, _window, cx| {
                        let _ = backdrop_owner.update(cx, |this, cx| this.close_palette(cx));
                    }),
            )
            .child(
                div()
                    .occlude()
                    .w(layout::COMMAND_PALETTE_WIDTH)
                    .rounded(px(LitheMetrics::PANE_RADIUS))
                    .overflow_hidden()
                    .bg(tokens.raised)
                    .border_1()
                    .border_color(tokens.panel_border)
                    .child(command),
            )
            .into_any_element()
    }

    pub(crate) fn open_palette(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.settings_visible = false;
        self.notifications_visible = false;
        self.pending_close_tab = None;
        self.project_menu_visible = false;
        self.branch_menu_visible = false;
        self.palette_visible = true;

        let Some(palette) = self.palette.clone() else {
            cx.notify();
            return;
        };
        palette.update(cx, |state, state_cx| {
            state.set_query("", window, state_cx);
            state.focus(window, state_cx);
        });
        cx.notify();
    }

    pub(crate) fn open_quick_open(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.settings_visible = false;
        self.notifications_visible = false;
        self.pending_close_tab = None;
        self.project_menu_visible = false;
        self.branch_menu_visible = false;
        self.palette_mode = PaletteMode::Files;
        self.palette_visible = true;

        let Some(palette) = self.palette.clone() else {
            cx.notify();
            return;
        };
        palette.update(cx, |state, state_cx| {
            state.set_query("", window, state_cx);
            state.focus(window, state_cx);
        });

        if self.project_root.is_some() && self.quick_files.is_empty() && !self.quick_index_running {
            self.refresh_quick_index(window, cx);
        }
        cx.notify();
    }

    pub(crate) fn open_local_history(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(path) = self.active_tab_path() else {
            return;
        };

        let snapshots = lithe_features::local_history::snapshots(&path);
        if snapshots.is_empty() {
            self.push_notification(
                tr("Local History…"),
                tr("No snapshots yet").into(),
                NotificationKind::Info,
            );
            cx.notify();
            return;
        }

        self.settings_visible = false;
        self.notifications_visible = false;
        self.pending_close_tab = None;
        self.project_menu_visible = false;
        self.branch_menu_visible = false;
        self.history_snapshots = snapshots;
        self.history_target = Some(path);
        self.palette_mode = PaletteMode::History;
        self.palette_visible = true;

        let Some(palette) = self.palette.clone() else {
            cx.notify();
            return;
        };
        palette.update(cx, |state, state_cx| {
            state.set_query("", window, state_cx);
            state.focus(window, state_cx);
        });
        cx.notify();
    }

    pub(crate) fn refresh_quick_index(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(root) = self.project_root.clone() else {
            self.quick_files.clear();
            self.quick_index_generation = self.quick_index_generation.wrapping_add(1);
            self.quick_index_running = false;
            cx.notify();
            return;
        };

        self.quick_index_generation = self.quick_index_generation.wrapping_add(1);
        let generation = self.quick_index_generation;
        self.quick_index_running = true;
        cx.notify();

        cx.spawn_in(window, async move |this, cx| {
            let files = cx
                .background_spawn(async move { index_project(&root, 20_000) })
                .await;
            let _ = this.update_in(cx, move |this, _window, cx| {
                if this.quick_index_generation != generation {
                    return;
                }
                this.quick_files = files;
                this.quick_index_running = false;
                cx.notify();
            });
        })
        .detach();
    }

    pub(crate) fn close_palette(&mut self, cx: &mut Context<Self>) {
        if self.palette_visible {
            self.palette_visible = false;
            self.palette_mode = PaletteMode::Commands;
            self.history_snapshots.clear();
            self.history_target = None;
            cx.notify();
        }
    }
}
