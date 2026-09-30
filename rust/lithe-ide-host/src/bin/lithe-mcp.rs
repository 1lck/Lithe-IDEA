//! MCP stdio adapter for one explicitly authorized running IDE workspace.
use lithe_ide_host::{catalog, Call, Connection};
use rmcp::{model::*, service::RequestContext, ErrorData, RoleServer, ServerHandler, ServiceExt};
use serde_json::{json, Value};
use std::{path::PathBuf, time::Duration};

#[derive(Clone)]
struct Ide {
    connection: PathBuf,
    http: reqwest::Client,
}
impl ServerHandler for Ide {
    fn get_info(&self) -> ServerConfig {
        ServerConfig::new(ServerCapabilities::builder().enable_tools().build())
            .with_server_info(Implementation::new("lithe", env!("CARGO_PKG_VERSION")))
            .with_instructions("Operate only the Lithe project authorized by this connection. Inspect the environment and existing configurations first. Mutations require permissions in Lithe. Build/run tools execute project code. Use returned operationID for output and stop. Never retry a timed-out mutation without inspecting operations.")
    }
    async fn list_tools(
        &self,
        _: Option<PaginatedRequestParams>,
        _: RequestContext<RoleServer>,
    ) -> Result<ListToolsResult, ErrorData> {
        let tools = catalog::tools()
            .into_iter()
            .map(serde_json::from_value)
            .collect::<Result<Vec<Tool>, _>>()
            .map_err(|_| ErrorData::internal_error("Invalid IDE tool catalog", None))?;
        Ok(ListToolsResult {
            tools,
            ..Default::default()
        })
    }
    async fn call_tool(
        &self,
        request: CallToolRequestParams,
        _: RequestContext<RoleServer>,
    ) -> Result<CallToolResponse, ErrorData> {
        let result = self
            .invoke(Call {
                name: request.name.to_string(),
                arguments: request
                    .arguments
                    .map(Value::Object)
                    .unwrap_or_else(|| json!({})),
            })
            .await;
        let failed = result.get("error").is_some_and(|error| !error.is_null());
        let mut response = if failed {
            CallToolResult::error(vec![ContentBlock::text(result.to_string())])
        } else {
            CallToolResult::success(vec![ContentBlock::text(result.to_string())])
        };
        response.structured_content = Some(result);
        Ok(response.into())
    }
}
impl Ide {
    async fn invoke(&self, call: Call) -> Value {
        let result = async {
            let bytes = std::fs::read(&self.connection).map_err(|_| "Open the project in Lithe and enable MCP access")?;
            let connection: Connection = serde_json::from_slice(&bytes).map_err(|_| "Invalid IDE connection; disable and re-enable MCP in Lithe")?;
            let url = reqwest::Url::parse(&connection.endpoint).map_err(|_| "Invalid IDE endpoint")?;
            if url.scheme() != "http" || url.host_str() != Some("127.0.0.1") || url.path() != "/call" || !url.username().is_empty() || url.password().is_some() {
                return Err("IDE connections must use the local loopback endpoint");
            }
            let response = self.http.post(url).bearer_auth(connection.token).json(&call).send().await.map_err(|_| "Lithe is unavailable or the request timed out. Inspect operations before retrying.")?;
            if !response.status().is_success() { return Err("IDE connection rejected the request; reconnect from Lithe settings"); }
            response.json::<Value>().await.map_err(|_| "Invalid IDE response")
        }.await;
        result.unwrap_or_else(|message| catalog::failure("CONNECTION_FAILED", message))
    }
}
#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut args = std::env::args_os().skip(1);
    if args.next().as_deref() != Some(std::ffi::OsStr::new("--connection")) {
        return Err("Usage: lithe-mcp --connection <connection file from Lithe settings>".into());
    }
    let connection = PathBuf::from(args.next().ok_or("Missing connection file")?);
    if args.next().is_some() {
        return Err("Unexpected argument".into());
    }
    let http = reqwest::Client::builder()
        .no_proxy()
        .redirect(reqwest::redirect::Policy::none())
        .timeout(Duration::from_secs(125))
        .build()?;
    Ide { connection, http }
        .serve(rmcp::transport::stdio())
        .await?
        .waiting()
        .await?;
    Ok(())
}
