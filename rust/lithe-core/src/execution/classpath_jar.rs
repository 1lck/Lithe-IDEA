//! Shortens an oversized Java 8 class path through a manifest-only JAR.
//!
//! JDK 9 added `java @file` argument files, so [`super::plan_launch_command`]
//! cannot help a JDK 8 launch. The launcher has always accepted a JAR whose
//! `META-INF/MANIFEST.MF` lists further class-path entries in its `Class-Path`
//! attribute. Passing that one JAR with `-cp` keeps the command line short
//! while the application class loader still sees every original entry in order.
//!
//! Core converts each entry to an absolute `file:` URL and renders the manifest
//! text, including the 72-byte line rule. The host owns the filesystem: it
//! answers whether an entry is a directory, writes the JAR at the path it
//! supplied, and deletes it after that execution exits. Every URL is
//! percent-encoded UTF-8, so the manifest is pure ASCII and, unlike an argument
//! file, does not depend on the Windows system code page.

use super::launch_command::{command_line_length, COMMAND_LINE_MARGIN, WINDOWS_COMMAND_LINE_LIMIT};
use std::path::Path;

/// First JDK release whose launcher reads argument files; from this version on
/// the argument-file planner owns shortening.
const FIRST_ARGFILE_JAVA_VERSION: u32 = 9;

/// Launcher options that a JDK 8 `java` accepts for the class path. The long
/// `--class-path` spelling only exists from JDK 9 on.
const CLASSPATH_OPTIONS: &[&str] = &["-cp", "-classpath"];

/// Longest manifest line in bytes, excluding the line break. Longer headers
/// continue on lines that start with one space (JAR File Specification).
const MANIFEST_LINE_LIMIT: usize = 72;

/// Path syntax of the host that will start the JVM. It decides the class-path
/// separator and how absolute paths are recognized and turned into URLs.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ClasspathStyle {
    /// `;`-separated entries with drive-letter or UNC absolute paths.
    Windows,
    /// `:`-separated entries with `/`-rooted absolute paths.
    Posix,
}

/// Inputs for [`plan_classpath_jar_launch`].
#[derive(Debug, Clone, Copy)]
pub struct ClasspathJarRequest<'a> {
    /// Java executable path used for launcher detection.
    pub executable: &'a str,
    /// Complete argument vector before shortening.
    pub arguments: &'a [String],
    /// Directory the JVM starts in. Relative class-path entries resolve against
    /// it on the command line, but against the JAR inside a manifest, so Core
    /// makes them absolute first.
    pub working_directory: &'a str,
    /// Host-owned path that may be referenced by a classpath-JAR plan.
    pub classpath_jar_path: &'a Path,
    /// Optional host-specific command-line cap; `None` uses the Windows cap.
    pub limit: Option<usize>,
    /// JDK feature version read by the host from its `release` file.
    pub java_feature_version: Option<u32>,
    /// Path syntax used by the class-path value.
    pub style: ClasspathStyle,
}

/// How a host should start a JDK 8 launch whose class path may be too long.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ClasspathJarPlan {
    /// Spawn with the original arguments.
    Direct,
    /// Write a JAR containing only `META-INF/MANIFEST.MF` with `manifest` at the
    /// supplied path, then spawn with `arguments`.
    ClasspathJar {
        /// Arguments whose effective class-path value is the JAR path.
        arguments: Vec<String>,
        /// Complete ASCII manifest text with CRLF line breaks.
        manifest: String,
    },
}

/// Plans a manifest-JAR launch for a known JDK older than 9.
///
/// `is_directory` receives each absolute entry and reports whether it names a
/// directory: a manifest URL must end in `/` for the class loader to treat it as
/// a directory rather than an archive. Returns [`ClasspathJarPlan::Direct`] when
/// the JDK is unknown or supports argument files, the command fits, the launch
/// uses `-jar` (which ignores `-cp`), or an entry cannot be expressed as an
/// absolute URL without changing its meaning, such as a `lib/*` wildcard.
pub fn plan_classpath_jar_launch(
    request: ClasspathJarRequest<'_>,
    is_directory: impl Fn(&str) -> bool,
) -> ClasspathJarPlan {
    let executable_name = request
        .executable
        .rsplit(['/', '\\'])
        .next()
        .unwrap_or(request.executable);
    if !["java", "java.exe", "javaw", "javaw.exe"]
        .iter()
        .any(|name| executable_name.eq_ignore_ascii_case(name))
        || !request
            .java_feature_version
            .is_some_and(|version| version < FIRST_ARGFILE_JAVA_VERSION)
    {
        return ClasspathJarPlan::Direct;
    }
    let budget = request
        .limit
        .unwrap_or(WINDOWS_COMMAND_LINE_LIMIT)
        .saturating_sub(COMMAND_LINE_MARGIN);
    if command_line_length(request.executable, request.arguments) <= budget {
        return ClasspathJarPlan::Direct;
    }
    let Some(value_index) = effective_classpath_value_index(request.arguments) else {
        return ClasspathJarPlan::Direct;
    };
    let Some(urls) = classpath_urls(
        &request.arguments[value_index],
        request.working_directory,
        request.style,
        &is_directory,
    ) else {
        return ClasspathJarPlan::Direct;
    };
    let mut arguments = request.arguments.to_vec();
    arguments[value_index] = request.classpath_jar_path.display().to_string();
    let mut manifest = String::from("Manifest-Version: 1.0\r\n");
    manifest.push_str(&manifest_header("Class-Path", &urls.join(" ")));
    // A header is only recognized once its line is terminated, and the blank
    // line closes the main section.
    manifest.push_str("\r\n");
    ClasspathJarPlan::ClasspathJar {
        arguments,
        manifest,
    }
}

/// Finds the class-path value the JDK 8 launcher will use.
///
/// Launcher options end at the main class or `-jar`. When `-cp` appears more
/// than once the last occurrence wins, so only that value is replaced. `-jar`
/// ignores `-cp` entirely, which leaves nothing to shorten.
fn effective_classpath_value_index(arguments: &[String]) -> Option<usize> {
    let mut effective = None;
    let mut index = 0;
    while index < arguments.len() {
        let argument = arguments[index].as_str();
        if argument == "-jar" {
            return None;
        }
        if !argument.starts_with('-') {
            break;
        }
        if CLASSPATH_OPTIONS.contains(&argument) && index + 1 < arguments.len() {
            effective = Some(index + 1);
            index += 2;
        } else {
            index += 1;
        }
    }
    effective
}

/// Converts a joined class-path value into manifest URLs in launcher order.
fn classpath_urls(
    value: &str,
    working_directory: &str,
    style: ClasspathStyle,
    is_directory: &dyn Fn(&str) -> bool,
) -> Option<Vec<String>> {
    let separator = match style {
        ClasspathStyle::Windows => ';',
        ClasspathStyle::Posix => ':',
    };
    value
        .split(separator)
        .map(|entry| {
            // The launcher reads an empty element as the current directory.
            let entry = if entry.is_empty() { "." } else { entry };
            let absolute = absolute_entry(entry, working_directory, style)?;
            // Launcher wildcards are expanded only on the command line; the
            // manifest class loader would look for a file literally named `*`.
            if absolute.rsplit(['/', '\\']).next() == Some("*") {
                return None;
            }
            Some(file_url(&absolute, style, is_directory(&absolute)))
        })
        .collect()
}

/// Makes one entry absolute, or returns `None` when its base is ambiguous.
fn absolute_entry(entry: &str, working_directory: &str, style: ClasspathStyle) -> Option<String> {
    match style {
        ClasspathStyle::Posix => {
            if entry.starts_with('/') {
                Some(entry.to_string())
            } else if working_directory.starts_with('/') {
                Some(format!(
                    "{}/{entry}",
                    working_directory.trim_end_matches('/')
                ))
            } else {
                None
            }
        }
        ClasspathStyle::Windows => {
            let entry = entry.replace('/', "\\");
            let path = if windows_root(&entry).is_some() {
                entry
            } else if entry.starts_with('\\') {
                // `\lib\a.jar` is rooted on the working directory's drive.
                format!(
                    "{}{entry}",
                    windows_root(working_directory)?.trim_end_matches('\\')
                )
            } else if entry.as_bytes().get(1) == Some(&b':') {
                // `C:lib` depends on a per-drive current directory that the
                // host never sees, so it cannot be resolved deterministically.
                return None;
            } else {
                windows_root(working_directory)?;
                format!(
                    "{}\\{entry}",
                    working_directory.trim_end_matches(['\\', '/'])
                )
            };
            Some(normalize_windows_path(&path))
        }
    }
}

/// Returns the root prefix of an absolute Windows path: `C:\` or `\\host\share`.
fn windows_root(path: &str) -> Option<String> {
    let path = path.replace('/', "\\");
    let bytes = path.as_bytes();
    if bytes.len() >= 3 && bytes[0].is_ascii_alphabetic() && bytes[1] == b':' && bytes[2] == b'\\' {
        return Some(path[..3].to_string());
    }
    let unc = path.strip_prefix("\\\\")?;
    let mut parts = unc.splitn(3, '\\');
    let host = parts.next().filter(|part| !part.is_empty())?;
    let share = parts.next().filter(|part| !part.is_empty())?;
    Some(format!("\\\\{host}\\{share}"))
}

/// Removes `.` and `..` segments the way Windows does, which is lexical.
fn normalize_windows_path(path: &str) -> String {
    let root = windows_root(path).expect("absolute Windows path");
    let mut segments: Vec<&str> = Vec::new();
    for segment in path[root.len()..].split('\\') {
        match segment {
            "" | "." => {}
            ".." => {
                segments.pop();
            }
            _ => segments.push(segment),
        }
    }
    let root = root.trim_end_matches('\\');
    if segments.is_empty() {
        format!("{root}\\")
    } else {
        format!("{root}\\{}", segments.join("\\"))
    }
}

/// Renders an absolute path as a `file:` URL the JDK class loader can open.
///
/// Drive paths become `file:/C:/...` and UNC paths `file:////host/share/...`,
/// matching `java.io.File.toURI`. Every byte outside a small unreserved set is
/// percent-encoded as UTF-8; the JDK decodes the URL before opening the file.
fn file_url(path: &str, style: ClasspathStyle, directory: bool) -> String {
    let path = match style {
        ClasspathStyle::Windows => {
            let slashed = path.replace('\\', "/");
            if slashed.starts_with("//") {
                format!("//{slashed}")
            } else {
                format!("/{slashed}")
            }
        }
        ClasspathStyle::Posix => path.to_string(),
    };
    let mut url = String::from("file:");
    for byte in path.bytes() {
        if byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'.' | b'_' | b'~' | b'/' | b':') {
            url.push(byte as char);
        } else {
            url.push_str(&format!("%{byte:02X}"));
        }
    }
    if directory && !url.ends_with('/') {
        url.push('/');
    }
    url
}

/// Renders one manifest header, continuing lines after 72 bytes.
///
/// The text is ASCII because every URL is percent-encoded, so splitting at a
/// byte offset can never cut a character in half.
fn manifest_header(name: &str, value: &str) -> String {
    let line = format!("{name}: {value}");
    debug_assert!(line.is_ascii());
    let mut rendered = String::with_capacity(line.len() + line.len() / 35 + 2);
    let mut rest = line.as_str();
    let mut width = MANIFEST_LINE_LIMIT;
    loop {
        let (head, tail) = rest.split_at(rest.len().min(width));
        rendered.push_str(head);
        rendered.push_str("\r\n");
        if tail.is_empty() {
            return rendered;
        }
        rendered.push(' ');
        rest = tail;
        width = MANIFEST_LINE_LIMIT - 1;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn jar_path() -> &'static Path {
        Path::new("C:\\Temp\\lithe-run\\launch-1-0.classpath.jar")
    }

    /// Mirrors a resolved Maven runtime classpath that exceeds the Windows cap.
    fn classpath(entries: usize) -> String {
        (0..entries)
            .map(|index| {
                format!(
                    "C:\\Users\\developer\\.m2\\repository\\org\\example\\artifact-{index}\\1.0.{index}\\artifact-{index}-1.0.{index}.jar"
                )
            })
            .collect::<Vec<_>>()
            .join(";")
    }

    fn request<'a>(arguments: &'a [String], version: Option<u32>) -> ClasspathJarRequest<'a> {
        ClasspathJarRequest {
            executable: "C:\\jdk8\\bin\\java.exe",
            arguments,
            working_directory: "C:\\work\\demo",
            classpath_jar_path: jar_path(),
            limit: None,
            java_feature_version: version,
            style: ClasspathStyle::Windows,
        }
    }

    /// Joins continuation lines back into logical headers.
    fn class_path_urls(manifest: &str) -> Vec<String> {
        let logical = manifest.replace("\r\n ", "");
        logical
            .split("\r\n")
            .find_map(|line| line.strip_prefix("Class-Path: "))
            .expect("manifest has a Class-Path header")
            .split(' ')
            .map(str::to_string)
            .collect()
    }

    fn no_directories(_: &str) -> bool {
        false
    }

    /// Regression for #955: a large JDK 8 project failed in `CreateProcessW`
    /// because argument files only exist from JDK 9 on.
    #[test]
    fn an_oversized_jdk8_classpath_moves_into_a_manifest_jar() {
        let arguments = vec![
            "-Dfile.encoding=UTF-8".to_string(),
            "-cp".to_string(),
            classpath(500),
            "com.example.Main".to_string(),
            "--server.port=8080".to_string(),
        ];
        let ClasspathJarPlan::ClasspathJar {
            arguments: shortened,
            manifest,
        } = plan_classpath_jar_launch(request(&arguments, Some(8)), no_directories)
        else {
            panic!("an oversized JDK 8 classpath must be shortened");
        };
        assert_eq!(
            shortened,
            [
                "-Dfile.encoding=UTF-8",
                "-cp",
                "C:\\Temp\\lithe-run\\launch-1-0.classpath.jar",
                "com.example.Main",
                "--server.port=8080",
            ]
        );
        assert!(manifest.starts_with("Manifest-Version: 1.0\r\nClass-Path: file:/C:/Users/"));
        assert!(manifest.ends_with("\r\n\r\n"));
        let urls = class_path_urls(&manifest);
        assert_eq!(urls.len(), 500);
        assert_eq!(
            urls[0],
            "file:/C:/Users/developer/.m2/repository/org/example/artifact-0/1.0.0/artifact-0-1.0.0.jar"
        );
    }

    #[test]
    fn manifest_lines_never_exceed_72_bytes() {
        let arguments = vec!["-cp".into(), classpath(500), "Main".into()];
        let ClasspathJarPlan::ClasspathJar { manifest, .. } =
            plan_classpath_jar_launch(request(&arguments, Some(8)), no_directories)
        else {
            panic!("classpath should move");
        };
        let body = manifest
            .strip_suffix("\r\n\r\n")
            .expect("terminated section");
        let lines: Vec<&str> = body.split("\r\n").collect();
        assert!(lines.len() > 100, "a long header must wrap");
        assert!(lines.iter().all(|line| line.len() <= MANIFEST_LINE_LIMIT));
        // Continuation lines start with the one marker space and fill the
        // remaining 71 bytes, except the last one. The content after the
        // marker may itself begin with the space that separates two URLs.
        for line in &lines[2..lines.len() - 1] {
            assert_eq!(line.len(), MANIFEST_LINE_LIMIT);
            assert!(line.starts_with(' '));
        }
        let urls = class_path_urls(&manifest);
        assert_eq!(urls.len(), 500);
        assert!(urls.iter().all(|url| url.starts_with("file:/C:/Users/")));
        // Every break is CRLF, the form the `jar` tool writes.
        assert_eq!(
            manifest.matches('\n').count(),
            manifest.matches("\r\n").count()
        );
    }

    #[test]
    fn spaces_chinese_and_reserved_characters_are_percent_encoded() {
        let entries = format!(
            "C:\\Program Files\\示例 库\\a#b%c+d.jar;D:/mixed/slash.jar;{}",
            classpath(500)
        );
        let arguments = vec!["-cp".into(), entries, "Main".into()];
        let ClasspathJarPlan::ClasspathJar { manifest, .. } =
            plan_classpath_jar_launch(request(&arguments, Some(8)), no_directories)
        else {
            panic!("classpath should move");
        };
        assert!(
            manifest.is_ascii(),
            "manifest must not depend on a code page"
        );
        let urls = class_path_urls(&manifest);
        assert_eq!(
            urls[0],
            "file:/C:/Program%20Files/%E7%A4%BA%E4%BE%8B%20%E5%BA%93/a%23b%25c%2Bd.jar"
        );
        assert_eq!(urls[1], "file:/D:/mixed/slash.jar");
    }

    #[test]
    fn directories_relative_unc_and_empty_entries_become_absolute_urls() {
        let entries = format!(
            "target\\classes;..\\shared\\lib.jar;\\tools\\x.jar;\\\\server\\share\\dep.jar;;{}",
            classpath(500)
        );
        let arguments = vec!["-cp".into(), entries, "Main".into()];
        let directories = ["C:\\work\\demo\\target\\classes", "C:\\work\\demo"];
        let ClasspathJarPlan::ClasspathJar { manifest, .. } =
            plan_classpath_jar_launch(request(&arguments, Some(8)), |path| {
                directories.contains(&path)
            })
        else {
            panic!("classpath should move");
        };
        let urls = class_path_urls(&manifest);
        assert_eq!(urls[0], "file:/C:/work/demo/target/classes/");
        assert_eq!(urls[1], "file:/C:/work/shared/lib.jar");
        assert_eq!(urls[2], "file:/C:/tools/x.jar");
        assert_eq!(urls[3], "file:////server/share/dep.jar");
        // An empty element means the working directory to the launcher.
        assert_eq!(urls[4], "file:/C:/work/demo/");
    }

    #[test]
    fn jdk9_unknown_short_and_non_java_launches_stay_direct() {
        let long = vec!["-cp".into(), classpath(500), "Main".into()];
        for version in [None, Some(9), Some(21)] {
            assert_eq!(
                plan_classpath_jar_launch(request(&long, version), no_directories),
                ClasspathJarPlan::Direct
            );
        }
        let short = vec!["-cp".into(), classpath(3), "Main".into()];
        assert_eq!(
            plan_classpath_jar_launch(request(&short, Some(8)), no_directories),
            ClasspathJarPlan::Direct
        );
        let mut node = request(&long, Some(8));
        node.executable = "node.exe";
        assert_eq!(
            plan_classpath_jar_launch(node, no_directories),
            ClasspathJarPlan::Direct
        );
    }

    #[test]
    fn launches_whose_meaning_a_manifest_cannot_preserve_stay_direct() {
        for (entries, target) in [
            (format!("lib\\*;{}", classpath(500)), "Main"),
            (format!("C:lib\\a.jar;{}", classpath(500)), "Main"),
            (classpath(500), "-jar"),
        ] {
            let arguments = vec!["-cp".into(), entries, target.into(), "app.jar".into()];
            assert_eq!(
                plan_classpath_jar_launch(request(&arguments, Some(8)), no_directories),
                ClasspathJarPlan::Direct,
                "{target}"
            );
        }
        let without_classpath = vec!["Main".into(), classpath(500)];
        assert_eq!(
            plan_classpath_jar_launch(request(&without_classpath, Some(8)), no_directories),
            ClasspathJarPlan::Direct
        );
    }

    #[test]
    fn only_the_effective_classpath_before_the_main_class_is_replaced() {
        let arguments = vec![
            "-cp".into(),
            "ignored.jar".into(),
            "-classpath".into(),
            classpath(500),
            "Main".into(),
            "-cp".into(),
            "program-value".into(),
        ];
        let ClasspathJarPlan::ClasspathJar {
            arguments: shortened,
            manifest,
        } = plan_classpath_jar_launch(request(&arguments, Some(8)), no_directories)
        else {
            panic!("classpath should move");
        };
        assert_eq!(&shortened[..3], &arguments[..3]);
        assert_eq!(
            shortened[3],
            "C:\\Temp\\lithe-run\\launch-1-0.classpath.jar"
        );
        assert_eq!(&shortened[4..], &arguments[4..]);
        assert!(!manifest.contains("program-value"));
        assert!(!manifest.contains("ignored.jar"));
    }

    #[test]
    fn posix_paths_use_colon_separators() {
        let entries = (0..800)
            .map(|index| format!("/home/dev/.m2/repository/lib {index}/artifact-{index}.jar"))
            .chain(["classes".to_string()])
            .collect::<Vec<_>>()
            .join(":");
        let arguments = vec!["-cp".into(), entries, "Main".into()];
        let mut posix = request(&arguments, Some(8));
        posix.executable = "/opt/jdk8/bin/java";
        posix.working_directory = "/work/demo";
        posix.style = ClasspathStyle::Posix;
        let ClasspathJarPlan::ClasspathJar { manifest, .. } =
            plan_classpath_jar_launch(posix, |path| path == "/work/demo/classes")
        else {
            panic!("classpath should move");
        };
        let urls = class_path_urls(&manifest);
        assert_eq!(
            urls[0],
            "file:/home/dev/.m2/repository/lib%200/artifact-0.jar"
        );
        assert_eq!(urls[800], "file:/work/demo/classes/");
    }
}
