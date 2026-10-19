//! Named host integrations: host code a build system may delegate one
//! concern to when its output fits neither a selector map nor a canonical
//! format yet.
//!
//! Only official plugins may name one, and each exists to migrate a
//! built-in tool onto the plugin model without changing its behavior. A new
//! build system never needs one; a new integration needs a reviewed reason
//! why the declarative contract cannot express it.

mod maven;

use super::decode::Workspace;
use super::manifest::{BuildSystemDeclaration, HOST_INTEGRATION_MAVEN};
use super::model::ModelBuilder;
use super::outputs::{DecodeTestResultsRequest, DependencyNode, TestResults};
use super::plans::{PlanContext, Selection};
use super::template;
use crate::plugins::declarative::{PluginRejection, Validation};
use crate::protocol::CoreError;
use serde_json::Value;

fn missing(build_system: &BuildSystemDeclaration) -> PluginRejection {
    PluginRejection::new(
        "plugin.integration.unsupported",
        format!(
            "{} names no host integration this host provides.",
            build_system.display_name
        ),
    )
}

/// Host-side failures surface as invalid output: the integration could not
/// read what the tool left behind.
fn rejected(error: CoreError) -> PluginRejection {
    PluginRejection::new("plugin.build.invalidOutput", error.message)
}

pub(crate) fn model(
    build_system: &BuildSystemDeclaration,
    workspace: &Workspace,
    root: &str,
    builder: &mut ModelBuilder<'_>,
) -> Validation<()> {
    match build_system.integration() {
        Some(HOST_INTEGRATION_MAVEN) => maven::model(workspace, root, builder),
        _ => Err(missing(build_system)),
    }
}

pub(crate) fn dependency_plan(
    context: &PlanContext<'_>,
    project: Option<&Selection>,
    output_file: Option<&str>,
) -> Validation<Value> {
    match context.build_system.integration() {
        Some(HOST_INTEGRATION_MAVEN) => {
            let tail = maven::dependency_arguments(project, output_file)?;
            context.plan_with_arguments(
                integration_arguments(context, tail)?,
                super::manifest::BuildExecution::Task,
                maven::dependency_plan_extra(),
            )
        }
        _ => Err(missing(context.build_system)),
    }
}

pub(crate) fn dependencies(
    build_system: &BuildSystemDeclaration,
    root: &str,
    project: &str,
    output_file: Option<&str>,
) -> Validation<Vec<DependencyNode>> {
    match build_system.integration() {
        Some(HOST_INTEGRATION_MAVEN) => maven::dependencies(root, project, output_file),
        _ => Err(missing(build_system)),
    }
}

pub(crate) fn test_results(
    build_system: &BuildSystemDeclaration,
    workspace: &Workspace,
    root: &str,
    project: &str,
    request: &DecodeTestResultsRequest,
) -> Validation<TestResults> {
    match build_system.integration() {
        Some(HOST_INTEGRATION_MAVEN) => maven::test_results(workspace, root, project, request),
        _ => Err(missing(build_system)),
    }
}

/// Global arguments, then the arguments of every option the globals do not
/// place themselves, then the integration's own: the same order a declared
/// command would produce when it lists `${optionArguments}` for the rest.
fn integration_arguments(context: &PlanContext<'_>, tail: Vec<String>) -> Validation<Vec<String>> {
    let globals = &context.build_system.invocation.global_arguments;
    let values = template::Values {
        root: &context.root,
        option_arguments: &context.contribution.arguments,
        ..template::Values::default()
    };
    let mut arguments = template::expand(globals, &values)?;
    let (all, named) = template::option_references(globals);
    if !all {
        for (id, expanded) in &context.contribution.arguments {
            if !named.contains(id) {
                arguments.extend(expanded.iter().cloned());
            }
        }
    }
    arguments.extend(tail);
    Ok(arguments)
}
