//! 语言分类侧栏与运行配置列表。

use std::collections::BTreeMap;

use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::checkbox::Checkbox;
use gpui_kit::component::{Icon, IconName, h_flex, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, ClickEvent, Context, FontWeight, InteractiveElement as _, SharedString,
    StatefulInteractiveElement as _, Styled as _, px,
};
use lithe_ui::i18n::tr;
use lithe_ui::{LitheIcon, LitheMetrics, LitheTokens, icon};

use super::model::{RunConfiguration, RunExecution, RunLanguage};
use super::state::SessionState;
use super::{CONFIGURATION_ROW_HEIGHT, GROUP_HEADER_HEIGHT, RunPanel};

impl RunPanel {
    /// 当前可见的配置：先按语言分类过滤，再排除 group 类型。
    ///
    /// 对齐 Tauri `runConfigurationLanguageGroups`：`runnableConfigurations` 去掉
    /// 内置的 “Current File” 后，再把 `execution === "group"` 排除掉——分组不是
    /// 可启动目标，只用于组织。
    fn configurations_for_language(&self, language: RunLanguage) -> Vec<&RunConfiguration> {
        self.configurations
            .iter()
            .filter(|configuration| configuration.execution != RunExecution::Group)
            .filter(|configuration| configuration.language() == language)
            .collect()
    }

    /// 侧栏里实际有配置的语言分类，按 [`RunLanguage::ORDER`] 固定排序。
    fn visible_languages(&self) -> Vec<RunLanguage> {
        RunLanguage::ORDER
            .into_iter()
            .filter(|language| {
                self.configurations
                    .iter()
                    .any(|configuration| configuration.language() == *language)
            })
            .collect()
    }

    /// 语言分类侧栏。对齐 Tauri `RunConfigurationBrowser` 的 `languages` 面板：
    /// 只列出有配置的分类，顺序固定，选中项切换列表内容并选中该分类第一条配置。
    pub(super) fn render_language_rail(
        &self,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let languages = self.visible_languages();
        // 当前选中配置所属分类优先；用户手动切换过就用那个分类。都没有时
        // 退回第一个有配置的分类，不伪造一个空列表。
        let current = self
            .selected_configuration()
            .map(RunConfiguration::language)
            .filter(|language| languages.contains(language))
            .or_else(|| {
                self.selected_language
                    .as_deref()
                    .and_then(RunLanguage::from_key)
                    .filter(|language| languages.contains(language))
            })
            .or_else(|| languages.first().copied());

        let mut rail = v_flex()
            .id("lithe-run-languages")
            .w(px(100.0))
            .flex_shrink_0()
            .h_full()
            .gap(px(2.0))
            .p(px(4.0))
            .overflow_y_scroll()
            .bg(tokens.sidebar)
            .border_r_1()
            .border_color(tokens.divider);

        for language in languages {
            let is_selected = current == Some(language);
            let title = language.title();
            rail = rail.child(
                Button::new(format!("lithe-run:lang:{}", language.key()))
                    .ghost()
                    .w_full()
                    .h(px(26.0))
                    .px(px(8.0))
                    .rounded(px(4.0))
                    .when(is_selected, |this| this.bg(tokens.selection))
                    .child(
                        h_flex()
                            .w_full()
                            .items_center()
                            .gap(px(6.0))
                            .child(icon(language.icon()).with_size(px(14.0)).text_color(
                                if is_selected {
                                    tokens.tool_window_selected_text
                                } else {
                                    tokens.primary_text
                                },
                            ))
                            .child(
                                div()
                                    .min_w(px(0.0))
                                    .flex_1()
                                    .truncate()
                                    .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                                    .font_weight(if is_selected {
                                        FontWeight::SEMIBOLD
                                    } else {
                                        FontWeight::NORMAL
                                    })
                                    .text_color(if is_selected {
                                        tokens.tool_window_selected_text
                                    } else {
                                        tokens.primary_text
                                    })
                                    .child(title),
                            ),
                    )
                    .on_click(cx.listener(move |this, _, _window, cx| {
                        // 切成该分类的第一条配置，和 Tauri `props.onSelect(group.configurations[0].id)`
                        // 一致：只切分类而不选中任何配置，会让右边的输出区读不到会话。
                        if let Some(first) = this.configurations_for_language(language).first() {
                            this.selected_id = Some(first.id.clone());
                        }
                        this.selected_language = Some(language.key().to_string());
                        this.show_details = false;
                        this.emit(cx);
                        cx.notify();
                    })),
            );
        }

        rail.into_any_element()
    }

    pub(super) fn render_configuration_list(
        &self,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        // 与侧栏共用同一判据：当前分类 = 选中配置所属分类，否则用用户上次切换
        // 的分类，再否则第一个有配置的分类。之前这里默认写死 "Java"，导致非 Java
        // 项目的列表在没切换侧栏时永远为空。
        let languages = self.visible_languages();
        let current_language = self
            .selected_configuration()
            .map(RunConfiguration::language)
            .filter(|language| languages.contains(language))
            .or_else(|| {
                self.selected_language
                    .as_deref()
                    .and_then(RunLanguage::from_key)
                    .filter(|language| languages.contains(language))
            })
            .or_else(|| languages.first().copied());

        let configurations = current_language
            .map(|language| self.configurations_for_language(language))
            .unwrap_or_default();

        let mut list = v_flex()
            .id("lithe-run-configurations")
            .w_full()
            .flex_shrink_0()
            .h_full()
            .min_h(px(0.0))
            .overflow_y_scroll()
            .bg(tokens.sidebar)
            .border_r_1()
            .border_color(tokens.divider);

        if configurations.is_empty() {
            list = list.child(
                div()
                    .w_full()
                    .p(px(12.0))
                    .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                    .text_color(tokens.secondary_text)
                    .child(tr("No configurations in this scope")),
            );
            return list.into_any_element();
        }

        for (group_title, group) in self.group_configurations(&configurations) {
            let representative = group.first().copied();
            let group_icon = representative.map(|c| c.icon());
            let is_collapsed = self.collapsed_groups.contains(&group_title);
            let toggle_title = group_title.clone();
            let group_slug = group_title.replace(' ', "-");
            list = list.child(
                h_flex()
                    .id(SharedString::from(format!(
                        "lithe-run:group-header:{group_slug}"
                    )))
                    .w_full()
                    .flex_shrink_0()
                    .h(px(GROUP_HEADER_HEIGHT))
                    .items_center()
                    .gap(px(6.0))
                    .px(px(8.0))
                    .cursor_pointer()
                    .hover(|style| style.bg(tokens.hover))
                    .on_click(cx.listener(move |this, _, _, cx| {
                        if this.collapsed_groups.contains(&toggle_title) {
                            this.collapsed_groups.remove(&toggle_title);
                        } else {
                            this.collapsed_groups.insert(toggle_title.clone());
                        }
                        cx.notify();
                    }))
                    .child(
                        div()
                            .id(SharedString::from(format!(
                                "lithe-run:chevron:{group_slug}"
                            )))
                            .p(px(2.0))
                            .rounded(px(4.0))
                            .child(
                                Icon::new(if is_collapsed {
                                    IconName::ChevronRight
                                } else {
                                    IconName::ChevronDown
                                })
                                .with_size(px(12.0))
                                .text_color(tokens.secondary_text),
                            ),
                    )
                    .when_some(group_icon, |this, icon_kind| {
                        let color = if icon_kind == LitheIcon::Spring {
                            tokens.success
                        } else {
                            tokens.secondary_text
                        };
                        this.child(icon(icon_kind).with_size(px(14.0)).text_color(color))
                    })
                    .child(
                        div()
                            .min_w(px(0.0))
                            .flex_1()
                            .truncate()
                            .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(tokens.secondary_text)
                            .child(group_title),
                    )
                    .child(
                        div()
                            .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                            .text_color(tokens.tertiary_text)
                            .child(group.len().to_string()),
                    ),
            );
            if !is_collapsed {
                for configuration in group {
                    list = list.child(self.render_configuration_row(&configuration, tokens, cx));
                }
            }
        }

        list.into_any_element()
    }

    fn render_configuration_row(
        &self,
        configuration: &RunConfiguration,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let id = configuration.id.clone();
        let selected = self.selected_id.as_deref() == Some(id.as_str());
        let _pinned = self.pinned.contains(&id);
        let session = self.sessions.get(&id);
        let starting = session.is_some_and(|session| session.starting);
        let stopped = session.is_some_and(|session| session.stopped);
        let running = session.is_some_and(SessionState::is_active);
        let exit_code = session.and_then(|session| session.exit_code);
        let foreground = if selected {
            tokens.tool_window_selected_text
        } else {
            tokens.primary_text
        };
        let status_color = if starting {
            tokens.warning
        } else if running {
            tokens.success
        } else if stopped {
            tokens.tertiary_text
        } else if exit_code == Some(0) {
            tokens.success
        } else if exit_code.is_some() {
            tokens.error
        } else {
            tokens.tertiary_text
        };
        let configuration_for_click = configuration.clone();
        let id_for_toggle = id.clone();
        let id_for_settings = id.clone();
        let id_for_check = id.clone();
        let is_checked = self.checked.contains(&id);

        h_flex()
            .id(format!("lithe-run:configuration:{id}"))
            .w_full()
            .flex_shrink_0()
            .h(px(CONFIGURATION_ROW_HEIGHT))
            .items_center()
            .gap(px(6.0))
            .px(px(8.0))
            .when(selected, |this| this.bg(tokens.selection))
            .when(!selected, |this| this.hover(|style| style.bg(tokens.hover)))
            .on_click(cx.listener(move |this, event: &ClickEvent, _window, cx| {
                this.selected_id = Some(configuration_for_click.id.clone());
                this.show_details = false;
                // 切换会话：重置跟随，不继承上一个会话的滚动位置。
                this.console.reset();
                this.console_follow_tail = true;
                this.emit(cx);
                if event.click_count() >= 2 {
                    this.start_configuration(configuration_for_click.id.clone(), cx);
                }
                cx.notify();
            }))
            // 批量模式才出现勾选框：平时行内只保留图标、名称、状态点和动作按钮。
            .when(self.batch_selection, |this| {
                this.child(
                    Checkbox::new(SharedString::from(format!("lithe-run:checked:{id}")))
                        .checked(is_checked)
                        .on_click(cx.listener(move |this, _, _window, cx| {
                            this.toggle_checked(&id_for_check, cx);
                        })),
                )
            })
            .child(
                icon(configuration.icon())
                    .with_size(px(LitheMetrics::TREE_ICON_SIZE))
                    .text_color(foreground),
            )
            .child(
                div()
                    .min_w(px(0.0))
                    .flex_1()
                    .truncate()
                    .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                    .text_color(foreground)
                    .child(configuration.name.clone()),
            )
            .child(div().size(px(6.0)).rounded_full().bg(status_color))
            .child(
                Button::new(format!("lithe-run:edit:{id}"))
                    .ghost()
                    .with_size(px(20.0))
                    .rounded(px(2.0))
                    .child(Icon::new(IconName::Settings).with_size(px(12.0)))
                    .tooltip(tr("Edit Service"))
                    .accessibility_label(tr("Edit Service"))
                    .on_click(cx.listener(move |this, _, window, cx| {
                        this.invoke_open_settings(&id_for_settings, window, cx);
                    })),
            )
            .child(
                Button::new(format!("lithe-run:toggle:{id}"))
                    .ghost()
                    .with_size(px(20.0))
                    .rounded(px(2.0))
                    .child(
                        Icon::new(if running {
                            IconName::Square
                        } else {
                            IconName::Play
                        })
                        .with_size(px(12.0))
                        .text_color(if running {
                            tokens.warning
                        } else {
                            tokens.success
                        }),
                    )
                    .tooltip(tr(if running { "Stop" } else { "Run" }))
                    .on_click(cx.listener(move |this, _, _window, cx| {
                        this.selected_id = Some(id_for_toggle.clone());
                        this.show_details = false;
                        this.console.reset();
                        this.console_follow_tail = true;
                        this.emit(cx);
                        if let Some(session) = this.sessions.get(&id_for_toggle) {
                            if session.is_active() {
                                this.stop_configuration(&id_for_toggle, cx);
                                return;
                            }
                        }
                        this.start_configuration(id_for_toggle.clone(), cx);
                    })),
            )
            .into_any_element()
    }

    /// 按配置类型分组（Java / Maven / Node.js …），组内按名称排序，保证渲染顺序确定。
    fn group_configurations<'a>(
        &self,
        configurations: &[&'a RunConfiguration],
    ) -> Vec<(String, Vec<&'a RunConfiguration>)> {
        let mut groups: BTreeMap<String, Vec<&RunConfiguration>> = BTreeMap::new();
        for configuration in configurations {
            groups
                .entry(configuration.kind_title())
                .or_default()
                .push(configuration);
        }
        let mut groups: Vec<_> = groups.into_iter().collect();
        groups.sort_by(|left, right| left.0.to_lowercase().cmp(&right.0.to_lowercase()));
        for (_, group) in &mut groups {
            group.sort_by(|left, right| {
                left.name
                    .to_lowercase()
                    .cmp(&right.name.to_lowercase())
                    .then_with(|| left.id.cmp(&right.id))
            });
        }
        groups
    }
}
