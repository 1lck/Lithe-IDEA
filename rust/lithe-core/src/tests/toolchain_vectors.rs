//! Inline toolchain pin and query vectors shared by the Core toolchain tests.
//!
//! Every path lives under `/opt/lithe-fixtures`; no test creates or probes it.
//! The pin, query and resolution tests all read these values, so changing one
//! here changes the expectations of all three modules.

use serde_json::{json, Value};

/// Tool-definition fixture whose single tool every vector queries and pins.
const TOOL_DEFINITION: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../shared/contracts/plugins/v1/fixtures/toolchains/tool-definition.plugin.json"
));

/// Home of the tool that the query reply reports and the root pin selects.
pub(super) const HOME: &str = "/opt/lithe-fixtures/installs/tool/21.0.4";
/// Workspace root that the query request names.
pub(super) const WORKSPACE: &str = "/opt/lithe-fixtures/workspace";
/// Manually pinned home for `apps/web`, older than [`HOME`].
pub(super) const MANUAL_HOME: &str = "/opt/lithe-fixtures/manual/tool/17.0.12";

/// Returns the tool ID that [`TOOL_DEFINITION`] declares.
///
/// The vectors read the ID from the fixture instead of repeating it, so host
/// test code names no specific tool and stays in step with the fixture.
fn tool() -> String {
    let fixture: Value = serde_json::from_str(TOOL_DEFINITION).unwrap();
    fixture["toolDefinitions"][0]["id"]
        .as_str()
        .unwrap()
        .to_owned()
}

/// Builds a local pins document with a root pin, a manual pin on `apps/web`
/// and a pin on the hidden `.config/tools` directory.
///
/// The nested pins let tests check that a directory inherits its nearest
/// ancestor and that a sibling sharing a name prefix does not.
pub(super) fn local_pins() -> Value {
    let tool = tool();
    json!({"version":1,"toolchains":{},"pins":{
        ".":{tool.as_str():{"home":HOME,"version":"21.0.4","provider":"dev.lithe.fixture.mise:mise"}},
        "apps/web":{tool.as_str():{"home":MANUAL_HOME,"version":"17.0.12","provider":"host:manual"}},
        ".config/tools":{tool.as_str():{"home":HOME,"version":"21.0.4","provider":"dev.lithe.fixture.mise:mise"}}
    }})
}

/// Builds the `toolchains/query` request a host sends to the `mise` provider
/// for the fixture tool in the workspace root.
pub(super) fn query_request() -> Value {
    let tool = tool();
    json!({"jsonrpc":"2.0","id":1,"method":"toolchains/query","params":{
        "operationID":"query-1","generation":1,"providerID":"mise","authority":{"kind":"local"},
        "context":{"contextID":"context-1","generation":1},
        "workspace":{"rootID":"root-1","root":WORKSPACE,"directory":"."},"tools":[tool]}})
}

/// Builds a valid reply to [`query_request`]: one installed home and the
/// project requirement in `mise.toml` that selects it.
pub(super) fn query_response() -> Value {
    let tool = tool();
    json!({"jsonrpc":"2.0","id":1,"result":{
        "operationID":"query-1","generation":1,"providerID":"mise",
        "installations":[{"tool":tool,"version":"21.0.4","home":HOME}],
        "statements":[{"tool":tool,"scope":"project","source":format!("{WORKSPACE}/mise.toml"),
            "request":"21","installation":HOME,"kind":"declaration","reader":"native"}],
        "watch":[format!("{WORKSPACE}/mise.toml"),"/opt/lithe-fixtures/installs/tool"]}})
}

/// Builds one JSON-RPC error reply per stable toolchain failure.
///
/// The numeric codes are listed here independently of `query::rpc_code`, so a
/// test pairing each reply with its decoded code checks the mapping itself.
/// Ids and operation IDs are distinct placeholders; tests rewrite both to match
/// the request they answer.
pub(super) fn error_responses() -> Vec<Value> {
    const FAILURES: [(i64, &str); 11] = [
        (-32601, "methodUnavailable"),
        (-32602, "invalidParams"),
        (-32800, "cancelled"),
        (-32070, "permissionDenied"),
        (-32071, "authorityUnsupported"),
        (-32072, "timeout"),
        (-32073, "providerUnavailable"),
        (-32074, "invalidReply"),
        (-32075, "limitExceeded"),
        (-32076, "unsafePath"),
        (-32077, "operationExpired"),
    ];
    FAILURES
        .iter()
        .zip(100..)
        .map(|(&(number, name), id)| {
            json!({"jsonrpc":"2.0","id":id,"error":{"code":number,"message":"Fixture diagnostic.",
                "data":{"code":format!("plugin.toolchain.{name}"),"operationID":format!("query-{id}"),"providerID":"mise"}}})
        })
        .collect()
}
