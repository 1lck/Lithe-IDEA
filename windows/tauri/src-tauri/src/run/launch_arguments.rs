//! Native encoding and execution-owned temporary files for Java launch arguments.
//!
//! JDK 9+ launches use a Core-planned `@argfile`; JDK 8 launches use a
//! Core-planned manifest-only class-path JAR. Both files are created under the
//! system temporary directory and owned by [`LaunchArgumentFile`].

use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};

/// Owns exactly one execution's file, including cleanup after partial writes.
pub(super) struct LaunchArgumentFile(PathBuf);

impl Drop for LaunchArgumentFile {
    fn drop(&mut self) {
        if let Err(error) = fs::remove_file(&self.0) {
            if error.kind() != std::io::ErrorKind::NotFound {
                eprintln!("Could not remove Java launch argument file: {error}");
            }
        }
    }
}

pub(super) fn prepare(
    executable: &str,
    arguments: &[String],
    working_directory: &str,
) -> Result<(Vec<String>, Option<LaunchArgumentFile>), String> {
    let version = java_feature_version(executable);
    // JDK 8 has no `@argfile`; Core plans a manifest-only class-path JAR for
    // it instead. Both planners check executable identity, and an unknown
    // version keeps the original command.
    if version.is_some_and(|version| version < 9) {
        return prepare_classpath_jar(executable, arguments, working_directory, version);
    }
    for _ in 0..128 {
        let path = next_temporary_path("argfile");
        let lithe_core::execution::LaunchCommandPlan::Argfile {
            arguments: shortened,
            argfile_contents,
        } = lithe_core::execution::plan_launch_command(executable, arguments, &path, None, version)
        else {
            return Ok((arguments.to_vec(), None));
        };
        let bytes = encode_argfile(&argfile_contents)?;
        fs::create_dir_all(path.parent().expect("temporary file has a parent"))
            .map_err(|error| format!("Could not create Java launch argument directory: {error}"))?;
        let mut file = match OpenOptions::new().write(true).create_new(true).open(&path) {
            Ok(file) => file,
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(error) => {
                return Err(format!(
                    "Could not create Java launch argument file: {error}"
                ))
            }
        };
        let owner = LaunchArgumentFile(path);
        let written = file.write_all(&bytes);
        // Close before the owner removes the file, including after a write failure.
        drop(file);
        written.map_err(|error| format!("Could not write Java launch argument file: {error}"))?;
        return Ok((shortened, Some(owner)));
    }
    Err("Could not allocate a unique Java launch argument file. Retry the launch.".into())
}

/// Writes the JDK 8 class-path JAR planned by Core.
///
/// The JAR lives in the same per-execution temporary directory as argument
/// files, never next to the JDK or the installation, and the returned owner
/// deletes it on write failure, spawn failure, or process exit.
fn prepare_classpath_jar(
    executable: &str,
    arguments: &[String],
    working_directory: &str,
    version: Option<u32>,
) -> Result<(Vec<String>, Option<LaunchArgumentFile>), String> {
    use lithe_core::execution::{
        plan_classpath_jar_launch, ClasspathJarPlan, ClasspathJarRequest, ClasspathStyle,
    };
    let style = if cfg!(windows) {
        ClasspathStyle::Windows
    } else {
        ClasspathStyle::Posix
    };
    for _ in 0..128 {
        let path = next_temporary_path("classpath.jar");
        let ClasspathJarPlan::ClasspathJar {
            arguments: shortened,
            manifest,
        } = plan_classpath_jar_launch(
            ClasspathJarRequest {
                executable,
                arguments,
                working_directory,
                classpath_jar_path: &path,
                limit: None,
                java_feature_version: version,
                style,
            },
            |entry| std::path::Path::new(entry).is_dir(),
        )
        else {
            return Ok((arguments.to_vec(), None));
        };
        fs::create_dir_all(path.parent().expect("temporary file has a parent"))
            .map_err(|error| format!("Could not create Java class-path JAR directory: {error}"))?;
        let file = match OpenOptions::new().write(true).create_new(true).open(&path) {
            Ok(file) => file,
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(format!("Could not create Java class-path JAR: {error}")),
        };
        let owner = LaunchArgumentFile(path);
        write_manifest_jar(file, &manifest)
            .map_err(|error| format!("Could not write Java class-path JAR: {error}"))?;
        return Ok((shortened, Some(owner)));
    }
    Err("Could not allocate a unique Java class-path JAR. Retry the launch.".into())
}

/// Writes a JAR whose only entry is `META-INF/MANIFEST.MF`.
///
/// The manifest is stored uncompressed: it is small, and stored entries keep
/// the archive readable by every JDK 8 `ZipFile` implementation.
fn write_manifest_jar(file: fs::File, manifest: &str) -> std::io::Result<()> {
    let mut writer = zip::ZipWriter::new(file);
    let options =
        zip::write::SimpleFileOptions::default().compression_method(zip::CompressionMethod::Stored);
    writer
        .start_file("META-INF/MANIFEST.MF", options)
        .map_err(std::io::Error::other)?;
    writer.write_all(manifest.as_bytes())?;
    // `finish` returns the file so it is closed before the owner can delete it.
    let file = writer.finish().map_err(std::io::Error::other)?;
    file.sync_all()
}

fn next_temporary_path(extension: &str) -> PathBuf {
    static NEXT_ID: AtomicU64 = AtomicU64::new(0);
    std::env::temp_dir().join("lithe-run").join(format!(
        "launch-{}-{}.{extension}",
        std::process::id(),
        NEXT_ID.fetch_add(1, Ordering::Relaxed)
    ))
}

fn java_feature_version(executable: &str) -> Option<u32> {
    let home = std::path::Path::new(executable).parent()?.parent()?;
    let contents = fs::read_to_string(home.join("release")).ok()?;
    lithe_core::execution::java_feature_version_from_release(&contents)
}

fn encode_argfile(text: &str) -> Result<Vec<u8>, String> {
    #[cfg(windows)]
    {
        encode_argfile_in_code_page(text, unsafe { GetACP() })
    }
    #[cfg(not(windows))]
    {
        Ok(text.as_bytes().to_vec())
    }
}

#[cfg(windows)]
fn encode_argfile_in_code_page(text: &str, code_page: u32) -> Result<Vec<u8>, String> {
    let mut output = Vec::with_capacity(text.len());
    for character in text.chars() {
        if character.is_ascii() {
            output.push(character as u8);
        } else {
            // Core quotes every path value. The native argfile parser is byte-based:
            // a multibyte trailing 0x5c (e.g. Shift-JIS 表) must be escaped too.
            for byte in encode_code_page(&character.to_string(), code_page)? {
                output.push(byte);
                if byte == b'\\' {
                    output.push(byte);
                }
            }
        }
    }
    Ok(output)
}

#[cfg(windows)]
#[link(name = "kernel32")]
extern "system" {
    fn GetACP() -> u32;
    fn WideCharToMultiByte(
        code_page: u32,
        flags: u32,
        source: *const u16,
        source_len: i32,
        destination: *mut u8,
        destination_len: i32,
        default_char: *const u8,
        used_default: *mut i32,
    ) -> i32;
    fn MultiByteToWideChar(
        code_page: u32,
        flags: u32,
        source: *const u8,
        source_len: i32,
        destination: *mut u16,
        destination_len: i32,
    ) -> i32;
}

#[cfg(windows)]
fn encode_code_page(text: &str, code_page: u32) -> Result<Vec<u8>, String> {
    let failure = || {
        format!("Java launch paths cannot be represented losslessly in Windows code page {code_page}. Move the project and dependencies to representable paths or use UTF-8 system encoding.")
    };
    if text.is_empty() {
        return Ok(Vec::new());
    }
    let wide: Vec<u16> = text.encode_utf16().collect();
    let length = i32::try_from(wide.len()).map_err(|_| failure())?;
    // Native launcher options use the system code page even on JDK 18+.
    // Round-trip verification rejects replacement characters and best-fit mappings.
    unsafe {
        let size = WideCharToMultiByte(
            code_page,
            0,
            wide.as_ptr(),
            length,
            std::ptr::null_mut(),
            0,
            std::ptr::null(),
            std::ptr::null_mut(),
        );
        if size <= 0 {
            return Err(failure());
        }
        let mut bytes = vec![0; size as usize];
        if WideCharToMultiByte(
            code_page,
            0,
            wide.as_ptr(),
            length,
            bytes.as_mut_ptr(),
            size,
            std::ptr::null(),
            std::ptr::null_mut(),
        ) != size
        {
            return Err(failure());
        }
        let decoded_len =
            MultiByteToWideChar(code_page, 0, bytes.as_ptr(), size, std::ptr::null_mut(), 0);
        if decoded_len <= 0 {
            return Err(failure());
        }
        let mut decoded = vec![0; decoded_len as usize];
        if MultiByteToWideChar(
            code_page,
            0,
            bytes.as_ptr(),
            size,
            decoded.as_mut_ptr(),
            decoded_len,
        ) != decoded_len
            || decoded != wide
        {
            return Err(failure());
        }
        Ok(bytes)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct JdkFixture(PathBuf);
    impl JdkFixture {
        fn new() -> Self {
            Self::with_version("21.0.2")
        }
        fn with_version(version: &str) -> Self {
            let root = next_temporary_path("jdk");
            fs::create_dir_all(root.join("bin")).unwrap();
            let fixture = Self(root);
            fs::write(
                fixture.0.join("release"),
                format!("JAVA_VERSION=\"{version}\"\n"),
            )
            .unwrap();
            fixture
        }
        fn working_directory(&self) -> String {
            self.0.to_string_lossy().into_owned()
        }
        fn executable(&self) -> String {
            self.0.join("bin/java.exe").to_string_lossy().into_owned()
        }
    }
    impl Drop for JdkFixture {
        fn drop(&mut self) {
            fs::remove_dir_all(&self.0).unwrap();
        }
    }
    fn long_arguments() -> Vec<String> {
        vec![
            "-cp".into(),
            (0..600)
                .map(|i| format!("C:/repository/example/artifact-{i}/1.0/artifact-{i}.jar"))
                .collect::<Vec<_>>()
                .join(";"),
            "Main".into(),
        ]
    }

    /// A host-native class path under the fixture: the separator and absolute
    /// path syntax follow the platform the planner will be asked about.
    fn native_long_classpath(jdk: &JdkFixture, classes_name: &str) -> (Vec<String>, PathBuf) {
        let classes = jdk.0.join(classes_name);
        fs::create_dir_all(&classes).unwrap();
        let separator = if cfg!(windows) { ";" } else { ":" };
        let entries = std::iter::once(classes.to_string_lossy().into_owned())
            .chain((0..600).map(|i| {
                jdk.0
                    .join(format!("repository/artifact-{i}/1.0/artifact-{i}.jar"))
                    .to_string_lossy()
                    .into_owned()
            }))
            .collect::<Vec<_>>()
            .join(separator);
        (vec!["-cp".into(), entries, "Main".into()], classes)
    }

    fn read_manifest(path: &std::path::Path) -> String {
        let mut archive = zip::ZipArchive::new(fs::File::open(path).unwrap()).unwrap();
        assert_eq!(archive.len(), 1, "the JAR holds only its manifest");
        let mut manifest = String::new();
        std::io::Read::read_to_string(
            &mut archive.by_name("META-INF/MANIFEST.MF").unwrap(),
            &mut manifest,
        )
        .unwrap();
        manifest
    }

    /// Regression for #955: JDK 8 cannot read `@argfile`, so its oversized
    /// class path must be written to a temporary manifest JAR instead.
    #[test]
    fn jdk8_launch_uses_an_owned_classpath_jar_in_the_temporary_directory() {
        let jdk = JdkFixture::with_version("1.8.0_392");
        // The manifest percent-encodes UTF-8, so this name works on every
        // Windows code page, unlike an argument file.
        let (arguments, classes) = native_long_classpath(&jdk, "项目 classes");
        let (shortened, file) =
            prepare(&jdk.executable(), &arguments, &jdk.working_directory()).unwrap();
        let file = file.expect("an oversized JDK 8 class path must be shortened");
        let jar = file.0.clone();
        assert!(jar.starts_with(std::env::temp_dir().join("lithe-run")));
        assert!(jar.to_string_lossy().ends_with(".classpath.jar"));
        assert_eq!(shortened, ["-cp", jar.to_str().unwrap(), "Main"]);
        let manifest = read_manifest(&jar);
        assert!(manifest.starts_with("Manifest-Version: 1.0\r\nClass-Path: file:"));
        let logical = manifest.replace("\r\n ", "");
        let class_path = logical
            .lines()
            .find_map(|line| line.strip_prefix("Class-Path: "))
            .unwrap();
        let urls: Vec<&str> = class_path.split(' ').collect();
        assert_eq!(urls.len(), 601);
        // The existing directory keeps its trailing slash and its encoded name.
        assert!(
            urls[0].ends_with("/%E9%A1%B9%E7%9B%AE%20classes/"),
            "{}",
            urls[0]
        );
        assert!(urls[1].ends_with("/artifact-0.jar"));
        drop(file);
        assert!(!jar.exists(), "the owner deletes the JAR");
        assert!(classes.exists(), "only the temporary JAR is removed");
    }

    #[test]
    fn jdk9_and_later_still_use_an_argument_file() {
        let jdk = JdkFixture::with_version("17.0.9");
        let (arguments, _) = native_long_classpath(&jdk, "classes");
        let (shortened, file) =
            prepare(&jdk.executable(), &arguments, &jdk.working_directory()).unwrap();
        let file = file.expect("an oversized JDK 17 class path must be shortened");
        assert!(file.0.to_string_lossy().ends_with(".argfile"));
        assert_eq!(shortened[0], format!("@{}", file.0.display()));
    }

    #[test]
    fn short_and_unknown_version_jdk8_launches_create_no_file() {
        let jdk = JdkFixture::with_version("1.8.0_392");
        let short = vec!["-cp".into(), "classes".into(), "Main".into()];
        let (actual, file) = prepare(&jdk.executable(), &short, &jdk.working_directory()).unwrap();
        assert_eq!(actual, short);
        assert!(file.is_none());
        fs::write(jdk.0.join("release"), "MODULES=\"java.base\"\n").unwrap();
        let (arguments, _) = native_long_classpath(&jdk, "classes");
        let (actual, file) =
            prepare(&jdk.executable(), &arguments, &jdk.working_directory()).unwrap();
        assert_eq!(actual, arguments);
        assert!(file.is_none());
    }

    #[test]
    fn replacement_execution_owns_a_distinct_file() {
        let jdk = JdkFixture::new();
        let cwd = jdk.working_directory();
        let (first_args, first) = prepare(&jdk.executable(), &long_arguments(), &cwd).unwrap();
        let (second_args, second) = prepare(&jdk.executable(), &long_arguments(), &cwd).unwrap();
        let first = first.unwrap();
        let second = second.unwrap();
        assert_ne!(first_args, second_args);
        let first_path = first.0.clone();
        let second_path = second.0.clone();
        drop(first);
        assert!(!first_path.exists());
        assert!(fs::read_to_string(&second_path)
            .unwrap()
            .starts_with("-cp\n"));
        drop(second);
        assert!(!second_path.exists());
    }

    #[test]
    fn short_non_java_and_unknown_jdk_launches_stay_direct() {
        let jdk = JdkFixture::new();
        let short = vec!["-cp".into(), "classes".into(), "Main".into()];
        let cwd = jdk.working_directory();
        let (actual, file) = prepare(&jdk.executable(), &short, &cwd).unwrap();
        assert_eq!(actual, short);
        assert!(file.is_none());
        for executable in ["node.exe", "C:/missing/bin/java.exe"] {
            let args = long_arguments();
            let (actual, file) = prepare(executable, &args, &cwd).unwrap();
            assert_eq!(actual, args);
            assert!(file.is_none());
        }
        assert_eq!(java_feature_version(&jdk.executable()), Some(21));
    }

    #[cfg(windows)]
    #[test]
    fn native_encoding_handles_chinese_and_rejects_lossy_paths() {
        assert_eq!(encode_code_page("中", 936).unwrap(), [0xd6, 0xd0]);
        assert_eq!(
            encode_argfile_in_code_page("\"表\"", 932).unwrap(),
            [b'"', 0x95, 0x5c, 0x5c, b'"']
        );
        assert_eq!(encode_code_page("中", 65001).unwrap(), "中".as_bytes());
        assert!(encode_code_page("中", 1252).is_err());
        assert_eq!(
            encode_code_page("-cp classes", 1252).unwrap(),
            b"-cp classes"
        );
    }
}
