use crate::error::{CoreError, ErrorCode};
use serde::{Deserialize, Serialize};
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

const SHELF_VERSION: u32 = 1;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ShelfCreateRequest {
    pub workspace_root: String,
    pub storage_root: String,
    #[serde(default)]
    pub label: String,
    #[serde(default)]
    pub staged_patch: String,
    #[serde(default)]
    pub working_tree_patch: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ShelfListRequest {
    pub workspace_root: String,
    pub storage_root: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ShelfRestoreRequest {
    pub workspace_root: String,
    pub storage_root: String,
    pub id: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ShelfDeleteRequest {
    pub workspace_root: String,
    pub storage_root: String,
    pub id: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ShelfSummary {
    pub id: String,
    pub workspace_root: String,
    pub label: String,
    pub created_at: i64,
    pub staged_byte_count: usize,
    pub working_tree_byte_count: usize,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ShelfListResponse {
    pub shelves: Vec<ShelfSummary>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ShelfRestoreResponse {
    pub id: String,
    pub staged_patch: String,
    pub working_tree_patch: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ShelfDeleteResponse {
    pub deleted: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct StoredShelf {
    version: u32,
    id: String,
    workspace_root: String,
    label: String,
    created_at: i64,
    staged_byte_count: usize,
    working_tree_byte_count: usize,
}

pub fn create(request: ShelfCreateRequest) -> Result<ShelfSummary, CoreError> {
    let workspace = existing_root(&request.workspace_root)?;
    let workspace_root = path_text(&workspace);
    let storage = storage_root(&request.storage_root)?;
    let directory = shelf_root(&storage, &workspace_root);
    ensure_directory_tree(&directory)?;
    let created_at = unix_milliseconds();
    let id = format!("shelf-{}-{}", created_at, monotonic_nonce());
    let shelf_directory = directory.join(&id);
    create_directory(&shelf_directory)?;
    let stored = StoredShelf {
        version: SHELF_VERSION,
        id: id.clone(),
        workspace_root: workspace_root.clone(),
        label: request.label,
        created_at,
        staged_byte_count: request.staged_patch.len(),
        working_tree_byte_count: request.working_tree_patch.len(),
    };
    let result = (|| {
        let metadata = serde_json::to_vec(&stored)
            .map_err(|error| std::io::Error::other(error.to_string()))?;
        write_new_file(&shelf_directory.join("metadata.json"), &metadata)?;
        write_new_file(
            &shelf_directory.join("staged.patch"),
            request.staged_patch.as_bytes(),
        )?;
        write_new_file(
            &shelf_directory.join("working-tree.patch"),
            request.working_tree_patch.as_bytes(),
        )?;
        Ok::<(), std::io::Error>(())
    })();
    if let Err(error) = result {
        let _ = fs::remove_dir_all(&shelf_directory);
        return Err(CoreError::from(error));
    }
    Ok(stored.into_summary())
}

pub fn list(request: ShelfListRequest) -> Result<ShelfListResponse, CoreError> {
    let workspace = existing_root(&request.workspace_root)?;
    let workspace_root = path_text(&workspace);
    let storage = storage_root(&request.storage_root)?;
    let directory = shelf_root(&storage, &workspace_root);
    if !ensure_existing_directory_tree(&storage, &directory)? {
        return Ok(ShelfListResponse {
            shelves: Vec::new(),
        });
    }
    let mut shelves = fs::read_dir(directory)
        .ok()
        .into_iter()
        .flatten()
        .filter_map(Result::ok)
        .filter(|entry| {
            entry
                .file_type()
                .map(|value| value.is_dir())
                .unwrap_or(false)
        })
        .filter_map(|entry| read_shelf(&entry.path(), &workspace_root).ok())
        .filter(|shelf| shelf.version == SHELF_VERSION)
        .map(StoredShelf::into_summary)
        .collect::<Vec<_>>();
    shelves.sort_by(|left, right| {
        right
            .created_at
            .cmp(&left.created_at)
            .then_with(|| right.id.cmp(&left.id))
    });
    Ok(ShelfListResponse { shelves })
}

pub fn restore(request: ShelfRestoreRequest) -> Result<ShelfRestoreResponse, CoreError> {
    validate_id(&request.id)?;
    let workspace = existing_root(&request.workspace_root)?;
    let workspace_root = path_text(&workspace);
    let storage = storage_root(&request.storage_root)?;
    let shelf_directory = shelf_root(&storage, &workspace_root);
    ensure_existing_directory_tree(&storage, &shelf_directory)?;
    let shelf = read_shelf(&shelf_directory.join(&request.id), &workspace_root)?;
    let directory = shelf_directory.join(&shelf.id);
    let staged_patch = fs::read_to_string(directory.join("staged.patch"))?;
    let working_tree_patch = fs::read_to_string(directory.join("working-tree.patch"))?;
    Ok(ShelfRestoreResponse {
        id: shelf.id,
        staged_patch,
        working_tree_patch,
    })
}

pub fn delete(request: ShelfDeleteRequest) -> Result<ShelfDeleteResponse, CoreError> {
    validate_id(&request.id)?;
    let workspace = existing_root(&request.workspace_root)?;
    let workspace_root = path_text(&workspace);
    let storage = storage_root(&request.storage_root)?;
    let shelf_directory = shelf_root(&storage, &workspace_root);
    ensure_existing_directory_tree(&storage, &shelf_directory)?;
    let directory = shelf_directory.join(&request.id);
    let shelf = read_shelf(&directory, &workspace_root)?;
    fs::remove_dir_all(shelf_directory.join(shelf.id))?;
    Ok(ShelfDeleteResponse { deleted: true })
}

impl StoredShelf {
    fn into_summary(self) -> ShelfSummary {
        ShelfSummary {
            id: self.id,
            workspace_root: self.workspace_root,
            label: self.label,
            created_at: self.created_at,
            staged_byte_count: self.staged_byte_count,
            working_tree_byte_count: self.working_tree_byte_count,
        }
    }
}

fn read_shelf(directory: &Path, expected_root: &str) -> Result<StoredShelf, CoreError> {
    ensure_directory(directory)?;
    ensure_regular_file(&directory.join("metadata.json"))?;
    ensure_regular_file(&directory.join("staged.patch"))?;
    ensure_regular_file(&directory.join("working-tree.patch"))?;
    let metadata = fs::read(directory.join("metadata.json"))?;
    let shelf: StoredShelf = serde_json::from_slice(&metadata)
        .map_err(|_| CoreError::new(ErrorCode::ParseFailed, "Invalid Shelf metadata"))?;
    if shelf.version != SHELF_VERSION
        || shelf.workspace_root != expected_root
        || !valid_id(&shelf.id)
        || shelf.id
            != directory
                .file_name()
                .and_then(|value| value.to_str())
                .unwrap_or_default()
    {
        return Err(CoreError::new(
            ErrorCode::PermissionDenied,
            "Shelf metadata does not match workspace",
        ));
    }
    Ok(shelf)
}

fn existing_root(value: &str) -> Result<PathBuf, CoreError> {
    let path = PathBuf::from(value);
    let metadata = fs::metadata(&path)
        .map_err(|_| CoreError::new(ErrorCode::WorkspaceNotFound, "Workspace does not exist"))?;
    if !metadata.is_dir() {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Workspace root must be a directory",
        ));
    }
    path.canonicalize().map_err(CoreError::from)
}

fn storage_root(value: &str) -> Result<PathBuf, CoreError> {
    let path = PathBuf::from(value);
    reject_symlink_components(&path)?;
    fs::create_dir_all(&path).map_err(CoreError::from)?;
    reject_symlink_components(&path)?;
    let canonical = path.canonicalize().map_err(CoreError::from)?;
    ensure_directory(&canonical)?;
    Ok(canonical)
}

fn existing_metadata(path: &Path) -> Result<Option<fs::Metadata>, CoreError> {
    match fs::symlink_metadata(path) {
        Ok(metadata) => Ok(Some(metadata)),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(CoreError::from(error)),
    }
}

fn reject_symlink_components(path: &Path) -> Result<(), CoreError> {
    let mut current = PathBuf::new();
    for component in path.components() {
        current.push(component.as_os_str());
        if let Some(metadata) = existing_metadata(&current)? {
            if metadata.file_type().is_symlink() {
                return Err(CoreError::new(
                    ErrorCode::PermissionDenied,
                    "Shelf path contains a symbolic link",
                ));
            }
        }
    }
    Ok(())
}

fn ensure_directory(path: &Path) -> Result<(), CoreError> {
    let metadata = fs::symlink_metadata(path).map_err(CoreError::from)?;
    if metadata.file_type().is_symlink() || !metadata.is_dir() {
        return Err(CoreError::new(
            ErrorCode::PermissionDenied,
            "Shelf path is not a directory",
        ));
    }
    Ok(())
}

fn create_directory(path: &Path) -> Result<(), CoreError> {
    match existing_metadata(path)? {
        Some(_) => ensure_directory(path),
        None => fs::create_dir(path).map_err(CoreError::from),
    }
}

fn ensure_directory_tree(path: &Path) -> Result<(), CoreError> {
    if let Some(parent) = path.parent() {
        if parent != path {
            ensure_directory_tree(parent)?;
        }
    }
    create_directory(path)
}

fn ensure_existing_directory_tree(root: &Path, target: &Path) -> Result<bool, CoreError> {
    ensure_directory(root)?;
    let relative = target.strip_prefix(root).map_err(|_| {
        CoreError::new(
            ErrorCode::PermissionDenied,
            "Shelf path escaped storage root",
        )
    })?;
    let mut current = root.to_path_buf();
    for component in relative.components() {
        current.push(component.as_os_str());
        let Some(_) = existing_metadata(&current)? else {
            return Ok(false);
        };
        ensure_directory(&current)?;
    }
    Ok(true)
}

fn ensure_regular_file(path: &Path) -> Result<(), CoreError> {
    let metadata = fs::symlink_metadata(path).map_err(CoreError::from)?;
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return Err(CoreError::new(
            ErrorCode::PermissionDenied,
            "Shelf file is not regular",
        ));
    }
    Ok(())
}

fn write_new_file(path: &Path, contents: &[u8]) -> Result<(), std::io::Error> {
    let mut file = OpenOptions::new().write(true).create_new(true).open(path)?;
    file.write_all(contents)
}

fn shelf_root(storage: &Path, workspace_root: &str) -> PathBuf {
    storage
        .join("shelves")
        .join("v1")
        .join(stable_identifier(workspace_root))
}

fn valid_id(value: &str) -> bool {
    !value.is_empty()
        && value.chars().all(|character| {
            character.is_ascii_alphanumeric() || character == '-' || character == '_'
        })
}

fn validate_id(value: &str) -> Result<(), CoreError> {
    if valid_id(value) {
        Ok(())
    } else {
        Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Invalid Shelf id",
        ))
    }
}

fn stable_identifier(value: &str) -> String {
    let mut hash: u64 = 14_695_981_039_346_656_037;
    for byte in value.as_bytes() {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(1_099_511_628_211);
    }
    format!("{:016x}", hash)
}

fn path_text(path: &Path) -> String {
    path.to_string_lossy().replace('\\', "/")
}

fn unix_milliseconds() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|value| value.as_millis() as i64)
        .unwrap_or_default()
}

fn monotonic_nonce() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|value| value.as_nanos())
        .unwrap_or_default()
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};

    #[cfg(unix)]
    fn temporary_root(label: &str) -> PathBuf {
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        let nonce = COUNTER.fetch_add(1, Ordering::Relaxed);
        std::env::temp_dir().join(format!(
            "lithe-shelf-test-{label}-{}-{nonce}",
            std::process::id()
        ))
    }

    #[cfg(unix)]
    fn workspace_path(root: &Path) -> String {
        fs::create_dir_all(root.join("workspace")).expect("workspace should be creatable");
        root.join("workspace").to_string_lossy().into_owned()
    }

    #[cfg(unix)]
    fn storage_path(root: &Path) -> String {
        root.join("storage").to_string_lossy().into_owned()
    }

    #[cfg(unix)]
    fn create_ok(workspace: &str, storage: &str) -> String {
        create(ShelfCreateRequest {
            workspace_root: workspace.to_string(),
            storage_root: storage.to_string(),
            label: "test".into(),
            staged_patch: "staged".into(),
            working_tree_patch: "working".into(),
        })
        .expect("Shelf create should succeed")
        .id
    }

    #[cfg(unix)]
    fn shelf_directory(workspace: &str, storage: &str) -> PathBuf {
        let workspace = existing_root(workspace).expect("workspace should resolve");
        let storage = storage_root(storage).expect("storage should resolve");
        shelf_root(&storage, &path_text(&workspace))
    }

    #[cfg(unix)]
    fn assert_permission_denied(result: Result<(), CoreError>) {
        let error = result.expect_err("Shelf path with a symbolic link should be rejected");
        assert_eq!(
            serde_json::to_string(&error.code).expect("error code should serialize"),
            "\"permission_denied\""
        );
    }

    #[cfg(unix)]
    #[test]
    fn create_rejects_symlinked_storage_root() {
        let root = temporary_root("storage-link");
        fs::create_dir_all(root.join("real-storage")).expect("real storage should be creatable");
        std::os::unix::fs::symlink(root.join("real-storage"), root.join("storage"))
            .expect("test symlink should be creatable");
        let workspace = workspace_path(&root);
        assert_permission_denied(create(ShelfCreateRequest {
            workspace_root: workspace,
            storage_root: storage_path(&root),
            label: String::new(),
            staged_patch: "s".into(),
            working_tree_patch: "w".into(),
        }));
        fs::remove_dir_all(&root).expect("temporary fixture should be removable");
    }

    #[cfg(unix)]
    #[test]
    fn create_rejects_symlinked_intermediate_directory() {
        let root = temporary_root("intermediate-link");
        let workspace = workspace_path(&root);
        let storage = storage_path(&root);
        fs::create_dir_all(root.join("storage")).expect("storage should be creatable");
        std::os::unix::fs::symlink(root.join("workspace"), root.join("storage").join("shelves"))
            .expect("test symlink should be creatable");
        assert_permission_denied(create(ShelfCreateRequest {
            workspace_root: workspace,
            storage_root: storage,
            label: String::new(),
            staged_patch: "s".into(),
            working_tree_patch: "w".into(),
        }));
        fs::remove_dir_all(&root).expect("temporary fixture should be removable");
    }

    #[cfg(unix)]
    #[test]
    fn restore_and_delete_reject_symlinked_shelf_directory() {
        let root = temporary_root("shelf-dir-link");
        let workspace = workspace_path(&root);
        let storage = storage_path(&root);
        let id = create_ok(&workspace, &storage);
        let directory = shelf_directory(&workspace, &storage).join(&id);
        fs::remove_dir_all(&directory).expect("shelf directory should be removable");
        fs::create_dir_all(root.join("outside")).expect("outside directory should be creatable");
        std::os::unix::fs::symlink(root.join("outside"), &directory)
            .expect("test symlink should be creatable");

        assert_permission_denied(restore(ShelfRestoreRequest {
            workspace_root: workspace.clone(),
            storage_root: storage.clone(),
            id: id.clone(),
        }));
        assert_permission_denied(delete(ShelfDeleteRequest {
            workspace_root: workspace,
            storage_root: storage,
            id,
        }));
        assert!(root.join("outside").is_dir());
        fs::remove_dir_all(&root).expect("temporary fixture should be removable");
    }

    #[cfg(unix)]
    #[test]
    fn restore_rejects_symlinked_patch_file_and_list_skips_shelf() {
        let root = temporary_root("patch-link");
        let workspace = workspace_path(&root);
        let storage = storage_path(&root);
        let id = create_ok(&workspace, &storage);
        let directory = shelf_directory(&workspace, &storage).join(&id);
        fs::remove_file(directory.join("staged.patch")).expect("patch should be removable");
        fs::write(root.join("outside.txt"), "evil").expect("outside file should be writable");
        std::os::unix::fs::symlink(root.join("outside.txt"), directory.join("staged.patch"))
            .expect("test symlink should be creatable");

        assert_permission_denied(restore(ShelfRestoreRequest {
            workspace_root: workspace.clone(),
            storage_root: storage.clone(),
            id: id.clone(),
        }));
        let listed = list(ShelfListRequest {
            workspace_root: workspace,
            storage_root: storage,
        })
        .expect("Shelf list should succeed");
        assert!(listed.shelves.is_empty());
        fs::remove_dir_all(&root).expect("temporary fixture should be removable");
    }
}
