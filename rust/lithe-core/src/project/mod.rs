//! Project files, search, local history, and document rendering services.

mod document_lifecycle;
pub(crate) mod file_name_order;
pub(crate) mod files;
mod history;
mod markdown;
mod maven;
mod maven_dependency_tree;
mod maven_test_reports;
mod name_matching;
mod search_index;

pub(crate) use document_lifecycle::*;
pub(crate) use files::*;
pub(crate) use history::*;
pub(crate) use markdown::*;
pub(crate) use maven::*;
pub(crate) use maven_dependency_tree::{
    dependencies, dependency_tree_arguments, validated_output_file, MavenDependenciesRequest,
};
pub(crate) use maven_test_reports::MavenTestReportsRequest;

pub use files::is_workspace_event_relevant;
