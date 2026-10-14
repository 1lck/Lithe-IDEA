//! Windows project creation: bounded Initializr downloads and exclusive publication.
//! Staging and generated files belong to the user-selected project parent, never
//! to the installation/resources directory. Spring owns versions and dependencies.
use serde::Deserialize;
use serde_json::Value;
use std::collections::HashSet;
use std::fs::{self, OpenOptions};
use std::io::{Cursor, Read, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tauri_plugin_http::reqwest;

const INITIALIZR: &str = "https://start.spring.io";
const MAX_DOWNLOAD: usize = 16 * 1024 * 1024;
const MAX_EXPANDED: u64 = 64 * 1024 * 1024;
const MAX_FILE: u64 = 8 * 1024 * 1024;
const MAX_ENTRIES: usize = 2048;
static STAGING_ID: AtomicU64 = AtomicU64::new(0);
const PUBLICATION_TIMEOUT: Duration = Duration::from_secs(2);
const PUBLICATION_RETRY_INTERVAL: Duration = Duration::from_millis(25);
const MAX_PUBLICATION_RETRIES: usize = 80;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProjectScaffoldRequest {
    parent_path: String,
    name: String,
    source: String,
    #[serde(default)]
    group_id: String,
    #[serde(default)]
    artifact_id: String,
    #[serde(default)]
    package_name: String,
    #[serde(default)]
    java_version: String,
    #[serde(default)]
    boot_version: String,
    #[serde(default)]
    build_type: String,
    #[serde(default)]
    dependencies: Vec<String>,
}

fn safe_component(value: &str) -> bool {
    let base = value.split('.').next().unwrap_or("").to_ascii_lowercase();
    !value.is_empty()
        && value.len() <= 200
        && value != "."
        && value != ".."
        && !value.ends_with(['.', ' '])
        && !value
            .chars()
            .any(|ch| ch.is_control() || "<>:\"/\\|?*".contains(ch))
        && !matches!(base.as_str(), "con" | "prn" | "aux" | "nul")
        && !(base.len() == 4
            && (base.starts_with("com") || base.starts_with("lpt"))
            && matches!(base.as_bytes()[3], b'1'..=b'9'))
}

fn safe_token(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 200
        && value
            .bytes()
            .all(|ch| ch.is_ascii_alphanumeric() || b"._-".contains(&ch))
}

fn validate_request(request: &ProjectScaffoldRequest) -> Result<(), String> {
    if !safe_component(&request.name) {
        return Err("Invalid project folder name.".into());
    }
    if !matches!(request.source.as_str(), "empty" | "java" | "spring-boot") {
        return Err("Unknown project starter.".into());
    }
    if request.source == "spring-boot" {
        if !matches!(
            request.build_type.as_str(),
            "maven-project" | "gradle-project" | "gradle-project-kotlin"
        ) || ![
            &request.group_id,
            &request.artifact_id,
            &request.package_name,
            &request.java_version,
            &request.boot_version,
        ]
        .iter()
        .all(|value| safe_token(value))
            || request.dependencies.len() > 100
            || !request.dependencies.iter().all(|value| safe_token(value))
        {
            return Err(
                "Invalid Spring Initializr options. Refresh the available versions and retry."
                    .into(),
            );
        }
    }
    Ok(())
}

async fn download(url: reqwest::Url, accept: &str, limit: usize) -> Result<Vec<u8>, String> {
    let client = reqwest::Client::builder()
        .connect_timeout(Duration::from_secs(15))
        .timeout(Duration::from_secs(90))
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .map_err(|error| error.to_string())?;
    let mut response = client
        .get(url)
        .header("Accept", accept)
        .send()
        .await
        .map_err(|error| format!("Cannot reach Spring Initializr: {error}"))?;
    if !response.status().is_success() {
        return Err(format!("Spring Initializr returned HTTP {}. Refresh versions and check the selected dependencies.", response.status()));
    }
    if response
        .content_length()
        .is_some_and(|length| length > limit as u64)
    {
        return Err("Spring Initializr response exceeded the size limit.".into());
    }
    let mut bytes = Vec::new();
    while let Some(chunk) = response.chunk().await.map_err(|error| error.to_string())? {
        if bytes.len().saturating_add(chunk.len()) > limit {
            return Err("Spring Initializr response exceeded the size limit.".into());
        }
        bytes.extend_from_slice(&chunk);
    }
    Ok(bytes)
}

#[tauri::command]
pub async fn spring_initializr_metadata() -> Result<Value, String> {
    let url = reqwest::Url::parse(INITIALIZR).map_err(|error| error.to_string())?;
    // Initializr v2.1 exposes legacy `.RELEASE` / `.BUILD-SNAPSHOT` ids.
    // Those are not the published Maven coordinates of modern Spring Boot.
    let data = download(url, "application/vnd.initializr.v2.2+json", 2 * 1024 * 1024).await?;
    serde_json::from_slice(&data)
        .map_err(|error| format!("Invalid Spring Initializr metadata: {error}"))
}

// Compare native directory identities, not ordinary versus extended-length path
// spellings. Both inputs must resolve; failure is not permission to write.
fn project_parent_outside_installation(
    parent_path: &Path,
    executable: &Path,
) -> Result<PathBuf, String> {
    if !parent_path.is_absolute() {
        return Err("Choose an existing absolute parent folder.".into());
    }
    let parent = fs::canonicalize(parent_path)
        .map_err(|error| format!("Cannot open parent folder: {error}"))?;
    if !parent.is_dir() {
        return Err("Choose an existing absolute parent folder.".into());
    }
    let executable = fs::canonicalize(executable)
        .map_err(|error| format!("Cannot resolve the Lithe installation: {error}"))?;
    let installation = executable
        .parent()
        .ok_or("Cannot resolve the Lithe installation directory.")?;
    let installation = same_file::Handle::from_path(installation)
        .map_err(|error| format!("Cannot inspect the Lithe installation: {error}"))?;
    for ancestor in parent.ancestors() {
        let identity = same_file::Handle::from_path(ancestor)
            .map_err(|error| format!("Cannot inspect the project parent: {error}"))?;
        if identity == installation {
            return Err("Create projects outside the Lithe installation directory.".into());
        }
    }
    Ok(parent)
}

#[tauri::command]
pub async fn create_project_scaffold(request: ProjectScaffoldRequest) -> Result<String, String> {
    let executable = std::env::current_exe()
        .map_err(|error| format!("Cannot locate the Lithe installation: {error}"))?;
    create_project_scaffold_for_executable(request, executable).await
}

async fn create_project_scaffold_for_executable(
    request: ProjectScaffoldRequest,
    executable: PathBuf,
) -> Result<String, String> {
    validate_request(&request)?;
    // Validate before network access, and again before creating any staging files.
    let parent = project_parent_outside_installation(Path::new(&request.parent_path), &executable)?;
    if parent.join(&request.name).exists() {
        return Err("The project destination already exists.".into());
    }
    let archive = if request.source == "spring-boot" {
        let mut url = reqwest::Url::parse(&format!("{INITIALIZR}/starter.zip"))
            .map_err(|error| error.to_string())?;
        url.query_pairs_mut()
            .append_pair("type", &request.build_type)
            .append_pair("language", "java")
            .append_pair("groupId", &request.group_id)
            .append_pair("artifactId", &request.artifact_id)
            .append_pair("name", &request.artifact_id)
            .append_pair("packageName", &request.package_name)
            .append_pair("javaVersion", &request.java_version)
            .append_pair("bootVersion", &request.boot_version)
            .append_pair("packaging", "jar")
            .append_pair("dependencies", &request.dependencies.join(","));
        Some(download(url, "application/zip", MAX_DOWNLOAD).await?)
    } else {
        None
    };
    tauri::async_runtime::spawn_blocking(move || {
        let parent = project_parent_outside_installation(&parent, &executable)?;
        publish_project(&parent, &request, archive.as_deref())
    })
    .await
    .map_err(|error| error.to_string())?
}

struct Staging(PathBuf);
impl Drop for Staging {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn publish_project(
    parent: &Path,
    request: &ProjectScaffoldRequest,
    archive: Option<&[u8]>,
) -> Result<String, String> {
    let destination = parent.join(&request.name);
    if destination.exists() {
        return Err("The project destination already exists.".into());
    }
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|error| error.to_string())?
        .as_nanos();
    let staging_path = parent.join(format!(
        ".lithe-new-{nonce}-{}",
        STAGING_ID.fetch_add(1, Ordering::Relaxed)
    ));
    fs::create_dir(&staging_path).map_err(|error| format!("Cannot create project: {error}"))?;
    let staging = Staging(staging_path);
    match request.source.as_str() {
        "spring-boot" => unpack_project(archive.ok_or("Missing Initializr archive.")?, &staging.0)?,
        "java" => {
            fs::write(staging.0.join("Main.java"), "public class Main {\n    public static void main(String[] args) {\n        System.out.println(\"Hello, World!\");\n    }\n}\n").map_err(|error| error.to_string())?;
            fs::write(staging.0.join(".gitignore"), ".lithe/\nout/\n*.class\n")
                .map_err(|error| error.to_string())?;
        }
        "empty" => {}
        _ => return Err("Unknown project starter.".into()),
    }
    // Windows rename is exclusive when the target directory already exists.
    // On failure only our staging tree is removed, never the user's target.
    if destination.exists() {
        return Err("The project destination already exists.".into());
    }
    let started = Instant::now();
    publish_with_retry(
        || fs::rename(&staging.0, &destination),
        || destination.exists(),
        || started.elapsed(),
        |duration| {
            // test-stability: allow(rust-real-sleep) reason: Windows exposes no notification for scanner handle release; this blocking worker has one 2s deadline and tests inject clock/wait.
            std::thread::sleep(duration);
        },
    )
    .map_err(|error| format!("Cannot publish project (destination may already exist): {error}"))?;
    Ok(destination.to_string_lossy().into_owned())
}

/// A scanner/watcher may briefly hold a newly extracted Windows file without
/// FILE_SHARE_DELETE. Retain the same private staging tree while waiting; never
/// copy into a partially visible destination or overwrite a racing creator.
fn publish_with_retry(
    mut rename: impl FnMut() -> std::io::Result<()>,
    mut destination_exists: impl FnMut() -> bool,
    mut elapsed: impl FnMut() -> Duration,
    mut wait: impl FnMut(Duration),
) -> std::io::Result<()> {
    let mut retries = 0;
    loop {
        if destination_exists() {
            return Err(std::io::Error::new(
                std::io::ErrorKind::AlreadyExists,
                "The project destination already exists.",
            ));
        }
        match rename() {
            Ok(()) => return Ok(()),
            Err(error) => {
                let spent = elapsed();
                let transient = cfg!(windows) && matches!(error.raw_os_error(), Some(5 | 32 | 33));
                if !transient || spent >= PUBLICATION_TIMEOUT || retries >= MAX_PUBLICATION_RETRIES
                {
                    return Err(error);
                }
                retries += 1;
                wait(PUBLICATION_RETRY_INTERVAL.min(PUBLICATION_TIMEOUT - spent));
            }
        }
    }
}

fn unpack_project(bytes: &[u8], destination: &Path) -> Result<(), String> {
    let mut archive = zip::ZipArchive::new(Cursor::new(bytes))
        .map_err(|error| format!("Invalid Initializr ZIP: {error}"))?;
    if archive.len() > MAX_ENTRIES {
        return Err("Initializr ZIP contains too many entries.".into());
    }
    let mut seen = HashSet::new();
    let mut expanded = 0u64;
    for index in 0..archive.len() {
        let mut entry = archive.by_index(index).map_err(|error| error.to_string())?;
        let name = entry.name().trim_end_matches('/');
        if name.is_empty()
            || !name.split('/').all(safe_component)
            || !seen.insert(name.to_ascii_lowercase())
            || entry
                .unix_mode()
                .is_some_and(|mode| mode & 0o170000 == 0o120000)
        {
            return Err("Initializr ZIP contains an unsafe or duplicate path.".into());
        }
        let output = destination.join(name);
        if entry.is_dir() {
            fs::create_dir_all(&output).map_err(|error| error.to_string())?;
            continue;
        }
        if entry.size() > MAX_FILE || expanded.saturating_add(entry.size()) > MAX_EXPANDED {
            return Err("Initializr ZIP exceeds the extraction limit.".into());
        }
        let mut content = Vec::new();
        (&mut entry)
            .take(MAX_FILE + 1)
            .read_to_end(&mut content)
            .map_err(|error| error.to_string())?;
        expanded += content.len() as u64;
        if content.len() as u64 > MAX_FILE || expanded > MAX_EXPANDED {
            return Err("Initializr ZIP exceeds the extraction limit.".into());
        }
        if let Some(parent) = output.parent() {
            fs::create_dir_all(parent).map_err(|error| error.to_string())?;
        }
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&output)
            .map_err(|error| error.to_string())?;
        file.write_all(&content)
            .map_err(|error| error.to_string())?;
    }
    if !destination.join("pom.xml").is_file()
        && !destination.join("build.gradle").is_file()
        && !destination.join("build.gradle.kts").is_file()
    {
        return Err("Initializr ZIP does not contain a supported build file.".into());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use zip::write::SimpleFileOptions;

    #[test]
    #[cfg(windows)]
    fn publication_retries_transient_windows_locks_on_the_same_staging_tree() {
        use std::cell::Cell;
        let attempts = Cell::new(0);
        let elapsed = Cell::new(Duration::ZERO);
        publish_with_retry(
            || {
                attempts.set(attempts.get() + 1);
                if attempts.get() < 3 {
                    Err(std::io::Error::from_raw_os_error(5))
                } else {
                    Ok(())
                }
            },
            || false,
            || elapsed.get(),
            |duration| elapsed.set(elapsed.get() + duration),
        )
        .unwrap();
        assert_eq!(attempts.get(), 3);
        assert_eq!(elapsed.get(), PUBLICATION_RETRY_INTERVAL * 2);
    }

    #[test]
    #[cfg(windows)]
    fn publication_stops_at_one_deadline_without_recreating_or_deleting_the_target() {
        use std::cell::Cell;
        let attempts = Cell::new(0);
        let elapsed = Cell::new(Duration::ZERO);
        let result = publish_with_retry(
            || {
                attempts.set(attempts.get() + 1);
                Err(std::io::Error::from_raw_os_error(32))
            },
            || false,
            || elapsed.get(),
            |duration| elapsed.set(elapsed.get() + duration),
        );
        assert_eq!(result.unwrap_err().raw_os_error(), Some(32));
        assert_eq!(elapsed.get(), PUBLICATION_TIMEOUT);
        assert!(attempts.get() <= MAX_PUBLICATION_RETRIES + 1);
    }

    #[test]
    #[cfg(windows)]
    fn publication_rechecks_for_a_destination_created_during_the_wait() {
        use std::cell::Cell;
        let destination_exists = Cell::new(false);
        let attempts = Cell::new(0);
        let result = publish_with_retry(
            || {
                attempts.set(attempts.get() + 1);
                Err(std::io::Error::from_raw_os_error(5))
            },
            || destination_exists.get(),
            || Duration::ZERO,
            |_| destination_exists.set(true),
        );
        assert_eq!(
            result.unwrap_err().kind(),
            std::io::ErrorKind::AlreadyExists
        );
        assert_eq!(attempts.get(), 1);
    }

    #[test]
    fn publication_does_not_retry_unrelated_errors() {
        let result = publish_with_retry(
            || {
                Err(std::io::Error::new(
                    std::io::ErrorKind::NotFound,
                    "missing staging",
                ))
            },
            || false,
            || Duration::ZERO,
            |_| panic!("non-transient errors must not wait"),
        );
        assert_eq!(result.unwrap_err().kind(), std::io::ErrorKind::NotFound);
    }

    fn fixture() -> Staging {
        let path = std::env::temp_dir().join(format!(
            "lithe-scaffold-test-{}-{}",
            std::process::id(),
            STAGING_ID.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&path).expect("isolated fixture");
        Staging(path)
    }
    fn request(source: &str) -> ProjectScaffoldRequest {
        ProjectScaffoldRequest {
            parent_path: String::new(),
            name: "sample".into(),
            source: source.into(),
            group_id: "com.example".into(),
            artifact_id: "demo".into(),
            package_name: "com.example.demo".into(),
            java_version: "17".into(),
            boot_version: "test-release".into(),
            build_type: "maven-project".into(),
            dependencies: vec!["web".into()],
        }
    }
    fn archive(files: &[(&str, &str)]) -> Vec<u8> {
        let mut writer = zip::ZipWriter::new(Cursor::new(Vec::new()));
        for (name, text) in files {
            writer
                .start_file(*name, SimpleFileOptions::default())
                .expect("ZIP entry");
            writer.write_all(text.as_bytes()).expect("ZIP content");
        }
        writer.finish().expect("ZIP finish").into_inner()
    }
    fn fake_installation(fixture: &Staging) -> PathBuf {
        let installation = fixture.0.join("Lithe");
        fs::create_dir_all(installation.join("resources")).unwrap();
        let executable = installation.join("Lithe.exe");
        fs::write(&executable, "installation sentinel").unwrap();
        executable
    }

    #[test]
    fn installation_and_descendants_are_rejected_before_scaffold_writes() {
        let fixture = fixture();
        let executable = fake_installation(&fixture);
        for parent in [
            executable.parent().unwrap().to_path_buf(),
            executable.parent().unwrap().join("resources"),
        ] {
            let mut options = request("java");
            options.parent_path = parent.to_string_lossy().into_owned();
            let error = tauri::async_runtime::block_on(create_project_scaffold_for_executable(
                options,
                executable.clone(),
            ))
            .unwrap_err();
            assert!(error.contains("outside the Lithe installation"), "{error}");
            assert!(!parent.join("sample").exists());
            assert!(!fs::read_dir(&parent).unwrap().any(|entry| entry
                .unwrap()
                .file_name()
                .to_string_lossy()
                .starts_with(".lithe")));
        }
        assert_eq!(
            fs::read_to_string(executable).unwrap(),
            "installation sentinel"
        );
    }

    #[test]
    fn similar_prefix_siblings_are_allowed_and_unresolved_installations_fail_closed() {
        let fixture = fixture();
        let executable = fake_installation(&fixture);
        let sibling = fixture.0.join("Lithe-projects");
        fs::create_dir(&sibling).unwrap();
        assert_eq!(
            project_parent_outside_installation(&sibling, &executable).unwrap(),
            fs::canonicalize(&sibling).unwrap()
        );
        assert!(
            project_parent_outside_installation(&sibling, &fixture.0.join("missing.exe")).is_err()
        );
        assert!(project_parent_outside_installation(Path::new("relative"), &executable).is_err());
        assert_eq!(fs::read_dir(&sibling).unwrap().count(), 0);
    }

    #[cfg(windows)]
    #[test]
    fn windows_regular_verbatim_and_case_spellings_share_installation_identity() {
        let fixture = fixture();
        let executable = fake_installation(&fixture);
        let canonical = fs::canonicalize(&executable).unwrap();
        let regular = canonical
            .to_string_lossy()
            .strip_prefix(r"\\?\")
            .unwrap()
            .to_owned();
        for spelling in [
            &regular,
            &regular.to_uppercase(),
            &canonical.to_string_lossy().into_owned(),
        ] {
            let installation = Path::new(spelling).parent().unwrap();
            let parent = installation.join("resources");
            let error = project_parent_outside_installation(&parent, &executable).unwrap_err();
            assert!(error.contains("outside the Lithe installation"), "{error}");
            let error = project_parent_outside_installation(
                executable.parent().unwrap(),
                Path::new(spelling),
            )
            .unwrap_err();
            assert!(error.contains("outside the Lithe installation"), "{error}");
        }
    }

    #[cfg(windows)]
    #[test]
    #[ignore = "requires Windows directory symlink privilege or Developer Mode"]
    fn windows_linked_parent_and_installation_resolve_to_the_same_identity() {
        let fixture = fixture();
        let executable = fake_installation(&fixture);
        let alias = fixture.0.join("installation-alias");
        std::os::windows::fs::symlink_dir(executable.parent().unwrap(), &alias)
            .expect("directory link privilege");
        let result = project_parent_outside_installation(&alias.join("resources"), &executable);
        let reverse = project_parent_outside_installation(
            executable.parent().unwrap(),
            &alias.join("Lithe.exe"),
        );
        // Remove the link explicitly before the fixture's recursive cleanup.
        fs::remove_dir(&alias).unwrap();
        assert!(result
            .unwrap_err()
            .contains("outside the Lithe installation"));
        assert!(reverse
            .unwrap_err()
            .contains("outside the Lithe installation"));
    }

    #[test]
    fn names_cannot_escape_or_use_windows_devices() {
        for name in [
            "../outside",
            "CON",
            "aux.txt",
            "a/b",
            "a\\b",
            "demo.",
            "C:escape",
            "a\n",
        ] {
            assert!(!safe_component(name), "{name}");
        }
        for name in ["sample", "我的项目", "demo-app", ".mvn"] {
            assert!(safe_component(name), "{name}");
        }
    }
    #[test]
    fn unknown_starters_and_shell_like_options_are_rejected() {
        assert!(validate_request(&request("unknown")).is_err());
        let mut options = request("spring-boot");
        options.dependencies.push("web; rm -rf".into());
        assert!(validate_request(&options).is_err());
    }
    #[test]
    fn empty_and_java_projects_are_published_without_overwriting() {
        let fixture = fixture();
        let options = request("java");
        let path = PathBuf::from(publish_project(&fixture.0, &options, None).expect("project"));
        assert!(fs::read_to_string(path.join("Main.java"))
            .unwrap()
            .contains("public static void main"));
        fs::write(path.join("keep.txt"), "user data").unwrap();
        assert!(publish_project(&fixture.0, &options, None).is_err());
        assert_eq!(
            fs::read_to_string(path.join("keep.txt")).unwrap(),
            "user data"
        );
        let mut empty = request("empty");
        empty.name = "empty".into();
        let path = PathBuf::from(publish_project(&fixture.0, &empty, None).unwrap());
        assert_eq!(fs::read_dir(path).unwrap().count(), 0);
    }
    #[test]
    fn initializr_preserves_wrapper_and_sources() {
        let fixture = fixture();
        let zip = archive(&[
            ("pom.xml", "<project/>"),
            ("mvnw.cmd", "@echo off"),
            (
                ".mvn/wrapper/maven-wrapper.properties",
                "distributionUrl=test",
            ),
            ("src/main/java/demo/App.java", "package demo; class App {}"),
        ]);
        let path = PathBuf::from(
            publish_project(&fixture.0, &request("spring-boot"), Some(&zip)).unwrap(),
        );
        assert!(path.join("mvnw.cmd").is_file());
        assert!(path.join("src/main/java/demo/App.java").is_file());
        assert!(path.join(".mvn/wrapper/maven-wrapper.properties").is_file());
    }
    #[test]
    fn traversal_and_case_collisions_never_publish_partial_projects() {
        for files in [
            vec![("pom.xml", "ok"), ("../escape", "bad")],
            vec![("pom.xml", "one"), ("POM.XML", "two")],
            vec![("C:/escape", "bad")],
            vec![("src\\escape", "bad")],
        ] {
            let fixture = fixture();
            assert!(
                publish_project(&fixture.0, &request("spring-boot"), Some(&archive(&files)))
                    .is_err()
            );
            assert_eq!(fs::read_dir(&fixture.0).unwrap().count(), 0);
        }
    }
    #[test]
    fn invalid_archive_or_missing_build_file_cleans_only_owned_staging() {
        let fixture = fixture();
        fs::write(fixture.0.join("keep.txt"), "keep").unwrap();
        for data in [
            b"not a zip".to_vec(),
            archive(&[("readme.txt", "no build")]),
        ] {
            assert!(publish_project(&fixture.0, &request("spring-boot"), Some(&data)).is_err());
            assert_eq!(fs::read_dir(&fixture.0).unwrap().count(), 1);
        }
        assert_eq!(
            fs::read_to_string(fixture.0.join("keep.txt")).unwrap(),
            "keep"
        );
    }
    #[test]
    fn oversized_archive_entry_is_rejected_before_publication() {
        let fixture = fixture();
        let content = "a".repeat(MAX_FILE as usize + 1);
        let data = archive(&[("pom.xml", &content)]);
        assert!(publish_project(&fixture.0, &request("spring-boot"), Some(&data)).is_err());
        assert_eq!(fs::read_dir(&fixture.0).unwrap().count(), 0);
    }
    /// Explicit integration probe: official network service, never part of unit runs.
    #[test]
    #[ignore = "requires access to the official Spring Initializr service"]
    fn real_initializr_generates_a_complete_project() {
        let fixture = fixture();
        tauri::async_runtime::block_on(async {
            let metadata = spring_initializr_metadata()
                .await
                .expect("Initializr metadata");
            let mut options = request("spring-boot");
            options.parent_path = fixture.0.to_string_lossy().into_owned();
            options.boot_version = metadata["bootVersion"]["default"]
                .as_str()
                .expect("Boot default")
                .into();
            options.java_version = metadata["javaVersion"]["default"]
                .as_str()
                .expect("Java default")
                .into();
            options.dependencies.clear();
            let boot_version = options.boot_version.clone();
            let mut parent_url =
                reqwest::Url::parse("https://repo.maven.apache.org/maven2/").unwrap();
            parent_url
                .path_segments_mut()
                .unwrap()
                .pop_if_empty()
                .extend([
                    "org",
                    "springframework",
                    "boot",
                    "spring-boot-starter-parent",
                    &boot_version,
                    &format!("spring-boot-starter-parent-{boot_version}.pom"),
                ]);
            // A ZIP containing files is not sufficient: the legacy metadata
            // media type produced a parent version that Central cannot resolve.
            let parent_url_text = parent_url.to_string();
            download(parent_url, "application/xml", 512 * 1024)
                .await
                .unwrap_or_else(|error| {
                    panic!("Published Spring Boot parent {parent_url_text}: {error}")
                });
            let path = PathBuf::from(
                create_project_scaffold(options)
                    .await
                    .expect("Initializr project"),
            );
            assert!(path.join("pom.xml").is_file());
            let pom = fs::read_to_string(path.join("pom.xml")).unwrap();
            assert!(pom.contains(&format!("<version>{boot_version}</version>")));
            assert!(path.join("mvnw.cmd").is_file());
            assert!(path
                .join("src/main/java/com/example/demo/DemoApplication.java")
                .is_file());
        });
    }
}
