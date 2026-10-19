//! The unified build model every build system is decoded into, and the two
//! ways to fill it: a plugin's selector map over a structured document, or
//! the canonical `litheBuildModel` format a plugin's own script prints.
//!
//! Projects, targets, and tasks get IDs in the same `<provider>:<dir>/<name>`
//! form as detected run entries, so hosts can join them with run
//! configurations and keep user overrides attached across refreshes.

use super::decode::{self, Workspace};
use super::manifest::{
    category_labels, BuildExecution, BuildSystemDeclaration, ContentRootKind, ContentRootRule,
    ModelMap, ProjectRule, RuleMatch, TargetRule, TaskGroup,
};
use super::select::{self, FieldSpec, Node};
use crate::plugins::declarative::{is_identifier, Validation};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{BTreeMap, BTreeSet};

/// Version of the canonical `litheBuildModel` format.
pub(crate) const CANONICAL_MODEL_VERSION: u32 = 1;
pub(crate) const MAX_PROJECTS: usize = 2_000;
const MAX_ITEMS: usize = 10_000;
const MAX_NAME: usize = 256;
const MAX_PROPERTY_VALUE: usize = 1_024;
/// Tags that name what a target is, in the order one of them becomes the
/// primary tag of its ID.
const PRIMARY_TAGS: &[&str] = &["application", "test", "benchmark", "example", "library"];

/// One build-system instance's projects and what they contain.
#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct BuildModel {
    pub(crate) projects: Vec<ModelProject>,
    pub(crate) targets: Vec<ModelTarget>,
    pub(crate) tasks: Vec<ModelTask>,
    pub(crate) content_roots: Vec<ModelContentRoot>,
    /// Values the model offers for `choicesFromModel` options.
    pub(crate) option_values: BTreeMap<String, Vec<String>>,
    /// True when a bound dropped entries.
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub(crate) truncated: bool,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ModelProject {
    pub(crate) id: String,
    /// Workspace-relative directory.
    pub(crate) path: String,
    pub(crate) name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) display_name: Option<String>,
    #[serde(rename = "parentID", skip_serializing_if = "Option::is_none")]
    pub(crate) parent_id: Option<String>,
    pub(crate) properties: BTreeMap<String, String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ModelTarget {
    pub(crate) id: String,
    #[serde(rename = "projectID")]
    pub(crate) project_id: String,
    pub(crate) name: String,
    /// Workspace-relative directory the target lives in.
    pub(crate) path: String,
    pub(crate) tags: Vec<String>,
    pub(crate) properties: BTreeMap<String, String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ModelTask {
    pub(crate) id: String,
    #[serde(rename = "projectID")]
    pub(crate) project_id: String,
    pub(crate) name: String,
    pub(crate) path: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) display_name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) description: Option<String>,
    /// The `fromModel` task declaration whose arguments run this task.
    pub(crate) template: String,
    pub(crate) group: TaskGroup,
    /// Headings the host files the task under, outermost first; the
    /// template's category when the model names none.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub(crate) category: Vec<String>,
    pub(crate) execution: BuildExecution,
    pub(crate) properties: BTreeMap<String, String>,
}

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ModelContentRoot {
    #[serde(rename = "projectID")]
    pub(crate) project_id: String,
    pub(crate) path: String,
    pub(crate) kind: ContentRootKind,
}

/// `<provider>:<dir>/<name>`, with the directory left out at the workspace
/// root; the format of `Detected::id`.
pub(crate) fn entry_id(provider: &str, directory: &str, name: &str) -> String {
    if directory == "." {
        format!("{provider}:{name}")
    } else {
        format!("{provider}:{directory}/{name}")
    }
}

/// The tag a target's ID is filed under.
pub(crate) fn primary_tag(tags: &[String]) -> &str {
    PRIMARY_TAGS
        .iter()
        .copied()
        .find(|tag| tags.iter().any(|candidate| candidate == tag))
        .or_else(|| tags.first().map(String::as_str))
        .unwrap_or("target")
}

fn model_text(value: &str, limit: usize) -> Option<String> {
    let value = value.trim();
    (!value.is_empty() && value.len() <= limit && !value.chars().any(char::is_control))
        .then(|| value.to_string())
}

/// Collects model entries, giving each its ID and its project.
pub(crate) struct ModelBuilder<'a> {
    build_system: &'a BuildSystemDeclaration,
    workspace: &'a Workspace,
    /// Instance root, workspace-relative.
    root: &'a str,
    model: BuildModel,
    /// Explicit parent directory per project, resolved in `finish`.
    parents: Vec<Option<String>>,
    option_values: BTreeMap<String, BTreeSet<String>>,
}

impl<'a> ModelBuilder<'a> {
    pub(crate) fn new(
        build_system: &'a BuildSystemDeclaration,
        workspace: &'a Workspace,
        root: &'a str,
    ) -> Self {
        Self {
            build_system,
            workspace,
            root,
            model: BuildModel::default(),
            parents: Vec::new(),
            option_values: BTreeMap::new(),
        }
    }

    fn add_project(
        &mut self,
        path: String,
        name: &str,
        display_name: Option<String>,
        parent: Option<String>,
        properties: BTreeMap<String, String>,
    ) -> Option<usize> {
        // Projects outside the instance cannot be addressed relative to it.
        if !decode::contains(self.root, &path) {
            return None;
        }
        let name = model_text(name, MAX_NAME)?;
        let id = entry_id(&self.build_system.id, &path, &name);
        if let Some(index) = self
            .model
            .projects
            .iter()
            .position(|project| project.id == id)
        {
            return Some(index);
        }
        if self.model.projects.len() >= MAX_PROJECTS {
            self.model.truncated = true;
            return None;
        }
        self.model.projects.push(ModelProject {
            id,
            path,
            name,
            display_name: display_name.and_then(|value| model_text(&value, MAX_NAME)),
            parent_id: None,
            properties,
        });
        self.parents.push(parent);
        Some(self.model.projects.len() - 1)
    }

    /// The deepest project containing `path`, earliest first on ties.
    fn containing_project(&self, path: &str) -> Option<usize> {
        self.model
            .projects
            .iter()
            .enumerate()
            .filter(|(_, project)| decode::contains(&project.path, path))
            .max_by_key(|(index, project)| (depth(&project.path), std::cmp::Reverse(*index)))
            .map(|(index, _)| index)
    }

    fn add_target(
        &mut self,
        project: usize,
        path: Option<String>,
        name: &str,
        tags: Vec<String>,
        properties: BTreeMap<String, String>,
    ) {
        let Some(name) = model_text(name, MAX_NAME) else {
            return;
        };
        let project = &self.model.projects[project];
        let path = path.unwrap_or_else(|| project.path.clone());
        if !decode::contains(self.root, &path) {
            return;
        }
        if self.model.targets.len() >= MAX_ITEMS {
            self.model.truncated = true;
            return;
        }
        let tags: Vec<String> = tags
            .into_iter()
            .filter(|tag| is_identifier(tag))
            .collect::<BTreeSet<_>>()
            .into_iter()
            .collect();
        let provider = format!("{}.{}", self.build_system.id, primary_tag(&tags));
        let id = entry_id(&provider, &path, &name);
        if self.model.targets.iter().any(|target| target.id == id) {
            return;
        }
        let project_id = project.id.clone();
        self.model.targets.push(ModelTarget {
            id,
            project_id,
            name,
            path,
            tags,
            properties,
        });
    }

    #[allow(clippy::too_many_arguments)]
    fn add_task(
        &mut self,
        project: usize,
        path: Option<String>,
        name: &str,
        template: &str,
        display_name: Option<String>,
        description: Option<String>,
        category: Vec<String>,
        execution: Option<BuildExecution>,
        properties: BTreeMap<String, String>,
    ) {
        let Some(declaration) = self
            .build_system
            .task(template)
            .filter(|declaration| declaration.from_model)
        else {
            return;
        };
        let Some(name) = model_text(name, MAX_NAME) else {
            return;
        };
        let project = &self.model.projects[project];
        let path = path.unwrap_or_else(|| project.path.clone());
        if !decode::contains(self.root, &path) {
            return;
        }
        if self.model.tasks.len() >= MAX_ITEMS {
            self.model.truncated = true;
            return;
        }
        let provider = format!("{}.{}", self.build_system.id, template);
        let id = entry_id(&provider, &path, &name);
        if self.model.tasks.iter().any(|task| task.id == id) {
            return;
        }
        self.model.tasks.push(ModelTask {
            id,
            project_id: project.id.clone(),
            name,
            path,
            display_name: display_name.and_then(|value| model_text(&value, MAX_NAME)),
            description: description.and_then(|value| model_text(&value, MAX_PROPERTY_VALUE)),
            template: template.to_string(),
            group: declaration.group,
            // A heading the tool reports badly drops the whole path, not the
            // task: the template's category still files it somewhere sensible.
            category: category_labels(&category)
                .filter(|labels| !labels.is_empty())
                .unwrap_or_else(|| declaration.category.clone()),
            execution: execution.unwrap_or(declaration.execution),
            properties,
        });
    }

    fn add_content_root(&mut self, project: usize, path: String, kind: ContentRootKind) -> bool {
        if !decode::contains(self.root, &path) {
            return false;
        }
        if self.model.content_roots.len() >= MAX_ITEMS {
            self.model.truncated = true;
            return false;
        }
        self.model.content_roots.push(ModelContentRoot {
            project_id: self.model.projects[project].id.clone(),
            path,
            kind,
        });
        true
    }

    fn add_option_value(&mut self, option: &str, value: &str) {
        let accepted = self
            .build_system
            .option(option)
            .is_some_and(|declaration| declaration.choices_from_model)
            && super::manifest::is_option_value(value);
        if accepted {
            let values = self.option_values.entry(option.to_string()).or_default();
            if values.len() < MAX_ITEMS {
                values.insert(value.to_string());
            }
        }
    }

    /// Resolves parents, applies the declared layout, and orders entries.
    pub(crate) fn finish(mut self) -> BuildModel {
        let paths: Vec<String> = self.model.projects.iter().map(|p| p.path.clone()).collect();
        let mut parents: Vec<Option<usize>> = Vec::with_capacity(paths.len());
        for (index, explicit) in self.parents.iter().enumerate() {
            let parent = match explicit {
                Some(parent_path) => paths
                    .iter()
                    .enumerate()
                    .find(|(other, path)| *other != index && *path == parent_path)
                    .map(|(other, _)| other),
                None => paths
                    .iter()
                    .enumerate()
                    .filter(|(other, path)| {
                        *other != index
                            && **path != paths[index]
                            && decode::contains(path, &paths[index])
                    })
                    .max_by_key(|(other, path)| (depth(path), std::cmp::Reverse(*other)))
                    .map(|(other, _)| other),
            };
            parents.push(parent);
        }
        // An explicit parent chain that loops back is dropped rather than
        // guessed at.
        for index in 0..parents.len() {
            let mut current = parents[index];
            let mut steps = 0;
            while let Some(next) = current {
                steps += 1;
                if next == index || steps > parents.len() {
                    parents[index] = None;
                    break;
                }
                current = parents[next];
            }
        }
        for (index, parent) in parents.into_iter().enumerate() {
            self.model.projects[index].parent_id =
                parent.map(|parent| self.model.projects[parent].id.clone());
        }

        if let Some(layout) = self.build_system.layout.clone() {
            for index in 0..self.model.projects.len() {
                let base = self.model.projects[index].path.clone();
                for path in &layout.excluded {
                    self.add_content_root(
                        index,
                        decode::join_relative(&base, path),
                        ContentRootKind::Excluded,
                    );
                }
            }
        }

        let mut model = self.model;
        model.projects.sort_by(|left, right| {
            (depth(&left.path), &left.path, &left.name).cmp(&(
                depth(&right.path),
                &right.path,
                &right.name,
            ))
        });
        model.targets.sort_by(|left, right| {
            (&left.project_id, &left.name, &left.id).cmp(&(
                &right.project_id,
                &right.name,
                &right.id,
            ))
        });
        model.tasks.sort_by(|left, right| {
            (&left.project_id, &left.name, &left.id).cmp(&(
                &right.project_id,
                &right.name,
                &right.id,
            ))
        });
        model.content_roots.sort();
        model.content_roots.dedup();
        model.option_values = self
            .option_values
            .into_iter()
            .map(|(id, values)| (id, values.into_iter().collect()))
            .collect();
        model
    }
}

pub(crate) fn depth(path: &str) -> usize {
    if path == "." {
        0
    } else {
        path.matches('/').count() + 1
    }
}

// MARK: Selector maps

/// Fills the model from a decoded document with the plugin's map.
pub(crate) fn map_document(builder: &mut ModelBuilder<'_>, map: &ModelMap, document: &Value) {
    let root = Node::root(document);
    apply_rules(&map.projects, document, &root, |rule, node| {
        map_project(builder, rule, document, node)
    });
    for (option, rule) in &map.option_values {
        for node in select::nodes(&rule.each, document, &root) {
            if select::all_hold(&rule.filter, document, &node) {
                if let Some(value) = rule.value.text(document, &node) {
                    builder.add_option_value(option, &value);
                }
            }
        }
    }
}

/// Applies a rule list: each element a rule selects is offered to `apply`,
/// which reports whether it produced an entry. Fallback rules run only when
/// no other rule in the list produced one.
fn apply_rules<'d, R: RuleMatch>(
    rules: &[R],
    document: &'d Value,
    current: &Node<'d>,
    mut apply: impl FnMut(&R, &Node<'d>) -> bool,
) {
    let mut produced = false;
    for fallback in [false, true] {
        if fallback && produced {
            break;
        }
        for rule in rules.iter().filter(|rule| rule.fallback() == fallback) {
            let nodes = match rule.each() {
                Some(each) => select::nodes(each, document, current),
                None => vec![current.clone()],
            };
            for node in nodes {
                if select::all_hold(rule.filter(), document, &node) {
                    produced |= apply(rule, &node);
                }
            }
        }
    }
}

/// Target rules group a fallback by its tags: an implicit target is skipped
/// when an explicit rule for the same kind already produced one, so an
/// explicit `[[test]]` or `[[example]]` does not hide `src/main.rs`.
fn apply_target_rules(
    builder: &mut ModelBuilder<'_>,
    project: usize,
    base: &str,
    rules: &[TargetRule],
    document: &Value,
    node: &Node<'_>,
) {
    let mut produced: BTreeSet<String> = BTreeSet::new();
    for fallback in [false, true] {
        for rule in rules.iter().filter(|rule| rule.fallback() == fallback) {
            if fallback && rule.tags.iter().any(|tag| produced.contains(tag)) {
                continue;
            }
            let nodes = match rule.each.as_ref() {
                Some(each) => select::nodes(each, document, node),
                None => vec![node.clone()],
            };
            for element in nodes {
                if select::all_hold(rule.filter(), document, &element)
                    && map_target(builder, project, base, rule, document, &element)
                    && !fallback
                {
                    produced.extend(rule.tags.iter().cloned());
                }
            }
        }
    }
}

fn properties(
    specs: &BTreeMap<String, FieldSpec>,
    document: &Value,
    node: &Node<'_>,
) -> BTreeMap<String, String> {
    specs
        .iter()
        .filter_map(|(key, spec)| {
            let value = spec.text(document, node)?;
            Some((key.clone(), model_text(&value, MAX_PROPERTY_VALUE)?))
        })
        .collect()
}

/// A mapped path, workspace-relative, or `None` when absent or outside.
fn mapped_path(
    builder: &ModelBuilder<'_>,
    spec: Option<&FieldSpec>,
    base: &str,
    document: &Value,
    node: &Node<'_>,
) -> Option<Option<String>> {
    match spec {
        None => Some(None),
        Some(spec) => {
            let raw = spec.text(document, node)?;
            builder.workspace.relativize(&raw, base).map(Some)
        }
    }
}

fn when_file_holds(builder: &ModelBuilder<'_>, rule: &impl RuleMatch, directory: &str) -> bool {
    rule.when_file().is_none_or(|file| {
        builder
            .workspace
            .join(&decode::join_relative(directory, file))
            .is_file()
    })
}

fn map_project(
    builder: &mut ModelBuilder<'_>,
    rule: &ProjectRule,
    document: &Value,
    node: &Node<'_>,
) -> bool {
    let root = builder.root.to_string();
    let Some(path) = mapped_path(builder, rule.path.as_ref(), &root, document, node) else {
        return false;
    };
    let path = path.unwrap_or_else(|| root.clone());
    if !when_file_holds(builder, rule, &path) {
        return false;
    }
    let Some(name) = rule.name.text(document, node) else {
        return false;
    };
    let display_name = rule
        .display_name
        .as_ref()
        .and_then(|spec| spec.text(document, node));
    let Some(project) = builder.add_project(
        path.clone(),
        &name,
        display_name,
        None,
        properties(&rule.properties, document, node),
    ) else {
        return false;
    };
    apply_target_rules(builder, project, &path, &rule.targets, document, node);
    apply_rules(
        &rule.content_roots,
        document,
        node,
        |content_root, element| {
            map_content_root(builder, project, &path, content_root, document, element)
        },
    );
    true
}

fn map_target(
    builder: &mut ModelBuilder<'_>,
    project: usize,
    base: &str,
    rule: &TargetRule,
    document: &Value,
    node: &Node<'_>,
) -> bool {
    let Some(path) = mapped_path(builder, rule.path.as_ref(), base, document, node) else {
        return false;
    };
    let directory = path
        .clone()
        .unwrap_or_else(|| builder.model.projects[project].path.clone());
    if !when_file_holds(builder, rule, &directory) {
        return false;
    }
    let Some(name) = rule.name.text(document, node) else {
        return false;
    };
    let count = builder.model.targets.len();
    builder.add_target(
        project,
        path,
        &name,
        rule.tags.clone(),
        properties(&rule.properties, document, node),
    );
    builder.model.targets.len() > count
}

fn map_content_root(
    builder: &mut ModelBuilder<'_>,
    project: usize,
    base: &str,
    rule: &ContentRootRule,
    document: &Value,
    node: &Node<'_>,
) -> bool {
    if !when_file_holds(builder, rule, base) {
        return false;
    }
    let Some(Some(path)) = mapped_path(builder, Some(&rule.path), base, document, node) else {
        return false;
    };
    builder.add_content_root(project, path, rule.kind)
}

// MARK: Canonical format

/// The `litheBuildModel` document a plugin's script prints. Paths are
/// relative to the instance root or absolute inside it. Unknown
/// fields are ignored so newer scripts keep working with older hosts.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct CanonicalModel {
    format: String,
    version: u32,
    #[serde(default)]
    projects: Vec<CanonicalProject>,
    #[serde(default)]
    targets: Vec<CanonicalTarget>,
    #[serde(default)]
    tasks: Vec<CanonicalTask>,
    #[serde(default)]
    content_roots: Vec<CanonicalContentRoot>,
    #[serde(default)]
    option_values: BTreeMap<String, Vec<String>>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct CanonicalProject {
    #[serde(default)]
    path: Option<String>,
    name: String,
    #[serde(default)]
    display_name: Option<String>,
    #[serde(default)]
    parent: Option<String>,
    #[serde(default)]
    properties: BTreeMap<String, Value>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct CanonicalTarget {
    /// Directory of the owning project; otherwise the deepest project
    /// containing `path`, otherwise the root project.
    #[serde(default)]
    project: Option<String>,
    #[serde(default)]
    path: Option<String>,
    name: String,
    #[serde(default)]
    tags: Vec<String>,
    #[serde(default)]
    properties: BTreeMap<String, Value>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct CanonicalTask {
    #[serde(default)]
    project: Option<String>,
    #[serde(default)]
    path: Option<String>,
    name: String,
    template: String,
    #[serde(default)]
    display_name: Option<String>,
    #[serde(default)]
    description: Option<String>,
    #[serde(default)]
    category: Vec<String>,
    #[serde(default)]
    execution: Option<BuildExecution>,
    #[serde(default)]
    properties: BTreeMap<String, Value>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct CanonicalContentRoot {
    #[serde(default)]
    project: Option<String>,
    path: String,
    kind: ContentRootKind,
}

fn canonical_properties(values: &BTreeMap<String, Value>) -> BTreeMap<String, String> {
    values
        .iter()
        .filter(|(key, _)| super::template::is_property_key(key))
        .filter_map(|(key, value)| {
            let text = match value {
                Value::String(text) => text.clone(),
                Value::Number(number) => number.to_string(),
                Value::Bool(flag) => flag.to_string(),
                _ => return None,
            };
            Some((key.clone(), model_text(&text, MAX_PROPERTY_VALUE)?))
        })
        .collect()
}

/// Fills the model from a canonical `litheBuildModel` document.
pub(crate) fn map_canonical(builder: &mut ModelBuilder<'_>, document: Value) -> Validation<()> {
    let model: CanonicalModel = serde_json::from_value(document).map_err(|error| {
        decode::invalid_output(format!(
            "The output is not a litheBuildModel document: {error}"
        ))
    })?;
    if model.format != "litheBuildModel" || model.version != CANONICAL_MODEL_VERSION {
        return Err(decode::invalid_output(format!(
            "Expected litheBuildModel version {CANONICAL_MODEL_VERSION}."
        )));
    }
    let root = builder.root.to_string();
    let relativize = |builder: &ModelBuilder<'_>, raw: &Option<String>| -> Option<Option<String>> {
        match raw {
            None => Some(None),
            Some(raw) => builder.workspace.relativize(raw, &root).map(Some),
        }
    };
    for project in &model.projects {
        let Some(path) = relativize(builder, &project.path) else {
            continue;
        };
        let parent = relativize(builder, &project.parent).flatten();
        builder.add_project(
            path.unwrap_or_else(|| root.clone()),
            &project.name,
            project.display_name.clone(),
            parent,
            canonical_properties(&project.properties),
        );
    }
    // Entries that name no project and no path belong to the outermost one.
    let owner = |builder: &ModelBuilder<'_>, project: &Option<String>, path: &Option<String>| {
        if let Some(Some(project)) = relativize(builder, project) {
            return builder
                .model
                .projects
                .iter()
                .position(|candidate| candidate.path == project);
        }
        match relativize(builder, path) {
            Some(Some(path)) => builder.containing_project(&path),
            Some(None) => builder.containing_project(&root),
            None => None,
        }
    };
    for target in &model.targets {
        let (Some(project), Some(path)) = (
            owner(builder, &target.project, &target.path),
            relativize(builder, &target.path),
        ) else {
            continue;
        };
        builder.add_target(
            project,
            path,
            &target.name,
            target.tags.clone(),
            canonical_properties(&target.properties),
        );
    }
    for task in &model.tasks {
        let (Some(project), Some(path)) = (
            owner(builder, &task.project, &task.path),
            relativize(builder, &task.path),
        ) else {
            continue;
        };
        builder.add_task(
            project,
            path,
            &task.name,
            &task.template,
            task.display_name.clone(),
            task.description.clone(),
            task.category.clone(),
            task.execution,
            canonical_properties(&task.properties),
        );
    }
    for content_root in &model.content_roots {
        let Some(project) = owner(builder, &content_root.project, &None) else {
            continue;
        };
        // Like every canonical path, a content root is relative to the
        // instance root, not to its project; `project` only names the owner.
        if let Some(Some(path)) = relativize(builder, &Some(content_root.path.clone())) {
            builder.add_content_root(project, path, content_root.kind);
        }
    }
    for (option, values) in &model.option_values {
        for value in values {
            builder.add_option_value(option, value);
        }
    }
    Ok(())
}

// MARK: Host integration input

/// Adds a project found by a host integration. Paths are workspace-relative.
pub(crate) fn add_integration_project(
    builder: &mut ModelBuilder<'_>,
    path: String,
    name: &str,
    properties: BTreeMap<String, String>,
) -> Option<usize> {
    builder.add_project(path, name, None, None, properties)
}

pub(crate) fn add_integration_content_root(
    builder: &mut ModelBuilder<'_>,
    project: usize,
    path: String,
    kind: ContentRootKind,
) {
    builder.add_content_root(project, path, kind);
}

pub(crate) fn add_integration_option_value(
    builder: &mut ModelBuilder<'_>,
    option: &str,
    value: &str,
) {
    builder.add_option_value(option, value);
}
