//! Project files, search, local history, and document rendering services.

pub(crate) mod directory_actions;
mod document_lifecycle;
pub(crate) mod document_save_batch;
pub(crate) mod file_name_order;
pub(crate) mod file_operations;
pub(crate) mod files;
mod history;
pub(crate) mod indexing;
mod markdown;
mod name_matching;
pub(crate) mod name_ranking;
pub(crate) mod recent_projects;
mod search_index;
mod search_paging;
pub(crate) use search_paging::{search_page, SearchPageRequest};

pub(crate) use document_lifecycle::*;
pub(crate) use files::*;
pub(crate) use history::*;
pub(crate) use markdown::*;

pub use files::{
    filter_workspace_changes, is_workspace_event_relevant, WorkspaceChangeFilterRequest,
};
