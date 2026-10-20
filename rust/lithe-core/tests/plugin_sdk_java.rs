//! End-to-end check of the official Java plugin SDK (`sdk/java`) against Rust
//! Core, with the scenario shared with the Node.js SDK in `plugin_sdk/mod.rs`.
//!
//! The sample is installed the way a plugin ships: `plugin.json` and the
//! shaded `backend/sample-build.jar` in one package. It runs only when
//! `LITHE_PLUGIN_SDK_JAVA` names a Java 8 or newer executable,
//! `LITHE_PLUGIN_SDK_JAVA_SAMPLE` the built sample JAR, and
//! `LITHE_PLUGIN_SDK_NODE` Node.js for the sample workspace's build tools;
//! `scripts/verify-rust-core-crates.sh` sets all three.

mod plugin_sdk;

#[test]
fn the_java_sdk_sample_backend_serves_build_requests_and_plugin_functions() {
    let (Some(java), Some(jar)) = (
        std::env::var_os("LITHE_PLUGIN_SDK_JAVA"),
        std::env::var_os("LITHE_PLUGIN_SDK_JAVA_SAMPLE"),
    ) else {
        eprintln!(
            "skipped: set LITHE_PLUGIN_SDK_JAVA and LITHE_PLUGIN_SDK_JAVA_SAMPLE to run the Java SDK end-to-end check"
        );
        return;
    };
    let Some(node) = plugin_sdk::node_from_environment("the Java SDK end-to-end check") else {
        return;
    };
    let package = plugin_sdk::TemporaryPackage::new(
        "java",
        &[
            (
                "plugin.json",
                plugin_sdk::repository_path("sdk/java/examples/sample-build/plugin.json"),
            ),
            ("backend/sample-build.jar", jar.into()),
        ],
    );
    plugin_sdk::run_sample_scenario(&plugin_sdk::Sample {
        tool: "java",
        runtime: java.into_string().expect("UTF-8 Java path"),
        package: package.root.clone(),
        node,
    });
}
