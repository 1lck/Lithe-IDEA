//! IDEA-compatible new-branch name cleanup and conflict validation.
//!
//! Both native products show the same new-branch dialog, so the cleanup rules
//! mirrored from IDEA's `GitRefNameValidator` and the `git.branch.cleanup.symbol`
//! default live here instead of in either platform. The module is pure: it never
//! starts Git and only reads the reference facts the caller already loaded.

use crate::protocol::{CoreError, ErrorCode};
use serde::{Deserialize, Serialize};
use std::collections::HashSet;

/// Longest raw name accepted from the dialog. The limit keeps a pathological
/// paste from crossing the boundary without adding any correctness value; IDEA
/// rejects refnames far earlier through `git check-ref-format`.
const MAX_RAW_NAME_CHARS: usize = 1024;
/// Replacement for spaces and control characters, matching IDEA's
/// `git.branch.cleanup.symbol` advanced-setting default.
const CLEANUP_SYMBOL: char = '-';

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Request for the cleaned and validated forms of a new branch name.
pub struct GitBranchNamePreviewRequest {
    /// Text exactly as the user typed it. Ref validity is still decided by Git
    /// when the branch is created.
    pub raw_name: String,
    /// `true` on submit, where an empty name is an error; `false` while typing.
    #[serde(default)]
    pub require_name: bool,
    /// Reference facts already loaded by the platform. Core never re-reads Git.
    #[serde(default)]
    pub references: Vec<GitBranchNameReference>,
    /// Reference the dialog was opened on, used only to propose `initialName`.
    #[serde(default)]
    pub reference: Option<GitBranchNameReference>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
/// One loaded reference fact used by new-branch conflict validation.
pub struct GitBranchNameReference {
    /// Reference namespace: `local`, `remote`, or `tag`.
    pub kind: GitBranchNameReferenceKind,
    /// User-facing short name, such as `main` or `origin/main`.
    pub short_name: String,
}

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
/// Reference namespaces that participate in new-branch validation.
pub enum GitBranchNameReferenceKind {
    /// Local branch under `refs/heads/`.
    Local,
    /// Remote-tracking branch under `refs/remotes/`.
    Remote,
    /// Tag under `refs/tags/`; it does not occupy the branch namespace.
    Tag,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
/// Stable new-branch validation outcomes shared by both products.
pub enum GitBranchNameErrorCode {
    /// The submit-time name is empty.
    Empty,
    /// The name would create `HEAD`, which Git reserves.
    Head,
    /// A remote-tracking branch already uses the name.
    ClashesWithRemote,
    /// A local branch is stored as a directory of that name.
    ClashesWithDirectory,
    /// A local branch already uses the name.
    AlreadyExists,
    /// A local branch occupies one of the name's `/` prefixes.
    ClashesWithBranchPrefix,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
/// Structured conflict returned to the dialog for localized presentation.
pub struct GitBranchNameError {
    pub code: GitBranchNameErrorCode,
    /// Candidate name or conflicting directory reported by the conflict code.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    /// Existing local branch that occupies a slash prefix of the candidate name.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub branch: Option<String>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
/// Cleaned name forms and the submit-time conflict for one raw dialog input.
pub struct GitBranchNamePreviewResponse {
    /// Cleanup applied while typing: invalid characters are dropped and spaces
    /// or control characters become the cleanup symbol.
    pub typing_cleaned_name: String,
    /// Submit-time cleanup: [`Self::typing_cleaned_name`] without a trailing
    /// dot, slash, or `.lock`, trimmed at the edges.
    pub cleaned_name: String,
    /// Proposed initial name for the opened reference; empty without one.
    pub initial_name: String,
    /// Submit-time conflict, or `null` when the cleaned name is usable.
    pub error: Option<GitBranchNameError>,
}

/// Builds the cleaned name forms and submit-time conflict for one dialog input.
///
/// `rawName` over [`MAX_RAW_NAME_CHARS`] characters is rejected with
/// `invalid_request`. Everything else is a pure transformation of the request.
pub fn preview(
    request: GitBranchNamePreviewRequest,
) -> Result<GitBranchNamePreviewResponse, CoreError> {
    if request.raw_name.chars().count() > MAX_RAW_NAME_CHARS {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Git branch name input is too long",
        ));
    }
    let typing_cleaned_name = clean_branch_name_on_typing(&request.raw_name);
    // The dialog trims the submit-time form, so validation runs on the exact
    // value the create command will receive.
    let cleaned_name = clean_branch_name(&request.raw_name).trim().to_string();
    let error = validate_new_branch_name(&cleaned_name, &request.references, request.require_name);
    Ok(GitBranchNamePreviewResponse {
        typing_cleaned_name,
        cleaned_name,
        initial_name: request
            .reference
            .as_ref()
            .map(initial_branch_name)
            .unwrap_or_default(),
        error,
    })
}

/// IDEA's typing-time cleanup: drop refname-invalid characters and fold spaces
/// and control characters into the cleanup symbol.
fn clean_branch_name_on_typing(raw_name: &str) -> String {
    let characters = raw_name.chars().collect::<Vec<_>>();
    let mut dropped = String::with_capacity(raw_name.len());
    let mut index = 0;
    while index < characters.len() {
        let character = characters[index];
        // `(^\.)`, `(^-)`, `(^/)`: IDEA only drops the leading character, so a
        // pasted `--name` keeps its second dash and Git rejects it on apply.
        if index == 0 && matches!(character, '.' | '-' | '/') {
            index += 1;
            continue;
        }
        if is_dropped_character(character) {
            // `[~:^?*"\[\\]+` consumes a maximal invalid run.
            index += 1;
            while index < characters.len() && is_dropped_character(characters[index]) {
                index += 1;
            }
            continue;
        }
        if character == '@' && characters.get(index + 1) == Some(&'{') {
            // `(@\{)+` drops every `@{` sequence that starts at this index.
            index += 2;
            while index + 1 < characters.len()
                && characters[index] == '@'
                && characters[index + 1] == '{'
            {
                index += 2;
            }
            continue;
        }
        if character == '/' && characters.get(index + 1) == Some(&'/') {
            // `/(?=/)` drops the first slash of every doubled slash but leaves
            // the rest of the run for the next scan.
            index += 1;
            continue;
        }
        if character == '.' {
            let previous = index.checked_sub(1).map(|position| characters[position]);
            if characters.get(index + 1) == Some(&'.') {
                // `(\.(?=\.))+` keeps the last dot of a run so `a..b` becomes
                // `a.b`; a single dot is not a match.
                index += 1;
                continue;
            }
            // `\.(?=/)` and `(?<=/)\.` remove dots next to a slash.
            if characters.get(index + 1) == Some(&'/') || previous == Some('/') {
                index += 1;
                continue;
            }
        }
        dropped.push(character);
        index += 1;
    }
    fold_spaces_and_controls(&dropped)
}

/// ` +|[\u0000-\u001f\u007f]`: one cleanup symbol per space run or control char.
fn fold_spaces_and_controls(name: &str) -> String {
    let mut folded = String::with_capacity(name.len());
    let mut pending_space = false;
    for character in name.chars() {
        if character == ' ' {
            pending_space = true;
            continue;
        }
        if pending_space {
            folded.push(CLEANUP_SYMBOL);
            pending_space = false;
        }
        if is_control_character(character) {
            folded.push(CLEANUP_SYMBOL);
        } else {
            folded.push(character);
        }
    }
    if pending_space {
        folded.push(CLEANUP_SYMBOL);
    }
    folded
}

/// Submit-time cleanup: typing cleanup plus one trailing `[./]` or `.lock`.
fn clean_branch_name(raw_name: &str) -> String {
    let cleaned = clean_branch_name_on_typing(raw_name);
    if let Some(stripped) = cleaned.strip_suffix(".lock") {
        stripped.to_string()
    } else if cleaned.ends_with(['.', '/']) {
        cleaned[..cleaned.len() - 1].to_string()
    } else {
        cleaned
    }
}

/// IDEA's `calculateNewBranchInitialName`: a remote reference loses its first
/// segment, everything else keeps its short name.
fn initial_branch_name(reference: &GitBranchNameReference) -> String {
    if reference.kind != GitBranchNameReferenceKind::Remote {
        return reference.short_name.clone();
    }
    match reference.short_name.find('/') {
        Some(separator) => reference.short_name[separator + 1..].to_string(),
        None => reference.short_name.clone(),
    }
}

/// Characters IDEA drops because they cannot appear in a branch refname.
///
/// This mirrors `GitRefNameValidator`'s invalid-character set. Whether the final
/// name passes `git check-ref-format` is still Git's decision.
fn is_dropped_character(character: char) -> bool {
    matches!(character, '~' | ':' | '^' | '?' | '*' | '"' | '[' | '\\')
}

/// ASCII controls and DEL, which IDEA replaces with the cleanup symbol.
fn is_control_character(character: char) -> bool {
    matches!(character, '\u{0}'..='\u{1f}' | '\u{7f}')
}

/// Validates an already cleaned name against loaded references in IDEA's order:
/// empty/HEAD, remote branch clash, local branch directory clash, an existing
/// local branch, then a local branch occupying one of the name's `/` prefixes.
fn validate_new_branch_name(
    name: &str,
    references: &[GitBranchNameReference],
    require_name: bool,
) -> Option<GitBranchNameError> {
    if name.trim().is_empty() {
        return require_name.then(|| GitBranchNameError {
            code: GitBranchNameErrorCode::Empty,
            name: None,
            branch: None,
        });
    }
    if name.to_lowercase() == "head" {
        return Some(GitBranchNameError {
            code: GitBranchNameErrorCode::Head,
            name: None,
            branch: None,
        });
    }
    let local_names = references
        .iter()
        .filter(|reference| reference.kind == GitBranchNameReferenceKind::Local)
        .map(|reference| reference.short_name.as_str())
        .collect::<Vec<_>>();
    let conflict = |code, conflicting: &str| GitBranchNameError {
        code,
        name: Some(conflicting.to_string()),
        branch: None,
    };
    if references.iter().any(|reference| {
        reference.kind == GitBranchNameReferenceKind::Remote && reference.short_name == name
    }) {
        return Some(conflict(GitBranchNameErrorCode::ClashesWithRemote, name));
    }
    // Git stores branches as loose refs, so `feature` and `feature/x` cannot
    // coexist: reject a name that is already a directory of local branches.
    if collect_directories(&local_names).contains(name) {
        return Some(conflict(GitBranchNameErrorCode::ClashesWithDirectory, name));
    }
    if local_names.contains(&name) {
        return Some(conflict(GitBranchNameErrorCode::AlreadyExists, name));
    }
    find_branch_prefix_clash(name, &local_names).map(|branch| GitBranchNameError {
        code: GitBranchNameErrorCode::ClashesWithBranchPrefix,
        name: Some(name.to_string()),
        branch: Some(branch.to_string()),
    })
}

/// Every `/` prefix of every local branch name, which loose refs treat as
/// directories that a new branch name may collide with.
fn collect_directories<'a>(branch_names: &[&'a str]) -> HashSet<&'a str> {
    let mut directories = HashSet::new();
    for branch_name in branch_names {
        let mut index = branch_name.find('/');
        while let Some(position) = index {
            directories.insert(&branch_name[..position]);
            index = branch_name[position + 1..]
                .find('/')
                .map(|next| position + 1 + next);
        }
    }
    directories
}

/// Finds a local branch that occupies one of `name`'s slash prefixes, the
/// opposite direction of the directory clash.
fn find_branch_prefix_clash<'a>(name: &str, local_names: &[&'a str]) -> Option<&'a str> {
    let mut search_from = 0;
    while let Some(offset) = name[search_from..].find('/') {
        let position = search_from + offset;
        let prefix = &name[..position];
        if let Some(branch) = local_names.iter().find(|branch| **branch == prefix) {
            return Some(branch);
        }
        search_from = position + 1;
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct CleanupParityFixture {
        cases: Vec<CleanupParityCase>,
    }

    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct CleanupParityCase {
        raw_name: String,
        typing_cleaned_name: String,
        cleaned_name: String,
    }

    fn reference(kind: GitBranchNameReferenceKind, short_name: &str) -> GitBranchNameReference {
        GitBranchNameReference {
            kind,
            short_name: short_name.to_string(),
        }
    }

    #[test]
    fn cleanup_matches_the_windows_idea_validator_vectors() {
        // The fixture records the Windows implementation's output before the
        // algorithm moved into Core, so this test pins cross-platform parity.
        let fixture: CleanupParityFixture = serde_json::from_str(include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/src/tests/fixtures/branch-name-cleanup-parity-v1.json"
        )))
        .expect("branch cleanup parity fixture should be valid JSON");
        assert!(!fixture.cases.is_empty());
        for case in fixture.cases {
            assert_eq!(
                clean_branch_name_on_typing(&case.raw_name),
                case.typing_cleaned_name,
                "typing cleanup differs for {:?}",
                case.raw_name
            );
            assert_eq!(
                clean_branch_name(&case.raw_name),
                case.cleaned_name,
                "submit cleanup differs for {:?}",
                case.raw_name
            );
        }
    }

    #[test]
    fn initial_name_keeps_local_names_and_drops_the_remote_prefix() {
        assert_eq!(
            initial_branch_name(&reference(
                GitBranchNameReferenceKind::Local,
                "feature/login"
            )),
            "feature/login"
        );
        assert_eq!(
            initial_branch_name(&reference(
                GitBranchNameReferenceKind::Remote,
                "origin/feature/login"
            )),
            "feature/login"
        );
        assert_eq!(
            initial_branch_name(&reference(GitBranchNameReferenceKind::Remote, "origin")),
            "origin"
        );
        assert_eq!(
            initial_branch_name(&reference(GitBranchNameReferenceKind::Tag, "v1")),
            "v1"
        );
    }

    #[test]
    fn validation_follows_idea_order_and_only_requires_a_name_on_apply() {
        let references = vec![
            reference(GitBranchNameReferenceKind::Local, "main"),
            reference(GitBranchNameReferenceKind::Local, "feature/login"),
            reference(GitBranchNameReferenceKind::Remote, "origin/main"),
            reference(GitBranchNameReferenceKind::Tag, "v1"),
        ];
        let error = |name: &str, require_name: bool| {
            validate_new_branch_name(name, &references, require_name).map(|error| error.code)
        };
        assert_eq!(error("", false), None);
        assert_eq!(error("", true), Some(GitBranchNameErrorCode::Empty));
        assert_eq!(error("head", false), Some(GitBranchNameErrorCode::Head));
        assert_eq!(
            error("origin/main", false),
            Some(GitBranchNameErrorCode::ClashesWithRemote)
        );
        assert_eq!(
            error("feature", false),
            Some(GitBranchNameErrorCode::ClashesWithDirectory)
        );
        assert_eq!(
            error("main", false),
            Some(GitBranchNameErrorCode::AlreadyExists)
        );
        assert_eq!(error("feature/signup", false), None);
        // Tags do not occupy the branch namespace checked by the dialog.
        assert_eq!(error("v1", false), None);
    }

    #[test]
    fn a_slash_prefix_occupied_by_a_local_branch_is_a_prefix_clash() {
        let flat = vec![
            reference(GitBranchNameReferenceKind::Local, "main"),
            reference(GitBranchNameReferenceKind::Local, "feature"),
        ];
        let clash = validate_new_branch_name("feature/login", &flat, false)
            .expect("a local branch prefix should conflict");
        assert_eq!(clash.code, GitBranchNameErrorCode::ClashesWithBranchPrefix);
        assert_eq!(clash.name.as_deref(), Some("feature/login"));
        assert_eq!(clash.branch.as_deref(), Some("feature"));

        // The clash may sit deeper than the first segment.
        let nested = vec![reference(GitBranchNameReferenceKind::Local, "a/b")];
        let clash = validate_new_branch_name("a/b/c", &nested, false)
            .expect("a nested local branch prefix should conflict");
        assert_eq!(clash.branch.as_deref(), Some("a/b"));

        // A prefix that is only a directory of other branches is not a clash.
        let nested_only = vec![
            reference(GitBranchNameReferenceKind::Local, "main"),
            reference(GitBranchNameReferenceKind::Local, "feature/login"),
        ];
        assert!(validate_new_branch_name("feature/signup", &nested_only, false).is_none());
        // Remote branches do not occupy the local ref namespace under validation.
        let remote_only = vec![reference(
            GitBranchNameReferenceKind::Remote,
            "origin/release",
        )];
        assert!(validate_new_branch_name("release/next", &remote_only, false).is_none());
    }

    #[test]
    fn preview_returns_submit_cleaning_initial_name_and_structured_conflicts() {
        let response = preview(GitBranchNamePreviewRequest {
            raw_name: "  topic ".into(),
            require_name: true,
            references: vec![reference(GitBranchNameReferenceKind::Local, "main")],
            reference: Some(reference(GitBranchNameReferenceKind::Remote, "origin/main")),
        })
        .expect("a bounded raw name should preview");
        assert_eq!(response.typing_cleaned_name, "-topic-");
        assert_eq!(response.cleaned_name, "-topic-");
        assert_eq!(response.initial_name, "main");
        assert!(response.error.is_none());

        let response = preview(GitBranchNamePreviewRequest {
            raw_name: "origin/main".into(),
            require_name: false,
            references: vec![reference(GitBranchNameReferenceKind::Remote, "origin/main")],
            reference: None,
        })
        .expect("a bounded raw name should preview");
        assert_eq!(response.initial_name, "");
        assert_eq!(
            serde_json::to_value(&response).expect("response should serialize"),
            serde_json::json!({
                "typingCleanedName": "origin/main",
                "cleanedName": "origin/main",
                "initialName": "",
                "error": {"code": "clashesWithRemote", "name": "origin/main"},
            })
        );
    }

    #[test]
    fn preview_rejects_raw_names_over_the_documented_limit() {
        let accepted = preview(GitBranchNamePreviewRequest {
            raw_name: "a".repeat(MAX_RAW_NAME_CHARS),
            require_name: false,
            references: Vec::new(),
            reference: None,
        })
        .expect("1024 characters should stay within the contract");
        assert_eq!(accepted.cleaned_name.len(), MAX_RAW_NAME_CHARS);

        let rejected = preview(GitBranchNamePreviewRequest {
            raw_name: "a".repeat(MAX_RAW_NAME_CHARS + 1),
            require_name: false,
            references: Vec::new(),
            reference: None,
        })
        .expect_err("1025 characters should be rejected");
        assert!(matches!(rejected.code, ErrorCode::InvalidRequest));
    }
}
