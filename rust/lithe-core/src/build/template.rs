//! Argument templates of build systems: their variables and conditions, the
//! check that every variable is guaranteed where it is used, and expansion
//! into argv.
//!
//! The `${...}` parser is shared with plugin run/test templates; only the
//! variable vocabulary differs. A variable that may be absent at plan time
//! must be guarded by a condition, so a template never expands to an empty
//! or half-filled argument.

use crate::plugins::declarative::{
    is_setting_identifier, parse_template_with, regex_literal, template, PluginRejection,
    TemplatePart, Validation,
};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};

/// One argv element: a literal template, or one emitted only when every
/// condition holds.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(untagged)]
pub(crate) enum BuildArgument {
    Literal(String),
    Conditional { value: String, when: Conditions },
}

impl BuildArgument {
    pub(crate) fn value(&self) -> &str {
        match self {
            Self::Literal(value) | Self::Conditional { value, .. } => value,
        }
    }

    fn conditions(&self) -> &[Condition] {
        match self {
            Self::Literal(_) => &[],
            Self::Conditional { when, .. } => when.as_slice(),
        }
    }
}

/// One condition or a list that must all hold.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(untagged)]
pub(crate) enum Conditions {
    One(Condition),
    All(Vec<Condition>),
}

impl Conditions {
    fn as_slice(&self) -> &[Condition] {
        match self {
            Self::One(condition) => std::slice::from_ref(condition),
            Self::All(conditions) => conditions,
        }
    }
}

/// What the request selected. `nestedProjectSelected` means a project other
/// than the one at the build-system root, which tools such as Maven address
/// with a project-list flag.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
#[allow(clippy::enum_variant_names)] // The names are the manifest's wire format.
pub(crate) enum Condition {
    ProjectSelected,
    NoProjectSelected,
    NestedProjectSelected,
    NoNestedProjectSelected,
    TargetSelected,
    NoTargetSelected,
    SuiteSelected,
    NoSuiteSelected,
    CaseSelected,
    NoCaseSelected,
}

impl Condition {
    /// The condition that can never hold together with this one.
    fn opposite(self) -> Self {
        use Condition::*;
        match self {
            ProjectSelected => NoProjectSelected,
            NoProjectSelected => ProjectSelected,
            NestedProjectSelected => NoNestedProjectSelected,
            NoNestedProjectSelected => NestedProjectSelected,
            TargetSelected => NoTargetSelected,
            NoTargetSelected => TargetSelected,
            SuiteSelected => NoSuiteSelected,
            NoSuiteSelected => SuiteSelected,
            CaseSelected => NoCaseSelected,
            NoCaseSelected => CaseSelected,
        }
    }

    fn is_test_filter(self) -> bool {
        use Condition::*;
        matches!(
            self,
            SuiteSelected | NoSuiteSelected | CaseSelected | NoCaseSelected
        )
    }

    fn holds(self, values: &Values<'_>) -> bool {
        use Condition::*;
        let nested = values
            .project
            .as_ref()
            .is_some_and(|project| project.path != ".");
        match self {
            ProjectSelected => values.project.is_some(),
            NoProjectSelected => values.project.is_none(),
            NestedProjectSelected => nested,
            NoNestedProjectSelected => !nested,
            TargetSelected => values.target.is_some(),
            NoTargetSelected => values.target.is_none(),
            SuiteSelected => values.suite.is_some(),
            NoSuiteSelected => values.suite.is_none(),
            CaseSelected => values.case.is_some(),
            NoCaseSelected => values.case.is_none(),
        }
    }
}

/// Variables of build-system templates.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Variable {
    /// Build-system instance root, workspace-relative.
    Root,
    ProjectName,
    /// Selected project's directory relative to the instance root, `.` for
    /// the root project.
    ProjectPath,
    ProjectProperty(String),
    TargetName,
    TargetProperty(String),
    TaskName,
    TaskProperty(String),
    TestSuite,
    TestCase,
    TestCaseRegex,
    /// Effective value of the option whose arguments are being expanded.
    Value,
    /// Arguments of every option (`None`) or of one option, in declaration
    /// order. Whole-argument: expands to zero or more elements.
    OptionArguments(Option<String>),
    /// Arguments the user typed. Whole-argument.
    UserArguments,
    PluginDir,
    WorkspaceStateDir,
    OutputFile,
}

const PROJECT_PROPERTY: &str = "project.property:";
const TARGET_PROPERTY: &str = "target.property:";
const TASK_PROPERTY: &str = "task.property:";
const OPTION_ARGUMENTS: &str = "optionArguments:";
/// Longest property key a template may name.
const MAX_PROPERTY_KEY: usize = 64;

impl Variable {
    fn parse(name: &str) -> Option<Self> {
        let property = |prefix: &str| {
            name.strip_prefix(prefix)
                .filter(|key| is_property_key(key))
                .map(str::to_string)
        };
        Some(match name {
            "root" => Self::Root,
            "project.name" => Self::ProjectName,
            "project.path" => Self::ProjectPath,
            "target.name" => Self::TargetName,
            "task.name" => Self::TaskName,
            "test.suite" => Self::TestSuite,
            "test.case" => Self::TestCase,
            "test.case:regex" => Self::TestCaseRegex,
            "value" => Self::Value,
            "optionArguments" => Self::OptionArguments(None),
            "userArguments" => Self::UserArguments,
            "pluginDir" => Self::PluginDir,
            "workspaceStateDir" => Self::WorkspaceStateDir,
            "outputFile" => Self::OutputFile,
            _ => {
                if let Some(key) = property(PROJECT_PROPERTY) {
                    Self::ProjectProperty(key)
                } else if let Some(key) = property(TARGET_PROPERTY) {
                    Self::TargetProperty(key)
                } else if let Some(key) = property(TASK_PROPERTY) {
                    Self::TaskProperty(key)
                } else {
                    let id = name
                        .strip_prefix(OPTION_ARGUMENTS)
                        .filter(|id| is_setting_identifier(id))?;
                    Self::OptionArguments(Some(id.to_string()))
                }
            }
        })
    }

    fn is_whole_argument(&self) -> bool {
        matches!(self, Self::OptionArguments(_) | Self::UserArguments)
    }
}

/// A property key in `${project.property:<key>}` and the model maps.
pub(crate) fn is_property_key(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= MAX_PROPERTY_KEY
        && value
            .chars()
            .all(|character| character.is_ascii_alphanumeric() || "._-".contains(character))
}

pub(crate) fn parse(value: &str) -> Option<Vec<TemplatePart<Variable>>> {
    parse_template_with(value, Variable::parse)
}

/// Whether something is available in a template family, and if so whether
/// it is always present or needs a guarding condition.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Availability {
    Never,
    Maybe,
    Always,
}

/// What one template family may use. Built by the manifest validation for
/// each list it checks.
#[derive(Debug, Clone)]
pub(crate) struct Allowed<'a> {
    pub(crate) root: bool,
    pub(crate) project: Availability,
    pub(crate) target: Availability,
    pub(crate) task: bool,
    pub(crate) test: bool,
    pub(crate) value: bool,
    pub(crate) user_arguments: bool,
    pub(crate) host_directories: bool,
    pub(crate) conditions: bool,
    /// Declared option IDs, or `None` when option arguments are not allowed.
    pub(crate) options: Option<&'a BTreeSet<String>>,
}

impl Allowed<'_> {
    /// Nothing at all: the starting point for narrow families.
    pub(crate) fn none() -> Allowed<'static> {
        Allowed {
            root: false,
            project: Availability::Never,
            target: Availability::Never,
            task: false,
            test: false,
            value: false,
            user_arguments: false,
            host_directories: false,
            conditions: false,
            options: None,
        }
    }
}

/// Checks a single template string used outside an argv list (names and
/// extension values), where conditions do not exist.
pub(crate) fn validate_text(value: &str, allowed: &Allowed<'_>, field: &str) -> Validation<()> {
    validate_element(value, &[], allowed, field)
}

/// Checks every element of an argv template list.
pub(crate) fn validate_arguments(
    arguments: &[BuildArgument],
    allowed: &Allowed<'_>,
    field: &str,
) -> Validation<()> {
    for (index, argument) in arguments.iter().enumerate() {
        let element = format!("{field}[{index}]");
        let conditions = argument.conditions();
        if !conditions.is_empty() && !allowed.conditions {
            return Err(template(
                element,
                "Conditional arguments are not allowed in this list.",
            ));
        }
        if let Some(condition) = conditions
            .iter()
            .find(|condition| conditions.contains(&condition.opposite()))
        {
            return Err(template(
                element,
                format!("The conditions contradict each other ({condition:?})."),
            ));
        }
        if !allowed.test
            && conditions
                .iter()
                .any(|condition| condition.is_test_filter())
        {
            return Err(template(
                element,
                "Suite and case conditions are only allowed in test arguments.",
            ));
        }
        validate_element(argument.value(), conditions, allowed, &element)?;
    }
    Ok(())
}

fn validate_element(
    value: &str,
    conditions: &[Condition],
    allowed: &Allowed<'_>,
    field: &str,
) -> Validation<()> {
    if value.contains('\0') {
        return Err(template(field, "Arguments must not contain NUL."));
    }
    let Some(parts) = parse(value) else {
        return Err(template(
            field,
            "The argument uses an unknown or unterminated template variable.",
        ));
    };
    let has = |condition: Condition| conditions.contains(&condition);
    let target_guaranteed =
        allowed.target == Availability::Always || has(Condition::TargetSelected);
    let project_guaranteed = allowed.project == Availability::Always
        || has(Condition::ProjectSelected)
        || has(Condition::NestedProjectSelected)
        || (target_guaranteed && allowed.target != Availability::Never);
    for part in &parts {
        let TemplatePart::Variable(variable) = part else {
            continue;
        };
        if variable.is_whole_argument() && parts.len() != 1 {
            return Err(template(
                field,
                "${optionArguments} and ${userArguments} must be a whole argument.",
            ));
        }
        let unavailable = || {
            template(
                field,
                "The argument uses a variable that is not available in this list.",
            )
        };
        let unguarded = |condition: &str| {
            template(
                field,
                format!("This variable may be absent; guard it with \"when\": \"{condition}\"."),
            )
        };
        match variable {
            Variable::Root if !allowed.root => return Err(unavailable()),
            Variable::ProjectName | Variable::ProjectPath | Variable::ProjectProperty(_) => {
                if allowed.project == Availability::Never {
                    return Err(unavailable());
                }
                if !project_guaranteed {
                    return Err(unguarded("projectSelected"));
                }
            }
            Variable::TargetName | Variable::TargetProperty(_) => {
                if allowed.target == Availability::Never {
                    return Err(unavailable());
                }
                if !target_guaranteed {
                    return Err(unguarded("targetSelected"));
                }
            }
            Variable::TaskName | Variable::TaskProperty(_) if !allowed.task => {
                return Err(unavailable())
            }
            Variable::TestSuite => {
                if !allowed.test {
                    return Err(unavailable());
                }
                if !has(Condition::SuiteSelected) {
                    return Err(unguarded("suiteSelected"));
                }
            }
            Variable::TestCase | Variable::TestCaseRegex => {
                if !allowed.test {
                    return Err(unavailable());
                }
                if !has(Condition::CaseSelected) {
                    return Err(unguarded("caseSelected"));
                }
            }
            Variable::Value if !allowed.value => return Err(unavailable()),
            Variable::UserArguments if !allowed.user_arguments => return Err(unavailable()),
            Variable::PluginDir | Variable::WorkspaceStateDir | Variable::OutputFile
                if !allowed.host_directories =>
            {
                return Err(unavailable())
            }
            Variable::OptionArguments(id) => {
                let Some(options) = allowed.options else {
                    return Err(unavailable());
                };
                if let Some(id) = id {
                    if !options.contains(id) {
                        return Err(template(
                            field,
                            format!("${{optionArguments:{id}}} names an undeclared option."),
                        ));
                    }
                }
            }
            _ => {}
        }
    }
    Ok(())
}

/// Options a list of templates refers to: whether it names all of them, and
/// which ones it names individually.
pub(crate) fn option_references(arguments: &[BuildArgument]) -> (bool, BTreeSet<String>) {
    let mut all = false;
    let mut named = BTreeSet::new();
    for argument in arguments {
        for part in parse(argument.value()).unwrap_or_default() {
            match part {
                TemplatePart::Variable(Variable::OptionArguments(None)) => all = true,
                TemplatePart::Variable(Variable::OptionArguments(Some(id))) => {
                    named.insert(id);
                }
                _ => {}
            }
        }
    }
    (all, named)
}

/// Whether one list could emit an option's arguments twice: two references
/// that cover a common option and whose conditions can hold together, such
/// as `${optionArguments}` beside `${optionArguments:release}`. References
/// under opposite conditions never meet on one command line.
pub(crate) fn repeats_option_arguments(arguments: &[BuildArgument]) -> bool {
    let references: Vec<(Option<String>, &[Condition])> = arguments
        .iter()
        .flat_map(|argument| {
            parse(argument.value())
                .unwrap_or_default()
                .into_iter()
                .filter_map(move |part| match part {
                    TemplatePart::Variable(Variable::OptionArguments(id)) => {
                        Some((id, argument.conditions()))
                    }
                    _ => None,
                })
        })
        .collect();
    references
        .iter()
        .enumerate()
        .any(|(index, (option, conditions))| {
            references[index + 1..]
                .iter()
                .any(|(other, other_conditions)| {
                    let common = option.is_none() || other.is_none() || option == other;
                    let exclusive = conditions
                        .iter()
                        .any(|condition| other_conditions.contains(&condition.opposite()));
                    common && !exclusive
                })
        })
}

/// True when any template in the list uses the variable.
pub(crate) fn uses(arguments: &[BuildArgument], variable: &Variable) -> bool {
    arguments.iter().any(|argument| {
        parse(argument.value())
            .unwrap_or_default()
            .iter()
            .any(|part| matches!(part, TemplatePart::Variable(found) if found == variable))
    })
}

/// True when an element whose conditions hold for `values` uses one of the
/// variables, so expanding the list would substitute it.
pub(crate) fn applies_any(
    arguments: &[BuildArgument],
    values: &Values<'_>,
    variables: &[Variable],
) -> bool {
    arguments.iter().any(|argument| {
        argument
            .conditions()
            .iter()
            .all(|condition| condition.holds(values))
            && parse(argument.value()).unwrap_or_default().iter().any(
                |part| matches!(part, TemplatePart::Variable(found) if variables.contains(found)),
            )
    })
}

/// A selected project, target, or task: its name and the properties the
/// model recorded for it.
#[derive(Debug, Clone)]
pub(crate) struct Selected<'a> {
    pub(crate) name: &'a str,
    /// For projects, the directory relative to the instance root.
    pub(crate) path: &'a str,
    pub(crate) properties: &'a BTreeMap<String, String>,
}

/// Everything one expansion may substitute.
#[derive(Debug, Clone, Default)]
pub(crate) struct Values<'a> {
    pub(crate) root: &'a str,
    pub(crate) project: Option<Selected<'a>>,
    pub(crate) target: Option<Selected<'a>>,
    pub(crate) task: Option<Selected<'a>>,
    pub(crate) suite: Option<&'a str>,
    pub(crate) case: Option<&'a str>,
    pub(crate) value: Option<&'a str>,
    /// Expanded arguments per option, in declaration order.
    pub(crate) option_arguments: &'a [(String, Vec<String>)],
    pub(crate) user_arguments: &'a [String],
    pub(crate) plugin_dir: Option<&'a str>,
    pub(crate) workspace_state_dir: Option<&'a str>,
    pub(crate) output_file: Option<&'a str>,
}

/// Expands a validated argv template list. Conditions that do not hold drop
/// their element; a substitution whose value is missing is a rejection,
/// because the plan would otherwise run something the user did not select.
pub(crate) fn expand(arguments: &[BuildArgument], values: &Values<'_>) -> Validation<Vec<String>> {
    let mut result = Vec::new();
    for argument in arguments {
        if !argument
            .conditions()
            .iter()
            .all(|condition| condition.holds(values))
        {
            continue;
        }
        let parts = parse(argument.value()).unwrap_or_default();
        if let [TemplatePart::Variable(variable)] = parts.as_slice() {
            match variable {
                Variable::UserArguments => {
                    result.extend(values.user_arguments.iter().cloned());
                    continue;
                }
                Variable::OptionArguments(None) => {
                    for (_, expanded) in values.option_arguments {
                        result.extend(expanded.iter().cloned());
                    }
                    continue;
                }
                Variable::OptionArguments(Some(id)) => {
                    if let Some((_, expanded)) = values
                        .option_arguments
                        .iter()
                        .find(|(option, _)| option == id)
                    {
                        result.extend(expanded.iter().cloned());
                    }
                    continue;
                }
                _ => {}
            }
        }
        result.push(expand_parts(&parts, values)?);
    }
    Ok(result)
}

/// Expands one template string with no conditions.
pub(crate) fn expand_text(value: &str, values: &Values<'_>) -> Validation<String> {
    expand_parts(&parse(value).unwrap_or_default(), values)
}

fn expand_parts(parts: &[TemplatePart<Variable>], values: &Values<'_>) -> Validation<String> {
    let mut text = String::new();
    for part in parts {
        match part {
            TemplatePart::Text(value) => text.push_str(value),
            TemplatePart::Variable(variable) => text.push_str(&substitute(variable, values)?),
        }
    }
    Ok(text)
}

fn substitute(variable: &Variable, values: &Values<'_>) -> Validation<String> {
    let missing = |what: &str| {
        PluginRejection::new(
            "plugin.build.invalidSelection",
            format!("The request does not provide {what}."),
        )
    };
    let property = |selected: Option<&Selected<'_>>, kind: &str, key: &str| {
        selected
            .ok_or_else(|| missing(kind))?
            .properties
            .get(key)
            .cloned()
            .ok_or_else(|| missing(&format!("the {kind} property {key}")))
    };
    Ok(match variable {
        Variable::Root => values.root.to_string(),
        Variable::ProjectName => values
            .project
            .as_ref()
            .ok_or_else(|| missing("a project"))?
            .name
            .to_string(),
        Variable::ProjectPath => values
            .project
            .as_ref()
            .ok_or_else(|| missing("a project"))?
            .path
            .to_string(),
        Variable::ProjectProperty(key) => property(values.project.as_ref(), "project", key)?,
        Variable::TargetName => values
            .target
            .as_ref()
            .ok_or_else(|| missing("a target"))?
            .name
            .to_string(),
        Variable::TargetProperty(key) => property(values.target.as_ref(), "target", key)?,
        Variable::TaskName => values
            .task
            .as_ref()
            .ok_or_else(|| missing("a task"))?
            .name
            .to_string(),
        Variable::TaskProperty(key) => property(values.task.as_ref(), "task", key)?,
        Variable::TestSuite => values
            .suite
            .ok_or_else(|| missing("a test suite"))?
            .to_string(),
        Variable::TestCase => values
            .case
            .ok_or_else(|| missing("a test case"))?
            .to_string(),
        // Escaped only, like `${testName:regex}`: the template adds anchors.
        Variable::TestCaseRegex => {
            regex_literal(values.case.ok_or_else(|| missing("a test case"))?)
        }
        Variable::Value => values
            .value
            .ok_or_else(|| missing("an option value"))?
            .to_string(),
        Variable::PluginDir => values
            .plugin_dir
            .ok_or_else(|| missing("pluginDirectory"))?
            .to_string(),
        Variable::WorkspaceStateDir => values
            .workspace_state_dir
            .ok_or_else(|| missing("workspaceStateDirectory"))?
            .to_string(),
        Variable::OutputFile => values
            .output_file
            .ok_or_else(|| missing("outputFile"))?
            .to_string(),
        // Whole-argument variables never reach here: validation rejects them
        // inside a longer element and `expand` handles them alone.
        Variable::OptionArguments(_) | Variable::UserArguments => String::new(),
    })
}
