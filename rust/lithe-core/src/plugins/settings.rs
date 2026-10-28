//! User-adjustable options of a declarative plugin: their declaration, the
//! values a host may store for them, and how stored layers become the value
//! a launch uses.
//!
//! Version 1 of the `settings` capability is the API level 2 section:
//! integer, enum, and boolean options stored once per plugin. Version 2 adds
//! the fields hosts need to place and apply a setting without plugin-specific
//! code: which settings page shows it (`page`, `section`), whether a project
//! may override it (`scope`), when a change takes effect (`effect`), and the
//! `multiSelect`, `text`, `file`, and `directory` types.
//!
//! Hosts never merge values themselves. They send the stored layers and Core
//! answers with the effective value of every setting and the layer it came
//! from, so both products show and launch with the same value.
//!
//! Note: the decision is recorded in .agents/notes/implemented/architecture/2026-10-21-plugin-settings-surfaces.md

use super::declarative::{invalid, PluginRejection, Validation};
use regex::Regex;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{BTreeMap, BTreeSet};

/// A whole number within a declared range.
const SETTING_INTEGER: &str = "integer";
/// One of a declared list of values.
const SETTING_ENUM: &str = "enum";
/// On or off.
const SETTING_BOOLEAN: &str = "boolean";
/// Any subset of a declared list of values. `settings` 2.
const SETTING_MULTI_SELECT: &str = "multiSelect";
/// Free text that matches a declared pattern. `settings` 2.
const SETTING_TEXT: &str = "text";
/// An absolute path to a file, or empty. `settings` 2.
const SETTING_FILE: &str = "file";
/// An absolute path to a directory, or empty. `settings` 2.
const SETTING_DIRECTORY: &str = "directory";
/// Most choices one enum setting may offer.
const MAX_ENUM_OPTIONS: usize = 16;
/// Most choices one multiSelect setting may offer.
const MAX_MULTI_SELECT_OPTIONS: usize = 32;
/// Longest setting ID, option value, title, unit, and section heading.
pub(crate) const MAX_SETTING_TEXT: usize = 120;
/// Longest pattern a text setting may declare.
const MAX_PATTERN: usize = 256;
/// Default and largest `maxLength` of a text setting.
const DEFAULT_TEXT_LENGTH: u32 = 256;
const MAX_TEXT_LENGTH: u32 = 1024;
/// Longest path a file or directory setting may hold.
const MAX_PATH_LENGTH: usize = 1024;

/// Where a project may replace the value the user chose for every project.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) enum SettingScope {
    /// One value for every workspace.
    Global,
    /// A workspace may override the global value.
    Project,
}

/// When a changed value reaches what it configures. Hosts use it to decide
/// what to do after a change: nothing, push it, restart, or reload.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) enum SettingEffect {
    /// The next start of the plugin's processes uses it.
    Restart,
    /// Pushed to running language servers through `workspaceConfiguration`.
    Immediate,
    /// The next build-model reload uses it.
    Reload,
    /// The next run or build command uses it.
    NextRun,
    /// Immediately enables definition navigation for the declared language.
    EditorNavigation,
}

/// The settings page that shows a setting besides the plugin's own page.
/// A plugin may add a setting to a language or build system another plugin
/// declares; the host shows the page while any plugin contributes to it.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) enum SettingPage {
    /// Languages & Frameworks › <language>.
    #[serde(rename = "languageID")]
    Language(String),
    /// Build Tools › <build system>.
    #[serde(rename = "buildSystemID")]
    BuildSystem(String),
}

/// A button the host draws on a settings page that invokes one of the same
/// plugin's [plugin functions](crate::lsp::interface::plugin_function). The
/// host owns the button; the plugin owns what the function does, so a
/// "Reindex" or "Download sources" action needs no host code. `settings` 2.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct SettingAction {
    /// Identifier, unique among the plugin's actions.
    pub(crate) id: String,
    /// Button label.
    title: String,
    /// Explanation shown next to the button.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    description: Option<String>,
    /// Page the button appears on besides the plugin's own page.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    page: Option<SettingPage>,
    /// Heading the button is grouped under on its page.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    section: Option<String>,
    /// Plugin function the button invokes with empty params. It is served
    /// by the plugin's own provider process for the open project; without
    /// one, the host reports the action as unavailable instead of running it.
    function: String,
    /// Ask before invoking, for actions that discard state.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    confirm: bool,
}

/// Most actions one plugin may declare.
pub(crate) const MAX_SETTING_ACTIONS: usize = 16;

impl SettingAction {
    pub(crate) fn validate(&self, field: &str) -> Validation<()> {
        if !is_setting_identifier(&self.id) {
            return Err(invalid(
                format!("{field}.id"),
                "An action ID starts with a lowercase letter and contains only letters and digits.",
            ));
        }
        check_label(
            &self.title,
            &format!("{field}.title"),
            "An action needs a short title.",
        )?;
        if self
            .description
            .as_ref()
            .is_some_and(|description| description.chars().count() > MAX_SETTING_TEXT * 4)
        {
            return Err(invalid(
                format!("{field}.description"),
                "The description is too long.",
            ));
        }
        if let Some(section) = &self.section {
            check_label(
                section,
                &format!("{field}.section"),
                "A section heading is short text.",
            )?;
        }
        if let Some(page) = &self.page {
            check_page(page, field)?;
        }
        if !crate::lsp::interface::plugin_function::is_function_id(&self.function) {
            return Err(invalid(
                format!("{field}.function"),
                "An action names a plugin function ID.",
            ));
        }
        Ok(())
    }
}

fn check_page(page: &SettingPage, field: &str) -> Validation<()> {
    let (key, id) = match page {
        SettingPage::Language(id) => ("languageID", id),
        SettingPage::BuildSystem(id) => ("buildSystemID", id),
    };
    if !is_setting_option_value(id) {
        return Err(invalid(
            format!("{field}.page.{key}"),
            "A settings page names a language or build system ID.",
        ));
    }
    Ok(())
}

/// One option the user may change. The plugin names it in launch templates
/// as `${setting:<id>}`; the value is always one of the declared shapes, so
/// it cannot add arguments or select files inside the package.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct SettingDeclaration {
    /// Identifier used in `${setting:<id>}` and as the stored key.
    pub(crate) id: String,
    /// One of the `SETTING_*` kinds.
    #[serde(rename = "type")]
    kind: String,
    /// Label shown next to the control.
    title: String,
    /// Explanation shown under the control.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    description: Option<String>,
    /// Value used until the user changes it, and whenever a stored value is
    /// no longer acceptable. Its JSON type follows `kind`.
    pub(crate) default: Value,
    /// Inclusive lower bound of an integer setting.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    minimum: Option<i64>,
    /// Inclusive upper bound of an integer setting.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    maximum: Option<i64>,
    /// Unit label of an integer setting, such as `MB`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    unit: Option<String>,
    /// Choices of an enum or multiSelect setting, in display order.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    options: Vec<SettingOption>,
    /// Whether a project may override the value. `settings` 2; `global`
    /// when absent.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    scope: Option<SettingScope>,
    /// When a change takes effect. `settings` 2; `restart` when absent.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    effect: Option<SettingEffect>,
    /// Page that shows the setting besides the plugin's own. `settings` 2.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) page: Option<SettingPage>,
    /// Heading the setting is grouped under on its page. `settings` 2.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    section: Option<String>,
    /// Regular expression a text value must match as a whole. Required for
    /// text settings. `settings` 2.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pattern: Option<String>,
    /// Longest text value, in characters. `settings` 2.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    max_length: Option<u32>,
    /// Hint shown in an empty text, file, or directory field. `settings` 2.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    placeholder: Option<String>,
}

/// One choice of an enum or multiSelect setting.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct SettingOption {
    /// Text substituted into templates and stored.
    value: String,
    /// Label shown to the user.
    title: String,
}

/// Setting IDs a template may name, with the restrictions their kinds carry.
#[derive(Debug, Clone, Default)]
pub(crate) struct DeclaredSettings {
    /// Global paths that may explicitly select a build executable.
    executables: BTreeSet<String>,
    /// Settings a launch reads when it starts.
    launch: BTreeSet<String>,
    /// Settings that are only pushed to a running server.
    immediate: BTreeSet<String>,
    /// Settings whose value must be a whole value or follow `name=`, because
    /// it is free text or a path.
    whole_value: BTreeSet<String>,
    /// Settings that hold the path of one file, whatever their scope.
    files: BTreeSet<String>,
}

impl DeclaredSettings {
    /// Whether the global file setting may select the build executable.
    pub(crate) fn is_executable(&self, id: &str) -> bool {
        self.executables.contains(id)
    }

    /// Whether the setting holds the path of one file, so a declaration can
    /// read the file the user chose.
    pub(crate) fn is_file(&self, id: &str) -> bool {
        self.files.contains(id)
    }

    /// Whether a start-time template may name the setting.
    pub(crate) fn contains(&self, id: &str) -> bool {
        self.launch.contains(id)
    }

    /// Whether the setting exists but only applies through
    /// `workspaceConfiguration`.
    pub(crate) fn is_immediate(&self, id: &str) -> bool {
        self.immediate.contains(id)
    }

    /// Whether a template must use the setting as a whole value.
    pub(crate) fn requires_whole_value(&self, id: &str) -> bool {
        self.whole_value.contains(id)
    }

    pub(crate) fn first_unreferenced_immediate(
        &self,
        references: &BTreeSet<String>,
    ) -> Option<String> {
        self.immediate.difference(references).next().cloned()
    }

    /// The settings `workspaceConfiguration` may name: every one, since
    /// the host re-expands it whenever a value changes.
    pub(crate) fn for_configuration(&self) -> Self {
        let mut all = self.clone();
        all.launch.extend(self.immediate.iter().cloned());
        all.immediate.clear();
        all
    }
}

/// Layer the effective value of a setting came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) enum SettingSource {
    Default,
    Global,
    Project,
}

/// Effective value of one setting and the layer it came from.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ResolvedSetting {
    pub(crate) id: String,
    pub(crate) value: Value,
    pub(crate) source: SettingSource,
}

/// Values a host stored for one plugin's settings.
#[derive(Debug, Clone, Copy)]
pub(crate) struct SettingLayers<'a> {
    /// The user's value for every workspace, by setting ID.
    pub(crate) global: &'a BTreeMap<String, Value>,
    /// The current workspace's overrides, by setting ID.
    pub(crate) project: &'a BTreeMap<String, Value>,
}

impl SettingDeclaration {
    /// Unlike display/configuration settings, an explicit invalid executable
    /// value must terminate resolution rather than silently choose a default.
    pub(crate) fn executable_value(&self, stored: Option<&Value>) -> Validation<Option<String>> {
        let value = stored.unwrap_or(&self.default);
        let valid = self.accepts(value)
            && value.as_str().is_some_and(|path| {
                path.is_empty()
                    || (path.trim() == path
                        && !path.chars().any(char::is_control)
                        && (path.starts_with('/')
                            || (path.len() >= 3
                                && path.as_bytes()[0].is_ascii_alphabetic()
                                && path.as_bytes()[1] == b':'
                                && matches!(path.as_bytes()[2], b'/' | b'\\'))
                            || path.starts_with("\\\\")))
            });
        if !valid {
            return Err(PluginRejection::at("plugin.build.invalidSelection", format!("settings.{}", self.id), "The configured executable must be an absolute file path satisfying the setting constraints."));
        }
        Ok(value
            .as_str()
            .filter(|path| !path.is_empty())
            .map(str::to_owned))
    }

    fn is_version_2_kind(&self) -> bool {
        matches!(
            self.kind.as_str(),
            SETTING_MULTI_SELECT | SETTING_TEXT | SETTING_FILE | SETTING_DIRECTORY
        )
    }

    fn uses_version_2_fields(&self) -> bool {
        self.scope.is_some()
            || self.effect.is_some()
            || self.page.is_some()
            || self.section.is_some()
            || self.pattern.is_some()
            || self.max_length.is_some()
            || self.placeholder.is_some()
    }

    pub(crate) fn effect(&self) -> SettingEffect {
        self.effect.unwrap_or(SettingEffect::Restart)
    }

    fn scope(&self) -> SettingScope {
        self.scope.unwrap_or(SettingScope::Global)
    }

    /// Text and paths come from the user unchecked by any option list.
    fn is_free_form(&self) -> bool {
        matches!(
            self.kind.as_str(),
            SETTING_TEXT | SETTING_FILE | SETTING_DIRECTORY
        )
    }

    fn text_pattern(&self) -> Option<Regex> {
        self.pattern
            .as_ref()
            .and_then(|pattern| Regex::new(&format!("^(?:{pattern})$")).ok())
    }

    /// Whether `value` is a value this setting can hold.
    pub(crate) fn accepts(&self, value: &Value) -> bool {
        match self.kind.as_str() {
            SETTING_INTEGER => value.as_i64().is_some_and(|number| {
                self.minimum.is_none_or(|minimum| number >= minimum)
                    && self.maximum.is_none_or(|maximum| number <= maximum)
            }),
            SETTING_ENUM => value.as_str().is_some_and(|text| self.offers(text)),
            SETTING_BOOLEAN => value.is_boolean(),
            SETTING_MULTI_SELECT => value.as_array().is_some_and(|items| {
                let mut seen = BTreeSet::new();
                items.iter().all(|item| {
                    item.as_str()
                        .is_some_and(|text| self.offers(text) && seen.insert(text))
                })
            }),
            SETTING_TEXT => value.as_str().is_some_and(|text| {
                text.chars().count() <= self.max_length.unwrap_or(DEFAULT_TEXT_LENGTH) as usize
                    && is_safe_free_text(text)
                    && self
                        .text_pattern()
                        .is_some_and(|pattern| pattern.is_match(text))
            }),
            SETTING_FILE | SETTING_DIRECTORY => value.as_str().is_some_and(|text| {
                text.is_empty()
                    || (text.chars().count() <= MAX_PATH_LENGTH
                        && is_safe_free_text(text)
                        && is_absolute_path(text))
            }),
            _ => false,
        }
    }

    fn offers(&self, value: &str) -> bool {
        self.options.iter().any(|option| option.value == value)
    }

    /// Checks the declaration against the `settings` capability version the
    /// manifest was written for.
    pub(crate) fn validate(&self, field: &str, version: u32) -> Validation<()> {
        if version < 2 && (self.is_version_2_kind() || self.uses_version_2_fields()) {
            return Err(invalid(
                field.to_string(),
                "This setting requires version 2 of the settings capability.",
            ));
        }
        if self.effect() == SettingEffect::EditorNavigation
            && (version < 3
                || self.kind != SETTING_BOOLEAN
                || self.scope() != SettingScope::Global
                || !matches!(self.page, Some(SettingPage::Language(_))))
        {
            return Err(invalid(
                field.to_string(),
                "Editor navigation requires settings 3, a global boolean, and a language page.",
            ));
        }
        if !is_setting_identifier(&self.id) {
            return Err(invalid(
                format!("{field}.id"),
                "A setting ID starts with a lowercase letter and contains only letters and digits.",
            ));
        }
        check_label(
            &self.title,
            &format!("{field}.title"),
            "A setting needs a short title.",
        )?;
        if self
            .description
            .as_ref()
            .is_some_and(|description| description.chars().count() > MAX_SETTING_TEXT * 4)
        {
            return Err(invalid(
                format!("{field}.description"),
                "The description is too long.",
            ));
        }
        if let Some(section) = &self.section {
            check_label(
                section,
                &format!("{field}.section"),
                "A section heading is short text.",
            )?;
        }
        if let Some(placeholder) = &self.placeholder {
            if !self.is_free_form() {
                return Err(invalid(
                    format!("{field}.placeholder"),
                    "Only text, file, and directory settings show a placeholder.",
                ));
            }
            check_label(
                placeholder,
                &format!("{field}.placeholder"),
                "A placeholder is short text.",
            )?;
        }
        if let Some(page) = &self.page {
            check_page(page, field)?;
        }
        self.validate_shape(field)
    }

    fn validate_shape(&self, field: &str) -> Validation<()> {
        let shape = |message: &str| invalid(format!("{field}.{}", self.id), message.to_string());
        let has_range = self.minimum.is_some() || self.maximum.is_some() || self.unit.is_some();
        let has_text_rules = self.pattern.is_some() || self.max_length.is_some();
        match self.kind.as_str() {
            SETTING_INTEGER => {
                let (Some(minimum), Some(maximum)) = (self.minimum, self.maximum) else {
                    return Err(shape("An integer setting declares minimum and maximum."));
                };
                if minimum > maximum || !self.accepts(&self.default) {
                    return Err(invalid(
                        format!("{field}.default"),
                        "The default must be a whole number between minimum and maximum.",
                    ));
                }
                if !self.options.is_empty() || has_text_rules {
                    return Err(shape("An integer setting has no options or pattern."));
                }
                if let Some(unit) = &self.unit {
                    check_label(
                        unit,
                        &format!("{field}.unit"),
                        "The unit is empty or too long.",
                    )?;
                }
            }
            SETTING_ENUM | SETTING_MULTI_SELECT => {
                let multiple = self.kind == SETTING_MULTI_SELECT;
                let most = if multiple {
                    MAX_MULTI_SELECT_OPTIONS
                } else {
                    MAX_ENUM_OPTIONS
                };
                if self.options.is_empty() || self.options.len() > most {
                    return Err(invalid(
                        format!("{field}.options"),
                        if multiple {
                            "A multiSelect setting offers between one and thirty-two options."
                        } else {
                            "An enum setting offers between one and sixteen options."
                        },
                    ));
                }
                self.validate_options(field)?;
                if !self.accepts(&self.default) {
                    return Err(invalid(
                        format!("{field}.default"),
                        if multiple {
                            "The default must be a list of distinct options."
                        } else {
                            "The default must be one of the options."
                        },
                    ));
                }
                if has_range || has_text_rules {
                    return Err(shape("A choice setting has no range, unit, or pattern."));
                }
            }
            SETTING_BOOLEAN => {
                if !self.accepts(&self.default) {
                    return Err(invalid(
                        format!("{field}.default"),
                        "The default of a boolean setting is true or false.",
                    ));
                }
                if has_range || has_text_rules || !self.options.is_empty() {
                    return Err(shape("A boolean setting has no range, unit, or options."));
                }
            }
            SETTING_TEXT => {
                let Some(pattern) = &self.pattern else {
                    return Err(invalid(
                        format!("{field}.pattern"),
                        "A text setting declares the pattern its value must match.",
                    ));
                };
                if pattern.is_empty()
                    || pattern.len() > MAX_PATTERN
                    || self.text_pattern().is_none()
                {
                    return Err(invalid(
                        format!("{field}.pattern"),
                        "The pattern is not a valid regular expression of at most 256 bytes.",
                    ));
                }
                if self
                    .max_length
                    .is_some_and(|length| length == 0 || length > MAX_TEXT_LENGTH)
                {
                    return Err(invalid(
                        format!("{field}.maxLength"),
                        "maxLength is between 1 and 1024.",
                    ));
                }
                if !self.accepts(&self.default) {
                    return Err(invalid(
                        format!("{field}.default"),
                        "The default must match the pattern and must not start with '-'.",
                    ));
                }
                if has_range || !self.options.is_empty() {
                    return Err(shape("A text setting has no range, unit, or options."));
                }
            }
            SETTING_FILE | SETTING_DIRECTORY => {
                if self.default != Value::String(String::new()) {
                    return Err(invalid(
                        format!("{field}.default"),
                        "A file or directory setting starts empty.",
                    ));
                }
                if has_range || has_text_rules || !self.options.is_empty() {
                    return Err(shape(
                        "A file or directory setting has no range, unit, options, or pattern.",
                    ));
                }
            }
            other => {
                return Err(invalid(
                    format!("{field}.type"),
                    format!("The setting type {other} is not supported."),
                ));
            }
        }
        Ok(())
    }

    fn validate_options(&self, field: &str) -> Validation<()> {
        let mut values = BTreeSet::new();
        for (index, option) in self.options.iter().enumerate() {
            let option_field = format!("{field}.options[{index}]");
            if !is_setting_option_value(&option.value) {
                return Err(invalid(
                    format!("{option_field}.value"),
                    "An option value contains only letters, digits, '.', '_' and '-'.",
                ));
            }
            check_label(
                &option.title,
                &format!("{option_field}.title"),
                "An option needs a short title.",
            )?;
            if !values.insert(option.value.as_str()) {
                return Err(invalid(
                    format!("{option_field}.value"),
                    "An option value is declared more than once.",
                ));
            }
        }
        Ok(())
    }
}

/// Checks a manifest's settings and returns what templates may name.
pub(crate) fn declared(settings: &[SettingDeclaration]) -> DeclaredSettings {
    let mut declared = DeclaredSettings::default();
    for setting in settings {
        if setting.kind == SETTING_FILE {
            declared.files.insert(setting.id.clone());
        }
        if setting.kind == "file"
            && setting.scope() == SettingScope::Global
            && matches!(
                setting.effect(),
                SettingEffect::Reload | SettingEffect::NextRun
            )
        {
            declared.executables.insert(setting.id.clone());
        }
        if setting.effect() == SettingEffect::Immediate {
            declared.immediate.insert(setting.id.clone());
        } else if setting.effect() != SettingEffect::EditorNavigation {
            declared.launch.insert(setting.id.clone());
        }
        if setting.is_free_form() {
            declared.whole_value.insert(setting.id.clone());
        }
    }
    declared
}

/// The effective value of every declared setting: a project override when
/// the setting allows one, then the global value, then the default. A stored
/// value the declaration no longer accepts is skipped, because a plugin
/// update may narrow a range and a launch must not fail for that.
pub(crate) fn resolve(
    settings: &[SettingDeclaration],
    layers: SettingLayers<'_>,
) -> Vec<ResolvedSetting> {
    settings
        .iter()
        .map(|setting| {
            let stored = |layer: &BTreeMap<String, Value>| {
                layer
                    .get(&setting.id)
                    .filter(|value| setting.accepts(value))
                    .cloned()
            };
            let project = (setting.scope() == SettingScope::Project)
                .then(|| stored(layers.project))
                .flatten();
            let (value, source) = match (project, stored(layers.global)) {
                (Some(value), _) => (value, SettingSource::Project),
                (None, Some(value)) => (value, SettingSource::Global),
                (None, None) => (setting.default.clone(), SettingSource::Default),
            };
            ResolvedSetting {
                id: setting.id.clone(),
                value,
                source,
            }
        })
        .collect()
}

/// Effective values by setting ID, as launch templates read them.
pub(crate) fn effective_values(
    settings: &[SettingDeclaration],
    layers: SettingLayers<'_>,
) -> BTreeMap<String, Value> {
    resolve(settings, layers)
        .into_iter()
        .map(|resolved| (resolved.id, resolved.value))
        .collect()
}

/// Text a setting contributes inside a longer template: the number,
/// `true`/`false`, the text, or the chosen options joined by commas.
pub(crate) fn setting_text(value: Option<&Value>) -> String {
    match value {
        Some(Value::String(text)) => text.clone(),
        Some(Value::Array(items)) => items
            .iter()
            .filter_map(Value::as_str)
            .collect::<Vec<_>>()
            .join(","),
        Some(other) => other.to_string(),
        None => String::new(),
    }
}

pub(crate) fn is_setting_identifier(value: &str) -> bool {
    let mut characters = value.chars();
    characters
        .next()
        .is_some_and(|first| first.is_ascii_lowercase())
        && characters.all(|character| character.is_ascii_alphanumeric())
        && value.len() <= MAX_SETTING_TEXT
}

fn is_setting_option_value(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= MAX_SETTING_TEXT
        && value.chars().all(|character| {
            character.is_ascii_alphanumeric() || matches!(character, '.' | '_' | '-')
        })
}

fn check_label(text: &str, field: &str, message: &str) -> Validation<()> {
    if text.trim().is_empty() || text.chars().count() > MAX_SETTING_TEXT {
        return Err(invalid(field.to_string(), message.to_string()));
    }
    Ok(())
}

/// Free text never starts like an option and never carries control
/// characters, so even a whole argument cannot become a flag or split a line.
fn is_safe_free_text(text: &str) -> bool {
    !text.starts_with('-') && !text.chars().any(char::is_control)
}

/// `/…` on Unix-like hosts, `C:\…` or `C:/…` on Windows.
fn is_absolute_path(text: &str) -> bool {
    let bytes = text.as_bytes();
    text.starts_with('/')
        || (bytes.len() >= 3
            && bytes[0].is_ascii_alphabetic()
            && bytes[1] == b':'
            && matches!(bytes[2], b'\\' | b'/'))
}

#[cfg(test)]
mod tests {
    #[test]
    fn editor_navigation_requires_capability_three_and_never_becomes_server_configuration() {
        let value = serde_json::json!({"id":"navigation", "type":"boolean", "title":"Navigation", "default":false,
            "effect":"editorNavigation", "page":{"languageID":"java"}});
        let setting: super::SettingDeclaration = serde_json::from_value(value.clone()).unwrap();
        assert!(setting.validate("settings[0]", 2).is_err());
        assert!(setting.validate("settings[0]", 3).is_ok());
        let declared = super::declared(&[setting]);
        assert!(declared.launch.is_empty() && declared.immediate.is_empty());
        for patch in [
            serde_json::json!({"scope":"project"}),
            serde_json::json!({"page":{"buildSystemID":"maven"}}),
            serde_json::json!({"type":"integer", "default":0, "minimum":0, "maximum":1}),
        ] {
            let mut invalid = value.clone();
            invalid
                .as_object_mut()
                .unwrap()
                .extend(patch.as_object().unwrap().clone());
            let setting: super::SettingDeclaration = serde_json::from_value(invalid).unwrap();
            assert!(setting.validate("settings[0]", 3).is_err());
        }
    }

    use super::*;
    use serde_json::json;

    fn setting(value: Value) -> SettingDeclaration {
        serde_json::from_value(value).expect("fixture declaration decodes")
    }

    #[test]
    fn version_1_refuses_version_2_fields_and_types() {
        let scoped = setting(json!({
            "id": "heap", "type": "integer", "title": "Heap", "default": 1,
            "minimum": 1, "maximum": 2, "scope": "project"
        }));
        assert!(scoped.validate("settings[0]", 1).is_err());
        assert!(scoped.validate("settings[0]", 2).is_ok());
        let text = setting(json!({
            "id": "name", "type": "text", "title": "Name", "default": "a", "pattern": "[a-z]+"
        }));
        assert!(text.validate("settings[0]", 1).is_err());
        assert!(text.validate("settings[0]", 2).is_ok());
    }

    #[test]
    fn text_values_match_the_whole_pattern_and_never_look_like_flags() {
        let text = setting(json!({
            "id": "profile", "type": "text", "title": "Profile", "default": "dev",
            "pattern": "[a-z-]+", "maxLength": 8
        }));
        assert!(text.accepts(&json!("release")));
        assert!(
            !text.accepts(&json!("release1")),
            "the pattern applies to the whole value"
        );
        assert!(
            !text.accepts(&json!("-agent")),
            "a value never starts like a flag"
        );
        assert!(!text.accepts(&json!("toolongvalue")));
        let combining = setting(json!({
            "id": "profile", "type": "text", "title": "Profile", "default": "",
            "pattern": ".*", "maxLength": 2
        }));
        assert!(combining.accepts(&json!("e\u{301}")));
        assert!(!combining.accepts(&json!("e\u{301}x")));
        let missing_pattern = setting(json!({
            "id": "profile", "type": "text", "title": "Profile", "default": "dev"
        }));
        assert!(missing_pattern.validate("settings[0]", 2).is_err());
    }

    #[test]
    fn paths_are_absolute_or_empty() {
        let file = setting(json!({
            "id": "settingsFile", "type": "file", "title": "Settings", "default": ""
        }));
        assert!(file.validate("settings[0]", 2).is_ok());
        assert!(file.accepts(&json!("")));
        assert!(file.accepts(&json!("/Users/me/settings.xml")));
        assert!(file.accepts(&json!("C:\\Users\\me\\settings.xml")));
        assert!(!file.accepts(&json!("relative/settings.xml")));
        assert!(!file.accepts(&json!("/a\nb")));
    }

    #[test]
    fn multi_select_holds_distinct_declared_options() {
        let profiles = setting(json!({
            "id": "features", "type": "multiSelect", "title": "Features", "default": ["a"],
            "options": [{"value": "a", "title": "A"}, {"value": "b", "title": "B"}]
        }));
        assert!(profiles.validate("settings[0]", 2).is_ok());
        assert!(profiles.accepts(&json!(["b", "a"])));
        assert!(profiles.accepts(&json!([])));
        assert!(!profiles.accepts(&json!(["a", "a"])));
        assert!(!profiles.accepts(&json!(["c"])));
        assert_eq!(setting_text(Some(&json!(["b", "a"]))), "b,a");
    }

    #[test]
    fn project_values_win_only_for_project_scoped_settings() {
        let settings = vec![
            setting(json!({
                "id": "heap", "type": "integer", "title": "Heap", "default": 1,
                "minimum": 1, "maximum": 9, "scope": "project"
            })),
            setting(json!({
                "id": "level", "type": "enum", "title": "Level", "default": "info",
                "options": [{"value": "info", "title": "Info"}, {"value": "debug", "title": "Debug"}]
            })),
            setting(json!({
                "id": "trace", "type": "boolean", "title": "Trace", "default": false
            })),
        ];
        let global = BTreeMap::from([
            ("heap".to_string(), json!(4)),
            ("level".to_string(), json!("debug")),
            ("trace".to_string(), json!("not a boolean")),
        ]);
        let project = BTreeMap::from([
            ("heap".to_string(), json!(8)),
            ("level".to_string(), json!("info")),
        ]);
        let resolved = resolve(
            &settings,
            SettingLayers {
                global: &global,
                project: &project,
            },
        );
        assert_eq!(
            resolved,
            vec![
                ResolvedSetting {
                    id: "heap".into(),
                    value: json!(8),
                    source: SettingSource::Project
                },
                ResolvedSetting {
                    id: "level".into(),
                    value: json!("debug"),
                    source: SettingSource::Global
                },
                ResolvedSetting {
                    id: "trace".into(),
                    value: json!(false),
                    source: SettingSource::Default
                },
            ]
        );
    }

    #[test]
    fn immediate_settings_are_only_declared_for_configuration() {
        let settings = vec![
            setting(json!({
                "id": "hints", "type": "boolean", "title": "Hints", "default": true, "effect": "immediate"
            })),
            setting(json!({
                "id": "home", "type": "directory", "title": "Home", "default": ""
            })),
        ];
        let declared = declared(&settings);
        assert!(!declared.contains("hints"));
        assert!(declared.is_immediate("hints"));
        assert!(declared.for_configuration().contains("hints"));
        assert!(declared.contains("home"));
        assert!(declared.requires_whole_value("home"));
    }

    #[test]
    fn page_ids_are_checked() {
        let paged = setting(json!({
            "id": "heap", "type": "boolean", "title": "Heap", "default": true,
            "page": {"languageID": "java"}, "section": "Language server"
        }));
        assert!(paged.validate("settings[0]", 2).is_ok());
        let wrong = setting(json!({
            "id": "heap", "type": "boolean", "title": "Heap", "default": true,
            "page": {"languageID": "has space"}
        }));
        assert!(wrong.validate("settings[0]", 2).is_err());
    }
}
