//! End-to-end check of the official Node.js plugin SDK (`sdk/node`) against
//! Rust Core; the scenario is shared with the Java SDK in `plugin_sdk/mod.rs`.
//! It runs only when `LITHE_PLUGIN_SDK_NODE` names a Node.js 20.3 or newer
//! executable; `scripts/verify-rust-core-crates.sh` sets it.

mod plugin_sdk;

#[test]
fn the_node_sdk_sample_backend_serves_build_requests_and_plugin_functions() {
    let Some(node) = plugin_sdk::node_from_environment("the Node.js SDK end-to-end check") else {
        return;
    };
    plugin_sdk::run_sample_scenario(&plugin_sdk::Sample {
        tool: "node",
        runtime: node.clone(),
        package: plugin_sdk::repository_path("sdk/node/examples/sample-build"),
        node,
    });
}
