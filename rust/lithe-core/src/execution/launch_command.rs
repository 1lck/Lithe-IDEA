//! Keeps an assembled launch command within the operating system's limit.
//!
//! A Java project launch passes the resolved runtime classpath on the command
//! line. For a large multi-module Maven project that is hundreds of absolute
//! jar paths, and Windows refuses to create a process whose command line
//! exceeds 32,767 UTF-16 code units. The JDK's own answer is an argument file:
//! `java @file` reads options from disk, so only the short reference stays on
//! the command line.
//!
//! Core decides whether shortening is required and what the file must contain.
//! The host owns the filesystem: it chooses the path, writes the file, and
//! deletes it after that execution exits. The returned text is Unicode; the
//! host must encode it losslessly with the launcher's native platform encoding.
//! JEP 400 does not make Windows launcher argument files UTF-8.

use serde::{Deserialize, Serialize};
use std::path::Path;

/// Maximum command line `CreateProcessW` accepts, including its terminating
/// null. Exceeding it fails the spawn with `ERROR_FILENAME_EXCED_RANGE` (206).
pub const WINDOWS_COMMAND_LINE_LIMIT: usize = 32_767;

/// Headroom for the null terminator and for host quoting that this estimate
/// does not model exactly. Shortening early costs nothing; shortening too late
/// fails the launch.
const COMMAND_LINE_MARGIN: usize = 2_048;

/// Options whose value is a joined list of absolute paths. These carry
/// practically all of an oversized command line, so moving them into the
/// argument file leaves the JVM options and program arguments untouched.
const PATH_LIST_OPTIONS: &[&str] = &["-cp", "-classpath", "--class-path", "-p", "--module-path"];

/// How a host should pass the assembled arguments to the operating system.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LaunchCommandPlan {
    /// The command line fits: spawn with the original arguments.
    Direct,
    /// The command line is too long. Write `argfile_contents` to the argfile
    /// path that was supplied, then spawn with `arguments`.
    Argfile {
        /// Arguments to spawn with; the moved options become one `@file` entry.
        arguments: Vec<String>,
        /// Complete argument-file text, already quoted and newline terminated.
        argfile_contents: String,
    },
}

/// JSON request used by hosts that cannot call the Rust planner directly.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LaunchCommandPlanRequest {
    /// Java executable path used for launcher detection.
    pub executable: String,
    /// Complete argument vector before shortening.
    pub arguments: Vec<String>,
    /// Host-owned path that may be referenced by an argument-file plan.
    pub argfile_path: String,
    /// Optional host-specific command-line cap; null uses the Windows cap.
    pub limit: Option<usize>,
    /// JDK feature version read by the host from its `release` file.
    pub java_feature_version: Option<u32>,
}

/// JSON response for [`LaunchCommandPlanRequest`].
#[derive(Debug, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum LaunchCommandPlanResponse {
    /// The original argument vector is safe to spawn directly.
    Direct,
    /// The host must write `argfileContents` before spawning `arguments`.
    Argfile {
        /// Arguments with path-list options replaced by an `@file` reference.
        arguments: Vec<String>,
        /// Newline-terminated JDK argument-file contents.
        #[serde(rename = "argfileContents")]
        argfile_contents: String,
    },
}

impl From<LaunchCommandPlan> for LaunchCommandPlanResponse {
    fn from(plan: LaunchCommandPlan) -> Self {
        match plan {
            LaunchCommandPlan::Direct => Self::Direct,
            LaunchCommandPlan::Argfile {
                arguments,
                argfile_contents,
            } => Self::Argfile {
                arguments,
                argfile_contents,
            },
        }
    }
}

/// Plans a launch through the shared JSON command dispatcher.
pub fn plan_launch_command_request(request: LaunchCommandPlanRequest) -> LaunchCommandPlanResponse {
    plan_launch_command(
        &request.executable,
        &request.arguments,
        Path::new(&request.argfile_path),
        request.limit,
        request.java_feature_version,
    )
    .into()
}

/// First JDK release that accepts `@file` argument files.
const MINIMUM_ARGFILE_JAVA_VERSION: u32 = 9;

/// Reads the feature version from a JDK `release` file.
///
/// `JAVA_VERSION="21.0.2"` yields 21 and the legacy `"1.8.0_392"` yields 8.
/// Hosts pass the result to [`plan_launch_command`], which needs it to know
/// whether an argument file is supported. Encoding is the host's responsibility.
pub fn java_feature_version_from_release(contents: &str) -> Option<u32> {
    let value = contents
        .lines()
        .find_map(|line| line.trim().strip_prefix("JAVA_VERSION="))?
        .trim()
        .trim_matches('"');
    let mut parts = value.split(['.', '_', '-', '+']);
    let first = parts.next()?.parse::<u32>().ok()?;
    if first == 1 {
        parts.next()?.parse::<u32>().ok()
    } else {
        Some(first)
    }
}

/// Plans how to spawn `executable` with `arguments` under `limit`.
///
/// `argfile_path` is the file the host will write when the returned plan asks
/// for one; it is only referenced, never created here. `limit` defaults to the
/// Windows command-line cap, which is the only mainstream limit small enough
/// for a Java class path to reach. `java_feature_version` is the JVM that will
/// expand the file; `None` means unknown and keeps the plan conservative.
pub fn plan_launch_command(
    executable: &str,
    arguments: &[String],
    argfile_path: &Path,
    limit: Option<usize>,
    java_feature_version: Option<u32>,
) -> LaunchCommandPlan {
    let executable_name = executable.rsplit(['/', '\\']).next().unwrap_or(executable);
    if !["java", "java.exe", "javaw", "javaw.exe"]
        .iter()
        .any(|name| executable_name.eq_ignore_ascii_case(name))
        || !java_feature_version.is_some_and(|version| version >= MINIMUM_ARGFILE_JAVA_VERSION)
    {
        return LaunchCommandPlan::Direct;
    }
    let limit = limit.unwrap_or(WINDOWS_COMMAND_LINE_LIMIT);
    let budget = limit.saturating_sub(COMMAND_LINE_MARGIN);
    if command_line_length(executable, arguments) <= budget {
        return LaunchCommandPlan::Direct;
    }
    let mut remaining = Vec::with_capacity(arguments.len());
    let mut argfile_lines = Vec::new();
    let mut index = 0;
    while index < arguments.len() {
        let argument = arguments[index].as_str();
        let value = arguments.get(index + 1);
        // The first application target ends launcher options. Everything after
        // it belongs to the program, even when named -p or --class-path.
        if !argument.starts_with('-')
            || matches!(argument, "-jar" | "-m" | "--module")
            || argument.starts_with("--module=")
        {
            remaining.extend_from_slice(&arguments[index..]);
            break;
        }
        if argument == "--disable-@files" {
            return LaunchCommandPlan::Direct;
        }
        match value {
            Some(value) if PATH_LIST_OPTIONS.contains(&argument) => {
                if argfile_lines.is_empty() {
                    remaining.push(format!("@{}", argfile_path.display()));
                }
                argfile_lines.push(argument.to_string());
                argfile_lines.push(quote_argfile_value(value));
                index += 2;
            }
            Some(value)
                if matches!(
                    argument,
                    "--add-modules"
                        | "--limit-modules"
                        | "--add-reads"
                        | "--add-exports"
                        | "--add-opens"
                        | "--patch-module"
                        | "--upgrade-module-path"
                        | "--enable-native-access"
                        | "--source"
                        | "--describe-module"
                        | "-d"
                ) =>
            {
                remaining.push(argument.to_string());
                remaining.push(value.clone());
                index += 2;
            }
            _ => {
                remaining.push(argument.to_string());
                index += 1;
            }
        }
    }
    if argfile_lines.is_empty() {
        // Nothing movable: the caller's own arguments are oversized, and the
        // host should report the operating system's refusal rather than
        // silently rewrite a command it does not understand.
        return LaunchCommandPlan::Direct;
    }
    let mut argfile_contents = argfile_lines.join("\n");
    argfile_contents.push('\n');
    LaunchCommandPlan::Argfile {
        arguments: remaining,
        argfile_contents,
    }
}

/// Estimates the command line the host will hand to the operating system.
///
/// Windows counts UTF-16 code units, and each argument containing whitespace or
/// a quote is wrapped in quotes. The estimate never has to be exact because
/// [`COMMAND_LINE_MARGIN`] absorbs the difference.
fn command_line_length(executable: &str, arguments: &[String]) -> usize {
    let mut length = quoted_length(executable);
    for argument in arguments {
        length += 1 + quoted_length(argument);
    }
    length
}

fn quoted_length(value: &str) -> usize {
    let units = value.encode_utf16().count();
    if value.is_empty() || value.contains([' ', '\t', '"']) {
        units + 2 + value.matches('"').count()
    } else {
        units
    }
}

/// Quotes one value for a JDK argument file.
///
/// Inside a quoted argfile string the backslash is an escape character, so
/// every separator in a Windows path has to be doubled. Quoting also keeps
/// paths that contain spaces in one argument.
fn quote_argfile_value(value: &str) -> String {
    let escaped = value.replace('\\', "\\\\").replace('"', "\\\"");
    format!("\"{escaped}\"")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn argfile() -> PathBuf {
        PathBuf::from("C:\\Temp\\lithe-run\\launch.argfile")
    }

    /// Mirrors a real Maven runtime classpath: absolute repository paths whose
    /// length is what pushes a multi-module project past the Windows limit.
    fn classpath(entries: usize) -> String {
        (0..entries)
            .map(|index| {
                format!(
                    "C:\\Users\\developer\\.m2\\repository\\org\\springframework\\boot\\spring-boot-starter-{index}\\3.2.{index}\\spring-boot-starter-{index}-3.2.{index}.jar"
                )
            })
            .collect::<Vec<_>>()
            .join(";")
    }

    #[test]
    fn a_command_that_fits_is_spawned_unchanged() {
        let arguments = vec![
            "-cp".to_string(),
            classpath(4),
            "org.dromara.DromaraApplication".to_string(),
        ];
        assert_eq!(
            plan_launch_command(
                "C:\\jdk\\bin\\java.exe",
                &arguments,
                &argfile(),
                None,
                Some(21)
            ),
            LaunchCommandPlan::Direct
        );
    }

    /// Regression: RuoYi-Vue-Plus resolves hundreds of jars, and the inline
    /// `-cp` made `CreateProcessW` fail before the JVM ever started.
    #[test]
    fn an_oversized_classpath_moves_into_an_argument_file() {
        let entries = classpath(500);
        let arguments = vec![
            "-Dfile.encoding=UTF-8".to_string(),
            "-cp".to_string(),
            entries.clone(),
            "org.dromara.DromaraApplication".to_string(),
            "--spring.profiles.active=dev".to_string(),
        ];

        let plan = plan_launch_command(
            "C:\\jdk\\bin\\java.exe",
            &arguments,
            &argfile(),
            None,
            Some(21),
        );
        let LaunchCommandPlan::Argfile {
            arguments: shortened,
            argfile_contents,
        } = plan
        else {
            panic!("an oversized classpath must be shortened");
        };
        // The argfile replaces the option in place, so JVM options still
        // precede the main class and program arguments still follow it.
        assert_eq!(
            shortened,
            [
                "-Dfile.encoding=UTF-8",
                "@C:\\Temp\\lithe-run\\launch.argfile",
                "org.dromara.DromaraApplication",
                "--spring.profiles.active=dev",
            ]
        );
        assert!(
            command_line_length("C:\\jdk\\bin\\java.exe", &shortened) < 1_000,
            "the remaining command line must be short: {shortened:?}"
        );
        let expected_value = format!("\"{}\"", entries.replace('\\', "\\\\"));
        assert_eq!(argfile_contents, format!("-cp\n{expected_value}\n"));
    }

    #[test]
    fn module_paths_are_moved_with_the_classpath() {
        let arguments = vec![
            "--module-path".to_string(),
            classpath(300),
            "-cp".to_string(),
            classpath(300),
            "-m".to_string(),
            "app/com.example.Main".to_string(),
        ];

        let LaunchCommandPlan::Argfile {
            arguments: shortened,
            argfile_contents,
        } = plan_launch_command(
            "C:\\jdk\\bin\\java.exe",
            &arguments,
            &argfile(),
            None,
            Some(21),
        )
        else {
            panic!("both path lists must be shortened");
        };
        // One argfile reference covers every moved option, and `-m` keeps its
        // own value because it names a module, not a path list.
        assert_eq!(
            shortened,
            [
                "@C:\\Temp\\lithe-run\\launch.argfile",
                "-m",
                "app/com.example.Main",
            ]
        );
        assert!(argfile_contents.starts_with("--module-path\n"));
        assert!(argfile_contents.contains("\n-cp\n"));
        assert!(argfile_contents.ends_with('\n'));
    }

    #[test]
    fn a_value_with_spaces_stays_one_argument_in_the_file() {
        let entries = format!("C:\\Program Files\\lib.jar;{}", classpath(500));
        let arguments = vec!["-cp".to_string(), entries, "Main".to_string()];

        let LaunchCommandPlan::Argfile {
            argfile_contents, ..
        } = plan_launch_command("java", &arguments, &argfile(), None, Some(21))
        else {
            panic!("an oversized classpath must be shortened");
        };
        assert!(argfile_contents.contains("\"C:\\\\Program Files\\\\lib.jar;"));
    }

    #[test]
    fn an_oversized_command_without_path_lists_is_left_to_the_operating_system() {
        let arguments = vec!["Main".to_string(), classpath(500)];
        assert_eq!(
            plan_launch_command("java", &arguments, &argfile(), None, Some(21)),
            LaunchCommandPlan::Direct
        );
    }

    #[test]
    fn the_limit_is_configurable_for_hosts_with_a_different_cap() {
        let arguments = vec![
            "-cp".to_string(),
            classpath(20),
            "com.example.Main".to_string(),
        ];
        assert_eq!(
            plan_launch_command("java", &arguments, &argfile(), None, Some(21)),
            LaunchCommandPlan::Direct
        );
        assert!(matches!(
            plan_launch_command("java", &arguments, &argfile(), Some(2_500), Some(21)),
            LaunchCommandPlan::Argfile { .. }
        ));
    }

    #[test]
    fn unicode_text_is_returned_for_the_host_to_encode_on_supported_jdks() {
        let arguments = vec![
            "-cp".into(),
            format!("C:\\Users\\示例;{}", classpath(500)),
            "Main".into(),
        ];
        for version in [9, 17, 21] {
            let LaunchCommandPlan::Argfile {
                argfile_contents, ..
            } = plan_launch_command("java.exe", &arguments, &argfile(), None, Some(version))
            else {
                panic!("a known supported JDK can use a host-encoded file");
            };
            assert!(argfile_contents.contains("示例"));
        }
    }

    #[test]
    fn non_java_and_unknown_or_unsupported_jdks_are_not_rewritten() {
        let arguments = vec!["-p".into(), classpath(500)];
        for executable in ["node.exe", "python.exe", "custom-launcher"] {
            assert_eq!(
                plan_launch_command(executable, &arguments, &argfile(), None, Some(21)),
                LaunchCommandPlan::Direct
            );
        }
        for version in [None, Some(8)] {
            assert_eq!(
                plan_launch_command("java.exe", &arguments, &argfile(), None, version),
                LaunchCommandPlan::Direct
            );
        }
    }

    #[test]
    fn application_arguments_keep_their_meaning_after_every_launch_target() {
        for target in [
            vec!["Main"],
            vec!["-jar", "app.jar"],
            vec!["-m", "app/Main"],
            vec!["--module=app/Main"],
        ] {
            let mut arguments = vec!["-cp".into(), classpath(500)];
            arguments.extend(target.into_iter().map(str::to_string));
            arguments.extend(["-p", "8080", "--class-path", "program-value"].map(str::to_string));
            let LaunchCommandPlan::Argfile {
                arguments: shortened,
                argfile_contents,
            } = plan_launch_command("java.exe", &arguments, &argfile(), None, Some(21))
            else {
                panic!("classpath should move");
            };
            assert_eq!(&shortened[1..], &arguments[2..]);
            assert!(!argfile_contents.contains("8080"));
            assert!(!argfile_contents.contains("program-value"));
        }
    }

    #[test]
    fn launcher_option_values_are_not_mistaken_for_path_options() {
        let arguments = vec![
            "--add-modules".into(),
            "-p".into(),
            "-cp".into(),
            classpath(500),
            "Main".into(),
        ];
        let LaunchCommandPlan::Argfile {
            arguments: shortened,
            ..
        } = plan_launch_command("java.exe", &arguments, &argfile(), None, Some(21))
        else {
            panic!("classpath should move");
        };
        assert_eq!(&shortened[..2], &arguments[..2]);
        let disabled = vec![
            "--disable-@files".into(),
            "-cp".into(),
            classpath(500),
            "Main".into(),
        ];
        assert_eq!(
            plan_launch_command("java.exe", &disabled, &argfile(), None, Some(21)),
            LaunchCommandPlan::Direct
        );
    }

    #[test]
    fn the_release_file_reports_the_feature_version() {
        assert_eq!(
            java_feature_version_from_release("IMPLEMENTOR=\"x\"\nJAVA_VERSION=\"21.0.2\"\n"),
            Some(21)
        );
        assert_eq!(
            java_feature_version_from_release("JAVA_VERSION=\"1.8.0_392\"\n"),
            Some(8)
        );
        assert_eq!(
            java_feature_version_from_release("JAVA_VERSION=\"17\"\n"),
            Some(17)
        );
        assert_eq!(
            java_feature_version_from_release("MODULES=\"java.base\"\n"),
            None
        );
    }
}
