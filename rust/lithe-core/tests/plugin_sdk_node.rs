//! End-to-end check of the official Node.js plugin SDK (`sdk/node`) against
//! Rust Core; the scenario is shared with the Java SDK in `plugin_sdk/mod.rs`.
//! The VCS scenario is in `plugin_sdk/vcs.rs`, and the official Subversion
//! plugin, a Node SDK backend, in `plugin_sdk/svn.rs`. They run only when
//! `LITHE_PLUGIN_SDK_NODE` names a Node.js 20.3 or newer executable, and the
//! Subversion scenario also needs `LITHE_SVN`;
//! `scripts/verify-rust-core-crates.sh` sets both when the tools exist.

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

#[test]
fn the_node_sdk_sample_vcs_provider_answers_every_operation() {
    let Some(node) = plugin_sdk::node_from_environment("the Node.js SDK VCS end-to-end check")
    else {
        return;
    };
    plugin_sdk::vcs::run_vcs_scenario(&node);
}

#[test]
fn the_official_subversion_plugin_works_on_a_real_working_copy() {
    let Some(node) = plugin_sdk::node_from_environment("the Subversion plugin end-to-end check")
    else {
        return;
    };
    let Some(svn) = plugin_sdk::svn_from_environment("the Subversion plugin end-to-end check")
    else {
        return;
    };
    plugin_sdk::svn::run_svn_scenario(&node, &svn);
}
