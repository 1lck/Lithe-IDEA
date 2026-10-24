//! The `projectGenerators` section of a manifest and its validation.

use super::template::{self, Source, Variable};
use crate::plugins::declarative::{
    invalid, is_bare_command, is_safe_relative_path, is_setting_identifier, TemplatePart, UIIcon,
    Validation,
};
use regex::Regex;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::{BTreeMap, BTreeSet};

/// Most generators one plugin may declare.
const MAX_GENERATORS: usize = 16;
/// Most fields, requirements, steps, and files to open per generator.
const MAX_FIELDS: usize = 32;
const MAX_REQUIREMENTS: usize = 8;
const MAX_STEPS: usize = 16;
const MAX_OPEN_FILES: usize = 8;
/// Most choices of one enum field, and of one multiSelect field (a
/// dependency list is longer than a choice of build tools).
const MAX_ENUM_OPTIONS: usize = 16;
const MAX_MULTI_SELECT_OPTIONS: usize = 128;
/// Longest ID, title, option value, and short label.
const MAX_LABEL: usize = 120;
/// Longest description.
const MAX_DESCRIPTION: usize = 480;
/// Longest pattern a text field may declare, and longest text value.
const MAX_PATTERN: usize = 256;
pub(crate) const DEFAULT_TEXT_LENGTH: u32 = 256;
const MAX_TEXT_LENGTH: u32 = 1024;
/// Most arguments, environment entries, and query parameters per step.
const MAX_ARGUMENTS: usize = 64;
const MAX_ENVIRONMENT: usize = 16;
const MAX_QUERY: usize = 32;
/// Longest step timeout, in seconds.
const MAX_TIMEOUT_SECONDS: u32 = 1800;

/// One way to start a project, listed in the New Project window.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct ProjectGeneratorDeclaration {
    /// Lowercase letters, digits, and hyphens; unique within the plugin.
    pub(crate) id: String,
    pub(crate) display_name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) description: Option<String>,
    /// The list the entry appears in.
    pub(crate) section: GeneratorSection,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) icon: Option<UIIcon>,
    /// Position within the section; lower first, ties by name.
    #[serde(default = "default_order")]
    pub(crate) order: u32,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub(crate) fields: Vec<GeneratorField>,
    /// Languages and build systems the created project needs. The host
    /// tells the user which plugin provides each and offers to enable it.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub(crate) requirements: Vec<GeneratorRequirement>,
    pub(crate) steps: Vec<GeneratorStep>,
    /// Project-relative files the host opens after creating the project.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub(crate) open_files: Vec<ConditionalPath>,
}

fn default_order() -> u32 {
    100
}

/// IDEA's two lists: language projects, and framework generators.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) enum GeneratorSection {
    /// "New Project": a plain project of a language.
    Project,
    /// "Generators": a framework or scaffolding tool.
    Generator,
}

pub(crate) const FIELD_TEXT: &str = "text";
pub(crate) const FIELD_ENUM: &str = "enum";
pub(crate) const FIELD_BOOLEAN: &str = "boolean";
pub(crate) const FIELD_MULTI_SELECT: &str = "multiSelect";
pub(crate) const FIELD_RUNTIME: &str = "runtime";
/// Host-managed runtimes a runtime field may select. The host discovers
/// installations; Core only checks the version.
const KNOWN_RUNTIMES: &[&str] = &["java"];

/// One input of a generator. The types follow plugin settings, minus
/// integer and paths, plus `runtime`.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct GeneratorField {
    /// lowerCamelCase; templates read it as `${field.<id>}`.
    pub(crate) id: String,
    #[serde(rename = "type")]
    pub(crate) kind: String,
    pub(crate) title: String,
    /// Explanation the host shows behind an info tip.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) description: Option<String>,
    /// Shown under the collapsed "Advanced Settings" group.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub(crate) advanced: bool,
    /// Shown, validated, and readable only while these hold.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) visible_when: Option<Conditions>,
    /// Initial value. For a text field it is a template over the project
    /// name and earlier fields, re-evaluated until the user edits the field.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) default: Option<Value>,
    /// Choices of an enum or multiSelect field, in display order.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub(crate) options: Vec<FieldOption>,
    /// How an enum field is drawn.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) presentation: Option<FieldPresentation>,
    /// Regular expression a text value must match as a whole.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) pattern: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) max_length: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) placeholder: Option<String>,
    /// A text or runtime field may be left empty.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub(crate) optional: bool,
    /// Runtime a runtime field selects.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) runtime: Option<String>,
    /// Oldest acceptable runtime version.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) minimum_version: Option<String>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct FieldOption {
    pub(crate) value: String,
    pub(crate) title: String,
    /// Heading a multiSelect option is listed under, such as "Web".
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) group: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) enum FieldPresentation {
    /// A row of buttons, for a few short choices.
    Segmented,
    /// A drop-down menu.
    Menu,
}

/// One condition or a list that must all hold.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(untagged)]
pub(crate) enum Conditions {
    One(Condition),
    All(Vec<Condition>),
}

impl Conditions {
    pub(crate) fn as_slice(&self) -> &[Condition] {
        match self {
            Self::One(condition) => std::slice::from_ref(condition),
            Self::All(conditions) => conditions,
        }
    }
}

/// A test of one field's value. Exactly one of the comparisons is set.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct Condition {
    pub(crate) field: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) equals: Option<Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) not_equals: Option<Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) one_of: Option<Vec<Value>>,
}

/// A language or build system the created project needs. Exactly one of
/// the two is set.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct GeneratorRequirement {
    #[serde(
        default,
        rename = "languageID",
        skip_serializing_if = "Option::is_none"
    )]
    pub(crate) language_id: Option<String>,
    #[serde(
        default,
        rename = "buildSystemID",
        skip_serializing_if = "Option::is_none"
    )]
    pub(crate) build_system_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) when: Option<Conditions>,
}

/// A path template, optionally guarded.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(untagged)]
pub(crate) enum ConditionalPath {
    Literal(String),
    Conditional { path: String, when: Conditions },
}

impl ConditionalPath {
    pub(crate) fn path(&self) -> &str {
        match self {
            Self::Literal(path) | Self::Conditional { path, .. } => path,
        }
    }

    pub(crate) fn when(&self) -> Option<&Conditions> {
        match self {
            Self::Literal(_) => None,
            Self::Conditional { when, .. } => Some(when),
        }
    }
}

/// One argv element or query value, optionally guarded.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(untagged)]
pub(crate) enum ConditionalValue {
    Literal(String),
    Conditional { value: String, when: Conditions },
}

impl ConditionalValue {
    pub(crate) fn value(&self) -> &str {
        match self {
            Self::Literal(value) | Self::Conditional { value, .. } => value,
        }
    }

    pub(crate) fn when(&self) -> Option<&Conditions> {
        match self {
            Self::Literal(_) => None,
            Self::Conditional { when, .. } => Some(when),
        }
    }
}

/// One query parameter of an archive URL.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct QueryParameter {
    pub(crate) name: String,
    pub(crate) value: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) when: Option<Conditions>,
    /// Leave the parameter out when its value expands to an empty string.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub(crate) omit_empty: bool,
}

/// One step of creating a project, run in order inside the staging
/// directory that becomes the project root.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase", deny_unknown_fields)]
pub(crate) enum GeneratorStep {
    /// Copies a template directory of the package, expanding `{{ ... }}`
    /// variables in file contents and `${...}` in path names.
    Files {
        /// Package-relative directory.
        source: String,
        /// Project-relative directory the files go to; the root if absent.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        target: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        when: Option<Conditions>,
    },
    /// Runs a scaffolding tool with the staging directory as its working
    /// directory.
    #[serde(rename_all = "camelCase")]
    Command {
        /// Bare executable name the host resolves like a build tool.
        command: String,
        #[serde(default)]
        arguments: Vec<ConditionalValue>,
        #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
        environment: BTreeMap<String, String>,
        /// The tool writes the project into this subdirectory (Maven's
        /// archetype plugin uses the artifact ID); its contents become the
        /// project root.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        collect: Option<String>,
        /// Shown in the install review and before creating.
        may_use_network: bool,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        timeout_seconds: Option<u32>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        when: Option<Conditions>,
    },
    /// Downloads a zip archive and extracts it into the project root.
    #[serde(rename_all = "camelCase")]
    Archive {
        /// HTTPS address without a query; `http` only for loopback hosts.
        url: String,
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        query: Vec<QueryParameter>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        when: Option<Conditions>,
    },
}

impl GeneratorStep {
    pub(crate) fn when(&self) -> Option<&Conditions> {
        match self {
            Self::Files { when, .. } | Self::Command { when, .. } | Self::Archive { when, .. } => {
                when.as_ref()
            }
        }
    }

    pub(crate) fn uses_network(&self) -> bool {
        match self {
            Self::Files { .. } => false,
            Self::Command {
                may_use_network, ..
            } => *may_use_network,
            Self::Archive { .. } => true,
        }
    }
}

/// Install-review entries: one per scaffolding command. The whole step
/// (executable, argument templates, environment, guard, and network flag)
/// is the approved value, so an update that adds a command or changes what
/// one runs is a new program the user must approve. File and archive steps
/// start no process and are covered by the `project.generate` permission.
pub(crate) fn programs(generator: &ProjectGeneratorDeclaration) -> Vec<Value> {
    generator
        .steps
        .iter()
        .filter_map(|step| match step {
            GeneratorStep::Command {
                command,
                arguments,
                environment,
                collect,
                may_use_network,
                timeout_seconds,
                when,
            } => Some(json!({
                "kind": "projectGenerator",
                "generatorID": generator.id,
                "command": command,
                "arguments": arguments,
                "environment": environment,
                "collect": collect,
                "mayUseNetwork": may_use_network,
                "timeoutSeconds": timeout_seconds,
                "when": when,
            })),
            GeneratorStep::Files { .. } | GeneratorStep::Archive { .. } => None,
        })
        .collect()
}

impl GeneratorField {
    pub(crate) fn is(&self, kind: &str) -> bool {
        self.kind == kind
    }

    pub(crate) fn offers(&self, value: &str) -> bool {
        self.options.iter().any(|option| option.value == value)
    }

    pub(crate) fn max_text_length(&self) -> u32 {
        self.max_length.unwrap_or(DEFAULT_TEXT_LENGTH)
    }

    pub(crate) fn text_pattern(&self) -> Option<Regex> {
        self.pattern
            .as_ref()
            .and_then(|pattern| Regex::new(&format!("^(?:{pattern})$")).ok())
    }

    pub(crate) fn default_template(&self) -> Option<Vec<TemplatePart<Variable>>> {
        match (&self.default, self.is(FIELD_TEXT)) {
            (Some(Value::String(text)), true) => template::parse(text),
            _ => None,
        }
    }
}

/// Validates every generator and sorts fields-free collections that have no
/// meaningful order. Field and step order are kept: fields are drawn and
/// defaults evaluated in order, steps run in order.
pub(crate) fn validate_declarations(generators: &[ProjectGeneratorDeclaration]) -> Validation<()> {
    if generators.len() > MAX_GENERATORS {
        return Err(invalid(
            "projectGenerators",
            format!("A plugin declares at most {MAX_GENERATORS} project generators."),
        ));
    }
    let mut ids = BTreeSet::new();
    for (index, generator) in generators.iter().enumerate() {
        let field = format!("projectGenerators[{index}]");
        if !ids.insert(generator.id.as_str()) {
            return Err(invalid(
                format!("{field}.id"),
                "A project generator is declared more than once.",
            ));
        }
        generator.validate(&field)?;
    }
    Ok(())
}

impl ProjectGeneratorDeclaration {
    fn validate(&self, field: &str) -> Validation<()> {
        if !is_generator_id(&self.id) {
            return Err(invalid(
                format!("{field}.id"),
                "A generator ID uses lowercase letters, digits, and hyphens.",
            ));
        }
        check_label(&self.display_name, &format!("{field}.displayName"))?;
        check_description(self.description.as_deref(), &format!("{field}.description"))?;
        if let Some(icon) = &self.icon {
            icon.validate_at(&format!("{field}.icon"))?;
        }
        if self.order > 1000 {
            return Err(invalid(format!("{field}.order"), "order is 0-1000."));
        }
        if self.fields.len() > MAX_FIELDS
            || self.requirements.len() > MAX_REQUIREMENTS
            || self.steps.is_empty()
            || self.steps.len() > MAX_STEPS
            || self.open_files.len() > MAX_OPEN_FILES
        {
            return Err(invalid(
                field,
                format!(
                    "A generator has at most {MAX_FIELDS} fields, {MAX_REQUIREMENTS} requirements, \
                     {MAX_OPEN_FILES} files to open, and 1-{MAX_STEPS} steps."
                ),
            ));
        }

        let mut declared: BTreeMap<&str, &GeneratorField> = BTreeMap::new();
        for (index, item) in self.fields.iter().enumerate() {
            let item_field = format!("{field}.fields[{index}]");
            // A field reads only fields declared before it, so defaults are
            // evaluated in one pass and visibility never forms a cycle.
            item.validate(&item_field, &declared)?;
            if declared.insert(item.id.as_str(), item).is_some() {
                return Err(invalid(
                    format!("{item_field}.id"),
                    "A field is declared more than once.",
                ));
            }
        }

        for (index, requirement) in self.requirements.iter().enumerate() {
            let item_field = format!("{field}.requirements[{index}]");
            let id = match (&requirement.language_id, &requirement.build_system_id) {
                (Some(id), None) | (None, Some(id)) => id,
                _ => {
                    return Err(invalid(
                        item_field,
                        "A requirement names exactly one of languageID and buildSystemID.",
                    ))
                }
            };
            if !is_generator_id(id) {
                return Err(invalid(
                    item_field,
                    "A requirement names a language or build system ID.",
                ));
            }
            check_conditions(
                requirement.when.as_ref(),
                &format!("{item_field}.when"),
                &declared,
            )?;
        }

        for (index, step) in self.steps.iter().enumerate() {
            step.validate(&format!("{field}.steps[{index}]"), &declared)?;
        }

        for (index, path) in self.open_files.iter().enumerate() {
            let item_field = format!("{field}.openFiles[{index}]");
            check_path_template(path.path(), &item_field, &declared)?;
            check_conditions(path.when(), &format!("{item_field}.when"), &declared)?;
        }
        Ok(())
    }
}

impl GeneratorField {
    fn validate(&self, field: &str, earlier: &BTreeMap<&str, &GeneratorField>) -> Validation<()> {
        if !is_setting_identifier(&self.id) {
            return Err(invalid(
                format!("{field}.id"),
                "A field ID starts with a lowercase letter and contains only letters and digits.",
            ));
        }
        check_label(&self.title, &format!("{field}.title"))?;
        check_description(self.description.as_deref(), &format!("{field}.description"))?;
        if let Some(placeholder) = &self.placeholder {
            check_label(placeholder, &format!("{field}.placeholder"))?;
        }
        check_conditions(
            self.visible_when.as_ref(),
            &format!("{field}.visibleWhen"),
            earlier,
        )?;

        let kind = self.kind.as_str();
        let allowed = |name: &str| match name {
            "options" => matches!(kind, FIELD_ENUM | FIELD_MULTI_SELECT),
            "presentation" => kind == FIELD_ENUM,
            "text" => kind == FIELD_TEXT,
            "optional" => matches!(kind, FIELD_TEXT | FIELD_RUNTIME),
            "runtime" => kind == FIELD_RUNTIME,
            _ => false,
        };
        let present = [
            ("options", !self.options.is_empty()),
            ("presentation", self.presentation.is_some()),
            (
                "text",
                self.pattern.is_some() || self.max_length.is_some() || self.placeholder.is_some(),
            ),
            ("optional", self.optional),
            (
                "runtime",
                self.runtime.is_some() || self.minimum_version.is_some(),
            ),
        ];
        if let Some((name, _)) = present
            .iter()
            .find(|(name, present)| *present && !allowed(name))
        {
            return Err(invalid(
                field,
                format!("A {kind} field does not take {name} properties."),
            ));
        }

        match kind {
            FIELD_TEXT => {
                let max_length = self.max_text_length();
                if max_length == 0 || max_length > MAX_TEXT_LENGTH {
                    return Err(invalid(
                        format!("{field}.maxLength"),
                        format!("maxLength is 1-{MAX_TEXT_LENGTH}."),
                    ));
                }
                if let Some(pattern) = &self.pattern {
                    if pattern.len() > MAX_PATTERN || self.text_pattern().is_none() {
                        return Err(invalid(
                            format!("{field}.pattern"),
                            "The pattern is not a valid regular expression.",
                        ));
                    }
                }
                match &self.default {
                    None => {}
                    Some(Value::String(text)) => {
                        let parts = template::parse(text).ok_or_else(|| {
                            invalid(
                                format!("{field}.default"),
                                "The default has an unknown or unterminated variable.",
                            )
                        })?;
                        check_variables(&parts, &format!("{field}.default"), earlier)?;
                    }
                    Some(_) => {
                        return Err(invalid(
                            format!("{field}.default"),
                            "A text default is a string.",
                        ))
                    }
                }
            }
            FIELD_ENUM | FIELD_MULTI_SELECT => {
                let limit = if kind == FIELD_ENUM {
                    MAX_ENUM_OPTIONS
                } else {
                    MAX_MULTI_SELECT_OPTIONS
                };
                if self.options.is_empty() || self.options.len() > limit {
                    return Err(invalid(
                        format!("{field}.options"),
                        format!("A {kind} field offers 1-{limit} options."),
                    ));
                }
                let mut values = BTreeSet::new();
                for (index, option) in self.options.iter().enumerate() {
                    let option_field = format!("{field}.options[{index}]");
                    if !is_option_value(&option.value) || !values.insert(option.value.as_str()) {
                        return Err(invalid(
                            format!("{option_field}.value"),
                            "Option values are unique and use letters, digits, dots, underscores, and hyphens.",
                        ));
                    }
                    check_label(&option.title, &format!("{option_field}.title"))?;
                    if let Some(group) = &option.group {
                        check_label(group, &format!("{option_field}.group"))?;
                    }
                }
                let default_ok = match (&self.default, kind) {
                    (None, _) => true,
                    (Some(Value::String(value)), FIELD_ENUM) => self.offers(value),
                    (Some(Value::Array(items)), FIELD_MULTI_SELECT) => items
                        .iter()
                        .all(|item| item.as_str().is_some_and(|value| self.offers(value))),
                    _ => false,
                };
                if !default_ok {
                    return Err(invalid(
                        format!("{field}.default"),
                        "The default must be one of the options.",
                    ));
                }
            }
            FIELD_BOOLEAN => {
                if !matches!(self.default, None | Some(Value::Bool(_))) {
                    return Err(invalid(
                        format!("{field}.default"),
                        "A boolean default is true or false.",
                    ));
                }
            }
            FIELD_RUNTIME => {
                if !self
                    .runtime
                    .as_deref()
                    .is_some_and(|runtime| KNOWN_RUNTIMES.contains(&runtime))
                {
                    return Err(invalid(
                        format!("{field}.runtime"),
                        format!(
                            "A runtime field selects one of: {}.",
                            KNOWN_RUNTIMES.join(", ")
                        ),
                    ));
                }
                if let Some(version) = &self.minimum_version {
                    crate::plugins::declarative::validate_minimum_version(
                        version,
                        &format!("{field}.minimumVersion"),
                    )?;
                }
                if self.default.is_some() {
                    return Err(invalid(
                        format!("{field}.default"),
                        "The host chooses the initial runtime.",
                    ));
                }
            }
            _ => {
                return Err(invalid(
                    format!("{field}.type"),
                    "A field type is text, enum, boolean, multiSelect, or runtime.",
                ))
            }
        }
        Ok(())
    }
}

impl GeneratorStep {
    fn validate(&self, field: &str, fields: &BTreeMap<&str, &GeneratorField>) -> Validation<()> {
        check_conditions(self.when(), &format!("{field}.when"), fields)?;
        match self {
            Self::Files { source, target, .. } => {
                if !is_safe_relative_path(source) || source.contains('$') {
                    return Err(invalid(
                        format!("{field}.source"),
                        "source is a package-relative directory.",
                    ));
                }
                if let Some(target) = target {
                    check_path_template(target, &format!("{field}.target"), fields)?;
                }
            }
            Self::Command {
                command,
                arguments,
                environment,
                collect,
                timeout_seconds,
                ..
            } => {
                if !is_bare_command(command) {
                    return Err(invalid(
                        format!("{field}.command"),
                        "command is a bare executable name the host resolves.",
                    ));
                }
                if arguments.len() > MAX_ARGUMENTS || environment.len() > MAX_ENVIRONMENT {
                    return Err(invalid(
                        field,
                        format!(
                            "A command has at most {MAX_ARGUMENTS} arguments and {MAX_ENVIRONMENT} environment entries."
                        ),
                    ));
                }
                for (index, argument) in arguments.iter().enumerate() {
                    let item = format!("{field}.arguments[{index}]");
                    check_value_template(argument.value(), &item, fields)?;
                    check_conditions(argument.when(), &format!("{item}.when"), fields)?;
                }
                for (name, value) in environment {
                    let item = format!("{field}.environment.{name}");
                    if !is_environment_name(name) {
                        return Err(invalid(item, "An environment name uses A-Z, 0-9, and _."));
                    }
                    check_value_template(value, &item, fields)?;
                }
                if let Some(collect) = collect {
                    check_path_template(collect, &format!("{field}.collect"), fields)?;
                }
                if timeout_seconds
                    .is_some_and(|seconds| seconds == 0 || seconds > MAX_TIMEOUT_SECONDS)
                {
                    return Err(invalid(
                        format!("{field}.timeoutSeconds"),
                        format!("timeoutSeconds is 1-{MAX_TIMEOUT_SECONDS}."),
                    ));
                }
            }
            Self::Archive { url, query, .. } => {
                let parts = check_value_template(url, &format!("{field}.url"), fields)?;
                // The scheme and host must be visible in the declaration:
                // only a field may supply the whole address, which the host
                // shows to the user (a configurable server URL).
                let literal_start = match parts.first() {
                    Some(TemplatePart::Text(text)) => Some(text.as_str()),
                    _ => None,
                };
                if let Some(start) = literal_start {
                    if !(start.starts_with("https://") || start.starts_with("http://")) {
                        return Err(invalid(
                            format!("{field}.url"),
                            "An archive URL is an http(s) address.",
                        ));
                    }
                }
                if url.contains('?') || url.contains('#') {
                    return Err(invalid(
                        format!("{field}.url"),
                        "Query parameters go in query, not in the URL.",
                    ));
                }
                if query.len() > MAX_QUERY {
                    return Err(invalid(
                        format!("{field}.query"),
                        format!("An archive URL has at most {MAX_QUERY} query parameters."),
                    ));
                }
                for (index, parameter) in query.iter().enumerate() {
                    let item = format!("{field}.query[{index}]");
                    if !is_option_value(&parameter.name) {
                        return Err(invalid(
                            format!("{item}.name"),
                            "A query parameter name uses letters, digits, dots, underscores, and hyphens.",
                        ));
                    }
                    check_value_template(&parameter.value, &format!("{item}.value"), fields)?;
                    check_conditions(parameter.when.as_ref(), &format!("{item}.when"), fields)?;
                }
            }
        }
        Ok(())
    }
}

fn check_conditions(
    conditions: Option<&Conditions>,
    field: &str,
    fields: &BTreeMap<&str, &GeneratorField>,
) -> Validation<()> {
    let Some(conditions) = conditions else {
        return Ok(());
    };
    if conditions.as_slice().is_empty() {
        return Err(invalid(field, "A condition list is not empty."));
    }
    for condition in conditions.as_slice() {
        let Some(target) = fields.get(condition.field.as_str()) else {
            return Err(invalid(
                field,
                format!(
                    "The condition reads {}, which is not an earlier field.",
                    condition.field
                ),
            ));
        };
        let comparisons: Vec<&Value> =
            match (&condition.equals, &condition.not_equals, &condition.one_of) {
                (Some(value), None, None) | (None, Some(value), None) => vec![value],
                (None, None, Some(values)) if !values.is_empty() => values.iter().collect(),
                _ => {
                    return Err(invalid(
                        field,
                        "A condition sets exactly one of equals, notEquals, and oneOf.",
                    ))
                }
            };
        let comparable = |value: &Value| match target.kind.as_str() {
            FIELD_ENUM => value.as_str().is_some_and(|text| target.offers(text)),
            FIELD_BOOLEAN => value.is_boolean(),
            FIELD_TEXT | FIELD_RUNTIME => value.is_string(),
            _ => false,
        };
        if !comparisons.into_iter().all(comparable) {
            return Err(invalid(
                field,
                format!(
                    "The condition compares {} with a value that field cannot hold.",
                    condition.field
                ),
            ));
        }
    }
    Ok(())
}

fn check_value_template(
    value: &str,
    field: &str,
    fields: &BTreeMap<&str, &GeneratorField>,
) -> Validation<Vec<TemplatePart<Variable>>> {
    let parts = template::parse(value).ok_or_else(|| {
        invalid(
            field,
            "The template has an unknown or unterminated variable.",
        )
    })?;
    check_variables(&parts, field, fields)?;
    Ok(parts)
}

fn check_path_template(
    value: &str,
    field: &str,
    fields: &BTreeMap<&str, &GeneratorField>,
) -> Validation<()> {
    if !is_safe_relative_path(value) {
        return Err(invalid(
            field,
            "The path is relative and stays inside the project.",
        ));
    }
    check_value_template(value, field, fields).map(|_| ())
}

fn check_variables(
    parts: &[TemplatePart<Variable>],
    field: &str,
    fields: &BTreeMap<&str, &GeneratorField>,
) -> Validation<()> {
    for part in parts {
        let TemplatePart::Variable(variable) = part else {
            continue;
        };
        if !variable_is_known(variable, |id| fields.get(id).copied()) {
            return Err(invalid(
                field,
                "The template reads a field that is not declared earlier, or a runtime version of a field that is not a runtime.",
            ));
        }
    }
    Ok(())
}

/// Whether a variable names a field `lookup` knows, with a runtime suffix
/// only on runtime fields.
pub(crate) fn variable_is_known<'a>(
    variable: &Variable,
    lookup: impl Fn(&str) -> Option<&'a GeneratorField>,
) -> bool {
    match &variable.source {
        Source::ProjectName => true,
        Source::Field(id) => lookup(id).is_some(),
        Source::RuntimeVersion(id) | Source::RuntimeMajor(id) => {
            lookup(id).is_some_and(|field| field.is(FIELD_RUNTIME))
        }
    }
}

fn check_label(text: &str, field: &str) -> Validation<()> {
    if text.trim().is_empty()
        || text.chars().count() > MAX_LABEL
        || text.chars().any(char::is_control)
    {
        return Err(invalid(field, "A label is short text on one line."));
    }
    Ok(())
}

fn check_description(text: Option<&str>, field: &str) -> Validation<()> {
    if text.is_some_and(|text| text.trim().is_empty() || text.chars().count() > MAX_DESCRIPTION) {
        return Err(invalid(field, "The description is empty or too long."));
    }
    Ok(())
}

pub(crate) fn is_generator_id(value: &str) -> bool {
    let mut chars = value.chars();
    value.len() <= 64
        && chars.next().is_some_and(|first| first.is_ascii_lowercase())
        && chars.all(|rest| rest.is_ascii_lowercase() || rest.is_ascii_digit() || rest == '-')
}

fn is_option_value(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= MAX_LABEL
        && value.chars().all(|character| {
            character.is_ascii_alphanumeric() || matches!(character, '.' | '_' | '-')
        })
}

fn is_environment_name(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 64
        && !value.starts_with(|character: char| character.is_ascii_digit())
        && value.chars().all(|character| {
            character.is_ascii_uppercase() || character.is_ascii_digit() || character == '_'
        })
}
