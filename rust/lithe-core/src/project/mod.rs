//! Project files, search, local history, and document rendering services.

mod document_lifecycle;
pub(crate) mod files;
mod history;
mod markdown;
mod maven;
mod maven_dependency_tree;
mod maven_test_reports;
mod search_index;

pub(crate) use document_lifecycle::*;
pub(crate) use files::*;
pub(crate) use history::*;
pub(crate) use markdown::*;
pub(crate) use maven::*;
pub(crate) use maven_dependency_tree::{dependencies, MavenDependenciesRequest};
