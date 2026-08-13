use super::super::types::Confidence;
use super::{Detected, DirectoryContext};
use serde_json::Value;

/// Frameworks in most-specific-first order, because the general framework is a
/// dependency of the specific one: Nuxt pulls in Vue, Next pulls in React, and
/// SvelteKit pulls in Svelte. Reporting `vue` for a Nuxt app would be true and
/// useless, so the first match wins.
const FRAMEWORKS: &[(&str, &str)] = &[
    ("nuxt", "nuxt"),
    ("next", "next"),
    ("@sveltejs/kit", "sveltekit"),
    ("@remix-run/dev", "remix"),
    ("@angular/core", "angular"),
    ("@nestjs/core", "nest"),
    ("astro", "astro"),
    ("@vue/cli-service", "vue"),
    ("vue", "vue"),
    ("svelte", "svelte"),
    ("react", "react"),
];

/// Programs that start a long-running server, each with the subcommands that do
/// so. An empty list means every invocation serves.
///
/// This is read from the script *body* because the script *name* is a
/// convention, not a declaration: `serve:local` starts a dev server and `start`
/// in a library package does not.
const SERVERS: &[(&str, &[&str])] = &[
    ("vite", &["", "dev", "serve", "preview"]),
    ("next", &["dev", "start"]),
    ("nuxt", &["dev", "start", "preview"]),
    ("nuxi", &["dev", "preview"]),
    ("astro", &["dev", "preview"]),
    ("remix", &["dev"]),
    ("ng", &["serve"]),
    ("vue-cli-service", &["serve"]),
    ("react-scripts", &["start"]),
    ("nest", &["start"]),
    ("nodemon", &[]),
    ("ts-node-dev", &[]),
    ("tsx", &["watch"]),
    ("webpack-dev-server", &[]),
    ("webpack", &["serve"]),
    ("http-server", &[]),
    ("serve", &[]),
];

/// Programs that always run to completion. Listed so a script whose body names
/// one is classified from that evidence instead of falling back to its name: a
/// `start` script that compiles is a task, whatever it is called.
const BUILDERS: &[&str] = &[
    "tsc",
    "rollup",
    "esbuild",
    "tsup",
    "parcel",
    "rimraf",
    "eslint",
    "prettier",
    "biome",
    "jest",
    "vitest",
    "playwright",
    "cypress",
    "mocha",
    "tap",
    "typedoc",
];

/// Script names that conventionally start a server. Kept as a fallback for
/// projects whose scripts shell out to something unrecognised, and reported as
/// `Heuristic` so any detector holding real evidence wins dedup.
const SERVICE_SCRIPTS: &[&str] = &["dev", "start", "serve", "server", "watch", "preview"];

/// Command prefixes that wrap the real program without changing what it is.
const WRAPPERS: &[&str] = &["npx", "cross-env", "env", "dotenv"];

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
    let framework = framework_for(&manifest);
    let Some(scripts) = manifest["scripts"].as_object() else {
        return Vec::new();
    };
    scripts
        .iter()
        .filter(|(name, _)| !name.is_empty())
        .map(|(name, body)| {
            let args = run_arguments(manager, name);
            let arguments = args.iter().map(String::as_str).collect::<Vec<_>>();
            let body = body.as_str().unwrap_or_default();
            let server = server_program(body);
            let detected = match server {
                Some(_) => {
                    Detected::service("npm.script", name, manager, arguments, ctx, "package.json")
                }
                None if SERVICE_SCRIPTS.contains(&name.as_str()) && !builds(body) => {
                    Detected::service("npm.script", name, manager, arguments, ctx, "package.json")
                        .with_confidence(Confidence::Heuristic)
                }
                None => Detected::task("npm.script", name, manager, arguments, ctx, "package.json"),
            };
            let mut extension = serde_json::json!({ "script": name, "manager": manager });
            if let Some(framework) = framework {
                extension["framework"] = framework.into();
            }
            if let Some(server) = server {
                extension["server"] = server.into();
            }
            detected.with_extension("npm", extension)
        })
        .collect()
}

/// The framework a package is built on, from its declared dependencies. Both
/// sections are searched because a framework may be a build-time dependency in
/// one project and a runtime one in another.
fn framework_for(manifest: &Value) -> Option<&'static str> {
    FRAMEWORKS
        .iter()
        .find(|(package, _)| {
            ["dependencies", "devDependencies"]
                .iter()
                .any(|section| manifest[section].get(package).is_some())
        })
        .map(|(_, framework)| *framework)
}

/// The server a script body starts, if any.
///
/// Each `&&` segment is examined rather than only the first, because a script
/// that prepares and then serves is still a service.
fn server_program(body: &str) -> Option<&'static str> {
    body.split("&&").find_map(|segment| {
        let (program, subcommand) = invocation(segment)?;
        SERVERS
            .iter()
            .find(|(name, serves)| {
                *name == program && (serves.is_empty() || serves.contains(&subcommand))
            })
            .map(|(name, _)| *name)
    })
}

/// Whether every segment of the script body runs a program known to terminate.
/// One unrecognised segment is enough to leave the question open, because it may
/// be the shell script that starts the server.
fn builds(body: &str) -> bool {
    let mut segments = body.split("&&").filter_map(invocation).peekable();
    segments.peek().is_some() && segments.all(|(program, _)| BUILDERS.contains(&program))
}

/// Splits a command segment into its program and first subcommand, skipping
/// leading environment assignments and wrappers. The subcommand is empty when
/// the program is invoked bare or with flags only.
///
/// Only the token immediately after the program counts: scanning further would
/// read a flag's value as the subcommand, so `vite --port 3000` would look like
/// `vite 3000` rather than the bare `vite` that serves.
fn invocation(segment: &str) -> Option<(&str, &str)> {
    let mut tokens = segment
        .split_whitespace()
        .skip_while(|token| token.contains('=') || WRAPPERS.contains(token));
    let program = tokens.next()?;
    let subcommand = tokens
        .next()
        .filter(|token| !token.starts_with('-'))
        .unwrap_or_default();
    Some((program, subcommand))
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
