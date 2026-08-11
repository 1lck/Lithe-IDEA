use super::super::types::Confidence;
use super::{Detected, DirectoryContext};

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

/// Framework entry points have no declaration to read, so they are recognised
/// by their conventional file name and marked `Heuristic`. A real declaration
/// for the same service outranks these during dedup.
fn frameworks(ctx: &DirectoryContext) -> Vec<Detected> {
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
            .with_confidence(Confidence::Heuristic),
        );
    }
    for (file, module) in [("app.py", "app"), ("main.py", "main"), ("wsgi.py", "wsgi")] {
        if !ctx.has(file) {
            continue;
        }
        let flask = ctx
            .read(file)
            .is_some_and(|text| text.contains("Flask(") || text.contains("from flask"));
        if flask {
            detected.push(
                Detected::service(
                    "python.flask",
                    module,
                    "flask",
                    vec!["--app", module, "run"],
                    ctx,
                    file,
                )
                .with_confidence(Confidence::Heuristic)
                .with_extension("python", serde_json::json!({ "module": module })),
            );
            continue;
        }
        let fastapi = ctx
            .read(file)
            .is_some_and(|text| text.contains("FastAPI(") || text.contains("from fastapi"));
        if fastapi {
            let target = format!("{module}:app");
            detected.push(
                Detected::service(
                    "python.uvicorn",
                    module,
                    "uvicorn",
                    vec![target.as_str(), "--reload"],
                    ctx,
                    file,
                )
                .with_confidence(Confidence::Heuristic)
                .with_extension("python", serde_json::json!({ "module": module })),
            );
        }
    }
    detected
}
