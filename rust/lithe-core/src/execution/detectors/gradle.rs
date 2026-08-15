//! Gradle service discovery without starting Gradle or evaluating build scripts.

use super::super::types::Confidence;
use super::{Detected, DirectoryContext};

const BUILD_FILES: &[&str] = &["build.gradle", "build.gradle.kts"];
const SETTINGS_FILES: &[&str] = &["settings.gradle", "settings.gradle.kts"];

/// Plugin ids that make a project a long-running service, paired with the task
/// the plugin contributes. A build file may apply several, so the first match in
/// this order wins: `bootRun` supersedes the plain `run` it is built on.
const SERVICE_PLUGINS: &[(&str, &str)] = &[
    ("org.springframework.boot", "bootRun"),
    ("io.quarkus", "quarkusDev"),
    ("io.micronaut.application", "run"),
];

/// A Gradle build is runnable when a plugin contributes a start task. Gradle has
/// no manifest listing tasks, so the build script is matched for plugin ids
/// rather than executed: running `gradle tasks` on project open would spawn a
/// daemon and take seconds per module.
pub fn detect(ctx: &DirectoryContext) -> Vec<Detected> {
    let Some(file) = ctx.any_of(BUILD_FILES) else {
        return Vec::new();
    };
    let Some(text) = ctx.read(file) else {
        return Vec::new();
    };
    let Some(invocation) = Invocation::resolve(ctx) else {
        return Vec::new();
    };
    if let Some((plugin, task)) = service_plugin(&text) {
        return vec![configuration(
            ctx,
            &invocation,
            "gradle.service",
            task,
            file,
            true,
        )
        .with_extension(
            "gradle",
            serde_json::json!({ "task": task, "plugin": plugin, "project": invocation.project }),
        )];
    }
    if applies_plugin(&text, "application") {
        return vec![
            configuration(ctx, &invocation, "gradle.application", "run", file, false)
                .with_extension(
                    "gradle",
                    serde_json::json!({ "task": "run", "project": invocation.project }),
                ),
        ];
    }
    Vec::new()
}

/// Where Gradle must be invoked from, and how the task is addressed from there.
///
/// Gradle only resolves task paths from the directory holding the wrapper and
/// settings file, so a subproject cannot run from its own directory: the build
/// runs at the root and names the task `:module:bootRun`.
struct Invocation {
    /// Project-relative directory the command runs in.
    cwd: String,
    /// Task prefix, empty for a root build.
    prefix: String,
    /// Gradle project path, `:` for the root build.
    project: String,
}

impl Invocation {
    fn resolve(ctx: &DirectoryContext) -> Option<Self> {
        let build_root = build_root(ctx)?;
        if build_root == ctx.relative {
            return Some(Self {
                cwd: build_root,
                prefix: String::new(),
                project: ":".to_string(),
            });
        }
        // Strip the build root from the module path so the task prefix is
        // expressed relative to the build, not to the project.
        let relative = if build_root == "." {
            ctx.relative.as_str()
        } else {
            ctx.relative.strip_prefix(&format!("{build_root}/"))?
        };
        let project = format!(":{}", relative.replace('/', ":"));
        Some(Self {
            cwd: build_root,
            prefix: format!("{project}:"),
            project,
        })
    }
}

/// Walks up to the nearest directory holding a settings file, which is what
/// defines a Gradle build. A build file with no settings file above it is a
/// standalone single-project build.
fn build_root(ctx: &DirectoryContext) -> Option<String> {
    let mut directory = Some(ctx.path.as_path());
    while let Some(path) = directory {
        if SETTINGS_FILES.iter().any(|name| path.join(name).is_file()) {
            return relative_to_root(ctx, path);
        }
        if path == ctx.root {
            break;
        }
        directory = path.parent().filter(|parent| parent.starts_with(&ctx.root));
    }
    // No settings file anywhere above: the build file stands on its own.
    Some(ctx.relative.clone())
}

fn relative_to_root(ctx: &DirectoryContext, path: &std::path::Path) -> Option<String> {
    if path == ctx.root {
        return Some(".".to_string());
    }
    let relative = path.strip_prefix(&ctx.root).ok()?;
    Some(relative.to_string_lossy().replace('\\', "/"))
}

fn configuration(
    ctx: &DirectoryContext,
    invocation: &Invocation,
    provider: &str,
    task: &str,
    source: &str,
    service: bool,
) -> Detected {
    // Subproject tasks all run from the build root, so `cwd` cannot tell two
    // modules apart and the name carries the whole Gradle project path. A leaf
    // name would collide across parents (`a:orders` and `b:orders`) and dedup
    // would silently drop one of the two services.
    let name = if invocation.project == ":" {
        task.to_string()
    } else {
        invocation.project.trim_start_matches(':').to_string()
    };
    let argument = format!("{}{task}", invocation.prefix);
    let detected = if service {
        Detected::service(
            provider,
            &name,
            "gradle",
            vec![argument.as_str()],
            ctx,
            source,
        )
    } else {
        Detected::application(
            provider,
            &name,
            "gradle",
            vec![argument.as_str()],
            ctx,
            source,
        )
    };
    detected
        .with_cwd(&invocation.cwd)
        .with_confidence(Confidence::Declared)
}

fn service_plugin(text: &str) -> Option<(&'static str, &'static str)> {
    SERVICE_PLUGINS
        .iter()
        .copied()
        .find(|(plugin, _)| applies_plugin(text, plugin))
}

/// Recognises both plugin syntaxes without parsing Groovy or Kotlin:
/// `id 'org.springframework.boot'` in a `plugins` block, and the legacy
/// `apply plugin: 'org.springframework.boot'`. Commented-out lines are skipped
/// so a disabled plugin does not contribute a configuration.
fn applies_plugin(text: &str, plugin: &str) -> bool {
    text.lines()
        .map(str::trim)
        .filter(|line| !line.starts_with("//") && !line.starts_with('*'))
        .any(|line| {
            (line.contains("id ")
                || line.contains("id(")
                || line.contains("apply plugin")
                || line.contains("apply(plugin"))
                && [
                    format!("\"{plugin}\""),
                    format!("'{plugin}'"),
                    // Kotlin accessor form: `kotlin("jvm")` style shorthands are
                    // not plugin ids, but `alias(libs.plugins.spring.boot)` and
                    // bare `org.springframework.boot` do appear unquoted.
                    format!(" {plugin} "),
                ]
                .iter()
                .any(|needle| line.contains(needle.as_str()))
        })
}
