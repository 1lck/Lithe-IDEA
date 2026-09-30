use anyhow::{Context as _, Result};
use chrono::{TimeZone, Utc};
use git2::{Oid, Repository};
use serde::{Deserialize, Serialize};
use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use crate::{CommitInfo, RefLabel, Signature};

const SCHEMA_VERSION: u32 = 1;
static TEMP_SEQUENCE: AtomicU64 = AtomicU64::new(0);

pub(super) struct HydratedHistory {
    pub commits: Vec<CommitInfo>,
    pub has_more_commits: bool,
    pub default_branch: Option<String>,
}

#[derive(Serialize, Deserialize)]
struct CacheFile {
    schema_version: u32,
    repo_identity: String,
    ref_fingerprint: u64,
    has_more_commits: bool,
    default_branch: Option<String>,
    commits: Vec<CachedCommit>,
}

#[derive(Serialize, Deserialize)]
struct CachedCommit {
    oid: String,
    short_id: String,
    summary: String,
    message: String,
    author: CachedSignature,
    committer: CachedSignature,
    co_authors: Vec<CachedSignature>,
    timestamp: i64,
    parent_oids: Vec<String>,
    refs: Vec<CachedRef>,
    is_signed: bool,
}

#[derive(Serialize, Deserialize)]
struct CachedSignature {
    name: String,
    email: String,
}

#[derive(Serialize, Deserialize)]
enum CachedRef {
    Head,
    LocalBranch(String),
    RemoteBranch(String),
    Tag(String),
}

fn repo_identity_and_fingerprint(repo_path: &Path) -> Result<(String, u64)> {
    let repo = Repository::open(repo_path)?;
    let identity_path = repo
        .commondir()
        .canonicalize()
        .unwrap_or_else(|_| repo.commondir().to_path_buf());
    let identity = identity_path.to_string_lossy().into_owned();
    let mut refs = Vec::new();
    if let Ok(iter) = repo.references() {
        for reference in iter.flatten() {
            let name = reference.name().unwrap_or("").to_owned();
            if name.starts_with("refs/heads/")
                || name.starts_with("refs/remotes/")
                || name.starts_with("refs/tags/")
            {
                refs.push((name, reference.target().map(|oid| oid.to_string())));
            }
        }
    }
    refs.sort();
    let mut hasher = DefaultHasher::new();
    let head = repo.head().ok();
    head.as_ref()
        .and_then(|head| head.target())
        .hash(&mut hasher);
    head.as_ref().and_then(|head| head.name()).hash(&mut hasher);
    repo.head_detached().unwrap_or(false).hash(&mut hasher);
    refs.hash(&mut hasher);
    Ok((identity, hasher.finish()))
}

pub(super) fn ref_fingerprint(repo_path: &Path) -> Result<u64> {
    repo_identity_and_fingerprint(repo_path).map(|(_, fingerprint)| fingerprint)
}

fn cache_path(repo_path: &Path) -> Result<(PathBuf, String, u64)> {
    let (identity, fingerprint) = repo_identity_and_fingerprint(repo_path)?;
    let mut identity_hasher = DefaultHasher::new();
    identity.hash(&mut identity_hasher);
    let root = rgitui_settings::cache_dir().join("history");
    let path = root.join(format!(
        "v{}-{:016x}-{:016x}.json",
        SCHEMA_VERSION,
        identity_hasher.finish(),
        fingerprint
    ));
    Ok((path, identity, fingerprint))
}

pub(super) fn load(repo_path: &Path, limit: usize) -> Option<HydratedHistory> {
    let (path, identity, fingerprint) = cache_path(repo_path).ok()?;
    let bytes = std::fs::read(&path).ok()?;
    let parsed: CacheFile = match serde_json::from_slice(&bytes) {
        Ok(parsed) => parsed,
        Err(_) => {
            let _ = std::fs::remove_file(path);
            return None;
        }
    };
    hydrate(parsed, &identity, fingerprint, limit)
}

fn hydrate(
    parsed: CacheFile,
    identity: &str,
    fingerprint: u64,
    limit: usize,
) -> Option<HydratedHistory> {
    if parsed.schema_version != SCHEMA_VERSION
        || parsed.repo_identity != identity
        || parsed.ref_fingerprint != fingerprint
    {
        return None;
    }
    let mut commits: Vec<CommitInfo> = parsed
        .commits
        .into_iter()
        .map(CachedCommit::into_commit)
        .collect::<Option<Vec<_>>>()?;
    let truncated = commits.len() > limit;
    commits.truncate(limit);
    Some(HydratedHistory {
        commits,
        has_more_commits: parsed.has_more_commits || truncated,
        default_branch: parsed.default_branch,
    })
}

pub(super) fn store(
    repo_path: &Path,
    expected_fingerprint: u64,
    commits: &[CommitInfo],
    has_more_commits: bool,
    default_branch: Option<&str>,
) -> Result<()> {
    let (path, identity, fingerprint) = cache_path(repo_path)?;
    if fingerprint != expected_fingerprint {
        anyhow::bail!("Repository refs changed while history snapshot was gathered");
    }
    if path.exists() {
        return Ok(());
    }
    let cache = CacheFile {
        schema_version: SCHEMA_VERSION,
        repo_identity: identity,
        ref_fingerprint: fingerprint,
        has_more_commits,
        default_branch: default_branch.map(str::to_owned),
        commits: commits.iter().map(CachedCommit::from_commit).collect(),
    };
    let bytes = serde_json::to_vec(&cache)?;
    let parent = path.parent().context("Cache path has no parent")?;
    std::fs::create_dir_all(parent)?;
    let temp = path.with_extension(format!(
        "tmp-{}-{}",
        std::process::id(),
        TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed)
    ));
    std::fs::write(&temp, bytes)?;
    match std::fs::rename(&temp, &path) {
        Ok(()) => {
            prune_old_generations(&path);
            Ok(())
        }
        Err(_error) if path.exists() => {
            let _ = std::fs::remove_file(temp);
            Ok(())
        }
        Err(error) => {
            let _ = std::fs::remove_file(temp);
            Err(error).context("Failed to atomically publish history cache")
        }
    }
}

fn prune_old_generations(current: &Path) {
    let Some(parent) = current.parent() else {
        return;
    };
    let Some(name) = current.file_name().and_then(|name| name.to_str()) else {
        return;
    };
    let mut parts = name.split('-');
    let Some(version) = parts.next() else { return };
    let Some(identity) = parts.next() else { return };
    let prefix = format!("{version}-{identity}-");
    if let Ok(entries) = std::fs::read_dir(parent) {
        for entry in entries.flatten() {
            let path = entry.path();
            if path != current
                && path
                    .file_name()
                    .and_then(|value| value.to_str())
                    .is_some_and(|value| value.starts_with(&prefix) && value.ends_with(".json"))
            {
                let _ = std::fs::remove_file(path);
            }
        }
    }
}

impl CachedCommit {
    fn from_commit(commit: &CommitInfo) -> Self {
        Self {
            oid: commit.oid.to_string(),
            short_id: commit.short_id.clone(),
            summary: commit.summary.clone(),
            message: commit.message.clone(),
            author: CachedSignature::from_signature(&commit.author),
            committer: CachedSignature::from_signature(&commit.committer),
            co_authors: commit
                .co_authors
                .iter()
                .map(CachedSignature::from_signature)
                .collect(),
            timestamp: commit.time.timestamp(),
            parent_oids: commit.parent_oids.iter().map(ToString::to_string).collect(),
            refs: commit.refs.iter().map(CachedRef::from_ref).collect(),
            is_signed: commit.is_signed,
        }
    }

    fn into_commit(self) -> Option<CommitInfo> {
        Some(CommitInfo {
            oid: Oid::from_str(&self.oid).ok()?,
            short_id: self.short_id,
            summary: self.summary,
            message: self.message,
            author: self.author.into_signature(),
            committer: self.committer.into_signature(),
            co_authors: self
                .co_authors
                .into_iter()
                .map(CachedSignature::into_signature)
                .collect(),
            time: Utc.timestamp_opt(self.timestamp, 0).single()?,
            parent_oids: self
                .parent_oids
                .iter()
                .map(|oid| Oid::from_str(oid).ok())
                .collect::<Option<Vec<_>>>()?,
            refs: self.refs.into_iter().map(CachedRef::into_ref).collect(),
            is_signed: self.is_signed,
        })
    }
}

impl CachedSignature {
    fn from_signature(signature: &Signature) -> Self {
        Self {
            name: signature.name.clone(),
            email: signature.email.clone(),
        }
    }
    fn into_signature(self) -> Signature {
        Signature {
            name: self.name,
            email: self.email,
        }
    }
}

impl CachedRef {
    fn from_ref(label: &RefLabel) -> Self {
        match label {
            RefLabel::Head => Self::Head,
            RefLabel::LocalBranch(name) => Self::LocalBranch(name.clone()),
            RefLabel::RemoteBranch(name) => Self::RemoteBranch(name.clone()),
            RefLabel::Tag(name) => Self::Tag(name.clone()),
        }
    }
    fn into_ref(self) -> RefLabel {
        match self {
            Self::Head => RefLabel::Head,
            Self::LocalBranch(name) => RefLabel::LocalBranch(name),
            Self::RemoteBranch(name) => RefLabel::RemoteBranch(name),
            Self::Tag(name) => RefLabel::Tag(name),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use rgitui_test_support::TempRepo;
    use std::time::{Duration, Instant};

    fn commit(index: usize) -> CommitInfo {
        let oid = Oid::from_bytes(&[index as u8; 20]).unwrap();
        CommitInfo {
            oid,
            short_id: oid.to_string()[..7].to_owned(),
            summary: format!("commit {index}"),
            message: format!("commit {index}\n\nbody"),
            author: Signature {
                name: "Test".into(),
                email: "test@example.com".into(),
            },
            committer: Signature {
                name: "Test".into(),
                email: "test@example.com".into(),
            },
            co_authors: Vec::new(),
            time: Utc.timestamp_opt(index as i64, 0).single().unwrap(),
            parent_oids: Vec::new(),
            refs: if index == 0 {
                vec![RefLabel::Head]
            } else {
                Vec::new()
            },
            is_signed: false,
        }
    }

    fn encoded(count: usize, fingerprint: u64) -> Vec<u8> {
        let file = CacheFile {
            schema_version: SCHEMA_VERSION,
            repo_identity: "repo".into(),
            ref_fingerprint: fingerprint,
            has_more_commits: true,
            default_branch: Some("main".into()),
            commits: (0..count)
                .map(|index| CachedCommit::from_commit(&commit(index)))
                .collect(),
        };
        serde_json::to_vec(&file).unwrap()
    }

    #[test]
    fn cache_round_trip_hydrates_commit_metadata() {
        let parsed: CacheFile = serde_json::from_slice(&encoded(3, 7)).unwrap();
        let hydrated = hydrate(parsed, "repo", 7, 10).unwrap();
        assert_eq!(hydrated.commits.len(), 3);
        assert_eq!(hydrated.commits[0].summary, "commit 0");
        assert!(matches!(
            hydrated.commits[0].refs.as_slice(),
            [RefLabel::Head]
        ));
        assert_eq!(hydrated.default_branch.as_deref(), Some("main"));
    }

    #[test]
    fn corrupt_cache_falls_back_silently() {
        assert!(serde_json::from_slice::<CacheFile>(b"not json").is_err());
    }

    #[test]
    fn ref_fingerprint_and_schema_invalidate_cache() {
        let parsed: CacheFile = serde_json::from_slice(&encoded(1, 7)).unwrap();
        assert!(hydrate(parsed, "repo", 8, 10).is_none());
        let mut parsed: CacheFile = serde_json::from_slice(&encoded(1, 7)).unwrap();
        parsed.schema_version += 1;
        assert!(hydrate(parsed, "repo", 7, 10).is_none());
    }

    #[test]
    fn fingerprint_changes_when_head_branch_name_changes_at_same_oid() {
        let fixture = TempRepo::init();
        let oid = fixture.commit("initial");
        let repo = fixture.repo();
        repo.reference("refs/heads/other", oid, true, "test")
            .unwrap();
        let main = ref_fingerprint(fixture.path()).unwrap();
        repo.set_head("refs/heads/other").unwrap();
        let other = ref_fingerprint(fixture.path()).unwrap();
        assert_ne!(main, other);
    }

    #[test]
    fn invalid_parent_oid_rejects_entire_cache() {
        let mut parsed: CacheFile = serde_json::from_slice(&encoded(2, 7)).unwrap();
        parsed.commits[1].parent_oids.push("not-an-oid".into());
        assert!(hydrate(parsed, "repo", 7, 10).is_none());
    }

    #[test]
    fn pruning_keeps_only_current_generation_for_repo() {
        let temp = tempfile::TempDir::new().unwrap();
        let old = temp.path().join("v1-abc-111.json");
        let current = temp.path().join("v1-abc-222.json");
        let unrelated = temp.path().join("v1-def-111.json");
        std::fs::write(&old, b"old").unwrap();
        std::fs::write(&current, b"current").unwrap();
        std::fs::write(&unrelated, b"other").unwrap();
        prune_old_generations(&current);
        assert!(!old.exists());
        assert!(current.exists());
        assert!(unrelated.exists());
    }

    #[test]
    fn hydration_of_one_thousand_commits_is_fast() {
        let bytes = encoded(1_000, 7);
        let started = Instant::now();
        let parsed: CacheFile = serde_json::from_slice(&bytes).unwrap();
        let hydrated = hydrate(parsed, "repo", 7, 1_000).unwrap();
        assert_eq!(hydrated.commits.len(), 1_000);
        assert!(started.elapsed() < Duration::from_secs(2));
    }
}
