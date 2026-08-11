use super::{Detected, DirectoryContext};
use serde_json::Value;

/// Scripts whose name says they start a long-running process. Everything else
/// is offered as a task, so the service list stays a list of *services* rather
/// than every lint and format script in the repo.
const SERVICE_SCRIPTS: &[&str] = &["dev", "start", "serve", "server", "watch", "preview"];

/// Package managers, most specific lockfile first. The chosen manager decides
/// the command, so guessing `npm` when the repo is pnpm-only produces a run
/// entry that fails at spawn time with a confusing error.
const MANAGERS: &[(&str, &str)] = &[
    ("bun.lockb", "bun"),
    ("bun.lock", "bun"),
    ("pnpm-lock.yaml", "pnpm"),
    ("yarn.lock", "yarn"),
    ("package-lock.json", "npm"),
];

pub fn detect(ctx: &DirectoryContext) -> Vec<Detected> {
    let Some(text) = ctx.read("package.json") else {
        return Vec::new();
    };
    let Ok(manifest) = serde_json::from_str::<Value>(&text) else {
        return Vec::new();
    };
    let manager = manager_for(ctx, &manifest);
    let Some(scripts) = manifest["scripts"].as_object() else {
        return Vec::new();
    };
    scripts
        .keys()
        .filter(|name| !name.is_empty())
        .map(|name| {
            let args = run_arguments(manager, name);
            let arguments = args.iter().map(String::as_str).collect::<Vec<_>>();
            let detected = if SERVICE_SCRIPTS.contains(&name.as_str()) {
                Detected::service("npm.script", name, manager, arguments, ctx, "package.json")
            } else {
                Detected::task("npm.script", name, manager, arguments, ctx, "package.json")
            };
            detected.with_extension(
                "npm",
                serde_json::json!({ "script": name, "manager": manager }),
            )
        })
        .collect()
}

fn manager_for(ctx: &DirectoryContext, manifest: &Value) -> &'static str {
    if let Some(manager) = manifest["packageManager"]
        .as_str()
        .and_then(|value| value.split('@').next())
        .and_then(known_manager)
    {
        return manager;
    }
    let mut directory = Some(ctx.path.as_path());
    while let Some(path) = directory {
        if let Some(manager) = MANAGERS
            .iter()
            .find(|(lockfile, _)| path.join(lockfile).is_file())
            .map(|(_, manager)| *manager)
        {
            return manager;
        }
        if path == ctx.root {
            break;
        }
        directory = path.parent().filter(|parent| parent.starts_with(&ctx.root));
    }
    "npm"
}

fn known_manager(value: &str) -> Option<&'static str> {
    match value {
        "npm" => Some("npm"),
        "pnpm" => Some("pnpm"),
        "yarn" => Some("yarn"),
        "bun" => Some("bun"),
        _ => None,
    }
}

/// `yarn <script>` takes no `run`; the others do. Yarn v1 accepts `run` too but
/// berry warns, and bare invocation works on both.
fn run_arguments(manager: &str, script: &str) -> Vec<String> {
    if manager == "yarn" {
        vec![script.to_string()]
    } else {
        vec!["run".to_string(), script.to_string()]
    }
}
