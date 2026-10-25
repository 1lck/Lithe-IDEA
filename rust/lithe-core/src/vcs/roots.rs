//! Which VCS owns which directory of a workspace.
//!
//! Roots are found from static markers only, so opening a workspace never
//! starts a provider. One bounded walk serves every provider: it records the
//! markers directly inside each directory, never descends into a VCS's own
//! metadata directory or through a symbolic link, and stops at a depth and
//! directory budget. When the workspace root itself carries no marker, its
//! ancestors are checked too, because a Subversion working copy has a single
//! `.svn` at its top and a workspace may be opened below it.
//!
//! A file belongs to the deepest root that contains it. A directory with
//! markers of several providers is ambiguous and owns nothing until the
//! user maps it to one of them; Core never guesses.

use super::manifest::{MarkerKind, VcsMarker};
use super::model::is_root_relative;
use std::collections::{BTreeMap, BTreeSet, VecDeque};
use std::fs::{self, FileType};
use std::path::{Path, PathBuf};

/// Deepest directory, below the workspace root, whose markers are read.
const MAX_DEPTH: usize = 8;
/// Most directories one detection reads before reporting a partial result.
const MAX_DIRECTORIES: usize = 20_000;

/// Directories that hold generated or downloaded files and never a working
/// copy worth tracking, and whose size would dominate the walk. Lithe's own
/// worktrees are pruned so they are not listed as nested repositories.
const PRUNED: &[&str] = &[
    ".build",
    ".cargo",
    ".dart_tool",
    ".gradle",
    ".idea",
    ".lithe",
    ".mypy_cache",
    ".next",
    ".nuxt",
    ".pytest_cache",
    ".stack-work",
    ".svelte-kit",
    ".swiftpm",
    ".terraform",
    ".tox",
    ".venv",
    ".vscode",
    ".worktree",
    ".worktrees",
    "DerivedData",
    "Pods",
    "__pycache__",
    "bower_components",
    "node_modules",
    "target",
];

/// The markers of one VCS, as detection sees them.
pub(crate) struct MarkerSet<'a> {
    pub(crate) vcs: &'a str,
    pub(crate) markers: &'a [VcsMarker],
}

/// A detected root. `id` is workspace-relative with `/` separators: `""` is
/// the workspace root and `..` segments name an enclosing directory.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Root {
    pub(crate) id: String,
    pub(crate) vcs: String,
    pub(crate) path: PathBuf,
    /// Whether the user's mapping, not a single marker, chose the VCS.
    pub(crate) mapped: bool,
}

/// A directory with markers of several VCSs and no mapping.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Ambiguous {
    pub(crate) id: String,
    pub(crate) vcs: Vec<String>,
}

/// The user's choice for an ambiguous directory.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Mapping {
    pub(crate) id: String,
    pub(crate) vcs: String,
}

#[derive(Debug, Default)]
pub(crate) struct Detection {
    pub(crate) roots: Vec<Root>,
    pub(crate) ambiguous: Vec<Ambiguous>,
    /// Mappings that name no ambiguous directory, or a VCS whose markers
    /// are not there. Hosts may offer to forget them.
    pub(crate) unused_mappings: Vec<Mapping>,
    /// Whether the directory budget cut the walk short, so a root may be
    /// missing. Roots deeper than [`MAX_DEPTH`] are never looked for.
    pub(crate) truncated: bool,
}

/// Whether `id` names a directory enclosing the workspace: only `..`
/// segments. A directory inside the workspace may still be named `..repo`.
fn is_enclosing(id: &str) -> bool {
    !id.is_empty() && id.split('/').all(|segment| segment == "..")
}

/// Sort key that puts enclosing roots first, then inner roots by depth.
pub(crate) fn depth(id: &str) -> i64 {
    if id.is_empty() {
        return 0;
    }
    let segments = id.split('/').count() as i64;
    if is_enclosing(id) {
        -segments
    } else {
        segments
    }
}

/// Whether `id` has the shape of a root or ambiguous-directory ID: `""`,
/// only `..` segments, or a path inside the workspace.
pub(crate) fn is_directory_id(id: &str) -> bool {
    id.is_empty() || is_enclosing(id) || is_root_relative(id)
}

/// Whether the root or ambiguous directory `id` contains the
/// workspace-relative `path`.
fn contains(id: &str, path: &str) -> bool {
    id.is_empty()
        || is_enclosing(id)
        || path == id
        || path
            .strip_prefix(id)
            .is_some_and(|rest| rest.starts_with('/'))
}

/// The root ID that owns a workspace-relative path, or `None` when the path
/// is outside every root or inside an unmapped ambiguous directory.
pub(crate) fn owner<'a>(roots: &'a [String], ambiguous: &[String], path: &str) -> Option<&'a str> {
    let deepest_root = roots
        .iter()
        .filter(|root| contains(root, path))
        .max_by_key(|root| depth(root));
    let deepest_ambiguous = ambiguous
        .iter()
        .filter(|directory| contains(directory, path))
        .map(|directory| depth(directory))
        .max();
    match (deepest_root, deepest_ambiguous) {
        (Some(root), Some(ambiguous)) if ambiguous > depth(root) => None,
        (root, _) => root.map(String::as_str),
    }
}

/// Resolves a directory entry's kind, following a link only for the
/// marker check itself (a `.git` that links elsewhere still marks a root).
fn marker_kind(path: &Path, file_type: FileType) -> Option<MarkerKind> {
    let file_type = if file_type.is_symlink() {
        fs::metadata(path).ok()?.file_type()
    } else {
        file_type
    };
    if file_type.is_dir() {
        Some(MarkerKind::Directory)
    } else if file_type.is_file() {
        Some(MarkerKind::File)
    } else {
        None
    }
}

fn matches(sets: &[MarkerSet<'_>], name: &str, kind: MarkerKind) -> Vec<String> {
    sets.iter()
        .filter(|set| {
            set.markers
                .iter()
                .any(|marker| marker.name == name && marker.kind == kind)
        })
        .map(|set| set.vcs.to_string())
        .collect()
}

/// VCSs whose markers sit directly in `directory`, checked by name.
fn markers_at(directory: &Path, sets: &[MarkerSet<'_>]) -> BTreeSet<String> {
    let names: BTreeSet<&str> = sets
        .iter()
        .flat_map(|set| set.markers.iter().map(|marker| marker.name.as_str()))
        .collect();
    let mut found = BTreeSet::new();
    for name in names {
        let path = directory.join(name);
        let Ok(metadata) = fs::symlink_metadata(&path) else {
            continue;
        };
        if let Some(kind) = marker_kind(&path, metadata.file_type()) {
            found.extend(matches(sets, name, kind));
        }
    }
    found
}

/// Walks the workspace and its ancestors. `workspace` must be absolute.
pub(crate) fn detect(workspace: &Path, sets: &[MarkerSet<'_>], mappings: &[Mapping]) -> Detection {
    let metadata_directories: BTreeSet<&str> = sets
        .iter()
        .flat_map(|set| set.markers.iter())
        .filter(|marker| marker.kind == MarkerKind::Directory)
        .map(|marker| marker.name.as_str())
        .collect();
    let mut found: BTreeMap<String, (PathBuf, BTreeSet<String>)> = BTreeMap::new();
    let mut truncated = false;
    let mut visited = 0usize;
    let mut queue = VecDeque::from([(workspace.to_path_buf(), String::new(), 0usize)]);
    // Breadth first, children sorted by name: when the budget runs out the
    // shallow roots are kept, and two runs over one tree agree.
    while let Some((directory, relative, level)) = queue.pop_front() {
        if visited == MAX_DIRECTORIES {
            truncated = true;
            break;
        }
        visited += 1;
        let Ok(entries) = fs::read_dir(&directory) else {
            continue;
        };
        let mut entries: Vec<_> = entries
            .flatten()
            .filter_map(|entry| {
                let name = entry.file_name().to_str()?.to_string();
                Some((name, entry.path(), entry.file_type().ok()?))
            })
            .collect();
        entries.sort_by(|left, right| left.0.cmp(&right.0));
        let mut here = BTreeSet::new();
        for (name, path, file_type) in entries {
            if let Some(kind) = marker_kind(&path, file_type) {
                here.extend(matches(sets, &name, kind));
            }
            // Source trees are routinely deeper than the limit, so stopping
            // there is the rule rather than a partial result.
            if !file_type.is_dir()
                || level == MAX_DEPTH
                || metadata_directories.contains(name.as_str())
                || PRUNED.contains(&name.as_str())
            {
                continue;
            }
            let child = if relative.is_empty() {
                name
            } else {
                format!("{relative}/{name}")
            };
            queue.push_back((path, child, level + 1));
        }
        if !here.is_empty() {
            found.insert(relative, (directory, here));
        }
    }

    if !found.contains_key("") {
        let mut id = String::from("..");
        let mut ancestor = workspace.parent();
        while let Some(directory) = ancestor {
            let here = markers_at(directory, sets);
            if !here.is_empty() {
                found.insert(id, (directory.to_path_buf(), here));
                break;
            }
            id.push_str("/..");
            ancestor = directory.parent();
        }
    }

    let mut detection = Detection {
        truncated,
        ..Detection::default()
    };
    let mut used = BTreeSet::new();
    for (id, (path, vcs)) in found {
        if vcs.len() == 1 {
            let vcs = vcs.into_iter().next().unwrap_or_default();
            detection.roots.push(Root {
                id,
                vcs,
                path,
                mapped: false,
            });
            continue;
        }
        match mappings
            .iter()
            .find(|mapping| mapping.id == id && vcs.contains(&mapping.vcs))
        {
            Some(mapping) => {
                used.insert((mapping.id.clone(), mapping.vcs.clone()));
                detection.roots.push(Root {
                    id,
                    vcs: mapping.vcs.clone(),
                    path,
                    mapped: true,
                });
            }
            None => detection.ambiguous.push(Ambiguous {
                id,
                vcs: vcs.into_iter().collect(),
            }),
        }
    }
    detection.unused_mappings = mappings
        .iter()
        .filter(|mapping| !used.contains(&(mapping.id.clone(), mapping.vcs.clone())))
        .cloned()
        .collect();
    detection
        .unused_mappings
        .sort_by(|left, right| (&left.id, &left.vcs).cmp(&(&right.id, &right.vcs)));
    detection.unused_mappings.dedup();
    detection
        .roots
        .sort_by(|left, right| (depth(&left.id), &left.id).cmp(&(depth(&right.id), &right.id)));
    detection
        .ambiguous
        .sort_by(|left, right| (depth(&left.id), &left.id).cmp(&(depth(&right.id), &right.id)));
    detection
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ids(values: &[&str]) -> Vec<String> {
        values.iter().map(ToString::to_string).collect()
    }

    #[test]
    fn the_deepest_root_owns_a_path_and_ambiguity_blocks_fallback() {
        let roots = ids(&["..", "", "a/b"]);
        let ambiguous = ids(&["m"]);
        let owner_of = |path| owner(&roots, &ambiguous, path);
        assert_eq!(owner_of("README.md"), Some(""));
        assert_eq!(owner_of("a/b/c.txt"), Some("a/b"));
        assert_eq!(owner_of("a/bc.txt"), Some(""));
        // Files below an unmapped ambiguous directory belong to nobody, not
        // to the enclosing Git root.
        assert_eq!(owner_of("m/x.txt"), None);
        assert_eq!(owner_of("mx.txt"), Some(""));
    }

    #[test]
    fn a_directory_named_like_dot_dot_is_inside_the_workspace() {
        let roots = ids(&["", "..repo"]);
        let owner_of = |path| owner(&roots, &[], path);
        assert_eq!(owner_of("..repo/a.txt"), Some("..repo"));
        assert_eq!(owner_of("README.md"), Some(""));
        // Without a workspace root, `..repo` owns only its own files.
        let inner = ids(&["..repo"]);
        assert_eq!(owner(&inner, &[], "src/main.rs"), None);
        assert_eq!(depth("..repo"), 1);
        assert!(is_directory_id("..repo/x"));
    }

    #[test]
    fn enclosing_roots_sort_before_inner_ones() {
        let mut ids = vec!["a/b", "", "../..", "a", ".."];
        ids.sort_by_key(|id| (depth(id), *id));
        assert_eq!(ids, ["../..", "..", "", "a", "a/b"]);
    }

    #[test]
    fn directory_ids_are_enclosing_or_inside_the_workspace() {
        for id in ["", "..", "../..", "a", "a/b"] {
            assert!(is_directory_id(id), "{id}");
        }
        for id in ["/a", "../a", "a/..", "a//b", "./a", "a\\b"] {
            assert!(!is_directory_id(id), "{id}");
        }
    }
}
