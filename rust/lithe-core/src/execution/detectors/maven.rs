use super::super::types::Confidence;
use super::{Detected, DirectoryContext};
use crate::project::{declared_modules, DeclaredModule};
use std::collections::BTreeMap;

/// Plugins that make a module a runnable service, paired with the provider that
/// records how the launch layer must address it.
///
/// A framework is identified by the plugin it applies rather than by a
/// dependency or an annotation: the plugin is what contributes the goal that
/// starts the service, so if it is absent there is nothing to run whatever the
/// sources say. Each framework needs its own provider because the goals take
/// their arguments under different property names -- see `maven_arguments`.
const SERVICE_PLUGINS: &[(&str, &str)] = &[
    ("spring-boot-maven-plugin", "spring-boot.maven"),
    ("quarkus-maven-plugin", "quarkus.maven"),
    ("micronaut-maven-plugin", "micronaut.maven"),
];

/// Maven modules are *declared*, not discovered, so this detector reads the
/// module graph from the root `pom.xml` instead of judging each directory the
/// shared walk visits.
///
/// A directory-driven scan gets Maven wrong in both directions: `<modules>` may
/// name a directory the walk prunes (one called `build` or `out` is invisible),
/// while a leftover `pom.xml` outside the graph is not part of the build at all.
/// Reading the graph once at the root is also cheaper than parsing every pom the
/// walk happens to pass.
pub fn detect(ctx: &DirectoryContext) -> Vec<Detected> {
    if ctx.relative != "." || !ctx.has("pom.xml") {
        return Vec::new();
    }
    let Ok(modules) = declared_modules(&ctx.root) else {
        return Vec::new();
    };
    let names = service_names(&modules);
    modules
        .iter()
        .filter(|module| !module.is_aggregator())
        .filter_map(|module| {
            let provider = service_provider(module)?;
            let name = names.get(&module.relative_path)?;
            Some(service(ctx, module, name, provider))
        })
        .collect()
}

/// The provider for the first framework plugin a module applies.
///
/// A module applying two of these is misconfigured -- only one goal can own the
/// process -- so table order decides rather than emitting two services that
/// would both claim the same port.
fn service_provider(module: &DeclaredModule) -> Option<&'static str> {
    SERVICE_PLUGINS
        .iter()
        .find(|(plugin, _)| module.applies_plugin(plugin))
        .map(|(_, provider)| *provider)
}

/// A Spring Boot module is launched by Maven from the reactor root, addressed by
/// `-pl <module>`. Every such configuration therefore shares one `cwd`, so the
/// name is what keeps two modules apart during dedup.
///
/// `artifactId` is Maven's own name for a module and is what a developer
/// recognises, but it is only unique per `groupId`. Where two modules share one,
/// both fall back to their path so neither is silently dropped.
fn service_names(modules: &[DeclaredModule]) -> BTreeMap<String, String> {
    let mut counts: BTreeMap<&str, usize> = BTreeMap::new();
    for module in modules {
        *counts.entry(module.artifact_id.as_str()).or_default() += 1;
    }
    modules
        .iter()
        .map(|module| {
            let unique = counts.get(module.artifact_id.as_str()) == Some(&1);
            let name = if unique {
                module.artifact_id.clone()
            } else {
                module.relative_path.clone()
            };
            (module.relative_path.clone(), name)
        })
        .collect()
}

/// These frameworks run through Maven rather than a command on `PATH`, so the
/// executable is a toolchain binding and the launch layer assembles the goal
/// from the `maven` extension. The main class is deliberately absent: the plugin
/// resolves it from the module itself, and the Java scan supplies it only when a
/// `@SpringBootApplication` source was read.
fn service(
    ctx: &DirectoryContext,
    module: &DeclaredModule,
    name: &str,
    provider: &str,
) -> Detected {
    // The detection is made at the root but the evidence is the module's own
    // pom, which is what the "why is this here" affordance should point at.
    let source = if module.relative_path == "." {
        "pom.xml".to_string()
    } else {
        format!("{}/pom.xml", module.relative_path)
    };
    // The command is discarded by `with_toolchains`: Maven is reached through
    // the project binding, which may be `./mvnw` rather than a program on PATH.
    Detected::service(provider, name, "", Vec::new(), ctx, &source)
        .with_toolchains(&[("java", "project-jdk"), ("maven", "project-maven")])
        .with_debug("jdwp")
        .with_confidence(Confidence::Declared)
        .with_extension(
            "maven",
            serde_json::json!({ "module": module.relative_path }),
        )
}
