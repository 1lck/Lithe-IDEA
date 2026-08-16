//! Python entry-point and framework discovery from declarations and conventions.

use super::super::types::Confidence;
use super::{Detected, DirectoryContext};

/// Combines declared Python entry points with framework-based conventions.
pub fn detect(ctx: &DirectoryContext) -> Vec<Detected> {
    let mut detected = pyproject(ctx);
    detected.extend(frameworks(ctx));
    detected
}

/// `[project.scripts]` and `[tool.poetry.scripts]` are the two declarative
/// places a Python project names its entry points.
fn pyproject(ctx: &DirectoryContext) -> Vec<Detected> {
    let Some(text) = ctx.read("pyproject.toml") else {
        return Vec::new();
    };
    let Ok(document) = text.parse::<toml::Table>() else {
        return Vec::new();
    };
    let tables = [
        document
            .get("project")
            .and_then(|value| value.get("scripts")),
        document
            .get("tool")
            .and_then(|value| value.get("poetry"))
            .and_then(|value| value.get("scripts")),
    ];
    // Poetry projects run their console scripts through the managed venv;
    // outside poetry the script lands on PATH directly.
    let poetry = document
        .get("tool")
        .and_then(|value| value.get("poetry"))
        .is_some();
    tables
        .into_iter()
        .flatten()
        .filter_map(|value| value.as_table())
        .flat_map(|table| table.keys())
        .map(|name| {
            let detected = if poetry {
                Detected::application(
                    "python.script",
                    name,
                    "poetry",
                    vec!["run", name],
                    ctx,
                    "pyproject.toml",
                )
            } else {
                Detected::application(
                    "python.script",
                    name,
                    name,
                    Vec::new(),
                    ctx,
                    "pyproject.toml",
                )
            };
            detected.with_extension("python", serde_json::json!({ "script": name }))
        })
        .collect()
}

/// Files that conventionally hold an application object, paired with the module
/// name uvicorn or flask would address it by.
const ENTRY_POINTS: &[(&str, &str)] = &[
    ("app.py", "app"),
    ("main.py", "main"),
    ("asgi.py", "asgi"),
    ("wsgi.py", "wsgi"),
];

/// Framework entry points have no declaration naming them as the entry point, so
/// they are recognised by their conventional file name. The framework *identity*
/// can still be declared, in the dependency list, which is what separates a
/// `Declared` detection from a `Heuristic` guess here.
fn frameworks(ctx: &DirectoryContext) -> Vec<Detected> {
    let declared = declared_dependencies(ctx);
    let confidence = |package: &str| {
        if declared.iter().any(|value| value == package) {
            Confidence::Declared
        } else {
            Confidence::Heuristic
        }
    };
    let mut detected = Vec::new();
    if ctx.has("manage.py") {
        detected.push(
            Detected::service(
                "python.django",
                "runserver",
                "python",
                vec!["manage.py", "runserver"],
                ctx,
                "manage.py",
            )
            .with_confidence(confidence("django"))
            .with_extension("python", serde_json::json!({ "framework": "django" })),
        );
    }
    for (file, module) in ENTRY_POINTS {
        let Some(text) = ctx.read(file) else {
            continue;
        };
        if text.contains("Flask(") || text.contains("from flask") {
            detected.push(
                Detected::service(
                    "python.flask",
                    module,
                    "flask",
                    vec!["--app", module, "run"],
                    ctx,
                    file,
                )
                .with_confidence(confidence("flask"))
                .with_extension(
                    "python",
                    serde_json::json!({ "module": module, "framework": "flask" }),
                ),
            );
            continue;
        }
        if text.contains("FastAPI(") || text.contains("from fastapi") {
            detected.push(asgi(ctx, file, module, "fastapi", confidence("fastapi")));
            continue;
        }
        // Starlette and Litestar are addressed exactly like FastAPI, so they are
        // recognised here rather than in a detector of their own.
        for (import, framework) in [
            ("from starlette", "starlette"),
            ("from litestar", "litestar"),
        ] {
            if text.contains(import) {
                detected.push(asgi(ctx, file, module, framework, confidence(framework)));
                break;
            }
        }
    }
    detected
}

/// An ASGI application is served by uvicorn addressing `module:app`. The provider
/// stays `python.uvicorn` because that is what runs; the framework travels in the
/// extension so the panel can label the service.
fn asgi(
    ctx: &DirectoryContext,
    file: &str,
    module: &str,
    framework: &str,
    confidence: Confidence,
) -> Detected {
    let target = format!("{module}:app");
    Detected::service(
        "python.uvicorn",
        module,
        "uvicorn",
        vec![target.as_str(), "--reload"],
        ctx,
        file,
    )
    .with_confidence(confidence)
    .with_extension(
        "python",
        serde_json::json!({ "module": module, "framework": framework }),
    )
}

/// Distribution names a project declares it depends on, lowercased.
///
/// Requirement lines carry version specifiers, extras, and markers, so the name
/// is everything before the first character that can introduce one.
fn declared_dependencies(ctx: &DirectoryContext) -> Vec<String> {
    let mut names = Vec::new();
    if let Some(document) = ctx
        .read("pyproject.toml")
        .and_then(|text| text.parse::<toml::Table>().ok())
    {
        let lists = [
            document
                .get("project")
                .and_then(|value| value.get("dependencies")),
            document
                .get("dependency-groups")
                .and_then(|value| value.get("dev")),
        ];
        for value in lists.into_iter().flatten() {
            names.extend(
                value
                    .as_array()
                    .into_iter()
                    .flatten()
                    .filter_map(|item| item.as_str())
                    .map(requirement_name),
            );
        }
        // Poetry declares dependencies as a table keyed by name.
        if let Some(table) = document
            .get("tool")
            .and_then(|value| value.get("poetry"))
            .and_then(|value| value.get("dependencies"))
            .and_then(|value| value.as_table())
        {
            names.extend(table.keys().map(|key| requirement_name(key)));
        }
    }
    for file in ["requirements.txt", "requirements-dev.txt"] {
        let Some(text) = ctx.read(file) else {
            continue;
        };
        names.extend(
            text.lines()
                .map(str::trim)
                .filter(|line| !line.is_empty() && !line.starts_with('#') && !line.starts_with('-'))
                .map(requirement_name),
        );
    }
    names
}

fn requirement_name(value: &str) -> String {
    value
        .split(['=', '<', '>', '!', '~', '[', ';', ' ', '@'])
        .next()
        .unwrap_or_default()
        .trim()
        .to_lowercase()
}
