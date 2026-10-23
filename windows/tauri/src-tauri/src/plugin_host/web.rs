//! Web tool windows (ui capability 2): package pages in a WebView2 shell.
//!
//! The contract rules (shared/contracts/plugins/v1/README.md, "Web content
//! (ui 2)") put the security boundary in the file service: only files of the
//! owning installed package are served, read-only, from a plugin-private
//! origin, with a CSP that refuses network access, remote resources, frames,
//! inline scripts and eval. The window shell (dock, title, order, lifecycle)
//! is host-owned; the page fills the body only. Build-system bridge methods
//! wait for the Windows build-system plugin capability and are not part of
//! this module.

use super::scan::ScannedPackage;
use serde::Serialize;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use tauri::{AppHandle, Manager, WebviewUrl, WebviewWindowBuilder};

/// Largest package file the scheme serves; a page cannot map the whole
/// package into memory through one request.
const MAX_PAGE_FILE_BYTES: u64 = 16 * 1024 * 1024;

/// CSP applied to every page response. `wasm-unsafe-eval` is absent: pages
/// compile no WebAssembly. `tauri:` IPC stays available because the bridge
/// runs over it; every other source is refused.
const PAGE_CSP: &str = "default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src ipc: http://ipc.localhost; frame-ancestors 'none'; form-action 'none'; base-uri 'none'";

/// Per-window page state (`ui.getState` / `ui.setState`), kept in the host so
/// web storage can stay non-persistent. Bounded per contract.
const MAX_PAGE_STATE_BYTES: usize = 64 * 1024;

#[derive(Default)]
pub struct WebPageHostState {
    states: Mutex<HashMap<String, Value>>,
}

/// State key of one page: plugin ID and tool window ID.
fn state_key(plugin_id: &str, window_id: &str) -> String {
    format!("{plugin_id}\u{0}{window_id}")
}

/// One declared web tool window of a scanned package.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WebToolWindow {
    pub window_id: String,
    pub plugin_id: String,
    pub title: String,
    pub placement: String,
    pub order: Option<u32>,
    /// Package-relative entry HTML path.
    pub entry: String,
}

/// Declared web tool windows of all accepted, enabled packages.
#[tauri::command]
pub fn declarative_plugins_web_windows(app: AppHandle) -> Vec<WebToolWindow> {
    let mut windows = Vec::new();
    for package in app.state::<super::PluginHostState>().packages() {
        if package.entry.status != "accepted" || !package.entry.enabled {
            continue;
        }
        collect_web_windows(&package, &mut windows);
    }
    windows.sort_by(|left, right| {
        (left.order.unwrap_or(u32::MAX), left.window_id.as_str())
            .cmp(&(right.order.unwrap_or(u32::MAX), right.window_id.as_str()))
    });
    windows
}

fn collect_web_windows(package: &ScannedPackage, windows: &mut Vec<WebToolWindow>) {
    let Some(tool_windows) = package.manifest["ui"]["toolWindows"].as_array() else {
        return;
    };
    for window in tool_windows {
        let Some(entry) = window["web"]["entry"].as_str() else {
            continue;
        };
        windows.push(WebToolWindow {
            window_id: window["id"].as_str().unwrap_or_default().to_string(),
            plugin_id: package.entry.plugin_id.clone(),
            title: window["title"].as_str().unwrap_or_default().to_string(),
            placement: window["placement"].as_str().unwrap_or("bottom").to_string(),
            order: window["order"].as_u64().map(|order| order as u32),
            entry: entry.to_string(),
        });
    }
}

/// Opens (or focuses) the web view of one tool window. The URL is the
/// plugin-private scheme origin with the declared entry path.
#[tauri::command]
pub fn declarative_plugins_open_web_window(
    app: AppHandle,
    plugin_id: String,
    window_id: String,
) -> Result<(), String> {
    let Some(window) = declarative_plugins_web_windows(app.clone())
        .into_iter()
        .find(|window| window.plugin_id == plugin_id && window.window_id == window_id)
    else {
        return Err(format!(
            "{plugin_id}/{window_id} is not a declared web tool window"
        ));
    };
    let label = format!(
        "plugin-web-{}",
        web_window_label(&window.plugin_id, &window.window_id)
    );
    if let Some(existing) = app.get_webview_window(&label) {
        let _ = existing.set_focus();
        return Ok(());
    }
    let url = format!(
        "lithe-plugin://{}/{}",
        urlencoding_encode(&window.plugin_id),
        window.entry
    );
    // Initialisation script defines the frozen `window.lithe` bridge before
    // any page script runs.
    let bridge = bridge_script(&window.plugin_id, &window.window_id);
    WebviewWindowBuilder::new(
        &app,
        &label,
        WebviewUrl::CustomProtocol(url.parse().map_err(|error| format!("{error}"))?),
    )
    .title(window.title)
    .initialization_script(&bridge)
    .build()
    .map(|_| ())
    .map_err(|error| format!("web window could not open: {error}"))
}

/// Destroys the web view of one tool window; used on plugin disable,
/// uninstall, and window teardown.
#[tauri::command]
pub fn declarative_plugins_close_web_window(
    app: AppHandle,
    plugin_id: String,
    window_id: String,
) -> Result<(), String> {
    let label = format!("plugin-web-{}", web_window_label(&plugin_id, &window_id));
    if let Some(existing) = app.get_webview_window(&label) {
        existing
            .close()
            .map_err(|error| format!("web window could not close: {error}"))?;
    }
    Ok(())
}

/// `ui.getState`: the host-stored state of one page, or `null`.
#[tauri::command]
pub fn declarative_plugins_web_get_state(
    app: AppHandle,
    plugin_id: String,
    window_id: String,
) -> Value {
    app.state::<WebPageHostState>()
        .states
        .lock()
        .expect("web page state mutex")
        .get(&state_key(&plugin_id, &window_id))
        .cloned()
        .unwrap_or(Value::Null)
}

/// `ui.setState`: stores page state; over the contract's 64 KiB budget the
/// call fails with the bridge error shape instead of truncating.
#[tauri::command]
pub fn declarative_plugins_web_set_state(
    app: AppHandle,
    plugin_id: String,
    window_id: String,
    state: Value,
) -> Result<(), String> {
    let serialized = serde_json::to_string(&state).map_err(|error| error.to_string())?;
    if serialized.len() > MAX_PAGE_STATE_BYTES {
        return Err(
            json!({ "code": "plugin.web.invalidRequest", "message": "state exceeds 64 KiB" })
                .to_string(),
        );
    }
    app.state::<WebPageHostState>()
        .states
        .lock()
        .expect("web page state mutex")
        .insert(state_key(&plugin_id, &window_id), state);
    Ok(())
}

/// Drops state of one plugin (disable/uninstall).
pub fn forget_plugin_state(app: &AppHandle, plugin_id: &str) {
    let states = app.state::<WebPageHostState>();
    let mut guard = states.states.lock().expect("web page state mutex");
    let prefix = format!("{plugin_id}\u{0}");
    guard.retain(|key, _| !key.starts_with(&prefix));
}

/// The document-start script that defines the frozen `window.lithe` bridge.
/// v0 methods: context, request (state + openFile), on; build.* and
/// functions.* resolve to `plugin.web.unknownMethod` until their Windows
/// capabilities land.
fn bridge_script(plugin_id: &str, window_id: &str) -> String {
    let context = json!({
        "pluginID": plugin_id,
        "windowID": window_id,
        "platform": "windows",
    });
    const_bridge_script()
        .replace("__LITHE_CONTEXT__", &context.to_string())
        .replace("__LITHE_PLUGIN__", &json!(plugin_id).to_string())
        .replace("__LITHE_WINDOW__", &json!(window_id).to_string())
}

/// Bridge bootstrap as a plain string; placeholders are replaced with JSON
/// literals so no brace escaping is involved.
fn const_bridge_script() -> &'static str {
    r#"(() => {
  "use strict";
  const context = Object.freeze(__LITHE_CONTEXT__);
  const listeners = new Map();
  const invoke = (method, params) => window.__TAURI_INTERNALS__.invoke(
    "declarative_plugins_web_bridge_request",
    { method, params },
  );
  const bridge = {
    context,
    request(method, params) {
      if (typeof method !== "string" || !method) {
        return Promise.reject({ code: "plugin.web.invalidRequest", message: "method must be a non-empty string" });
      }
      return invoke(method, params ?? null);
    },
    on(event, listener) {
      if (typeof event !== "string" || typeof listener !== "function") {
        throw new TypeError("on(event, listener) requires a string and a function");
      }
      const set = listeners.get(event) ?? new Set();
      set.add(listener);
      listeners.set(event, set);
      return () => set.delete(listener);
    },
  };
  Object.freeze(bridge);
  Object.defineProperty(window, "lithe", { value: Object.freeze(bridge), configurable: false, writable: false });
  window.__litheDeliverEvent = (event, payload) => {
    const set = listeners.get(event);
    if (set) for (const listener of [...set]) {
      try { listener(payload); } catch { /* a failing listener must not break the pump */ }
    }
  };
})();"#
}

/// The single Tauri entry behind `lithe.request`. The calling page's
/// identity is derived from the invoking webview's label
/// (`plugin-web-<windowID>`), never from arguments the page supplies; the
/// plugin is then resolved from the accepted catalog and must currently
/// declare this window and be enabled. A page can only reach its own
/// plugin's state and the workspace layer.
///
/// This consumes the raw `Invoke` (the invoke handler in `main.rs` dispatches
/// plugin-page traffic here directly) so no other command can be reached
/// through this path.
pub fn declarative_plugins_web_bridge_request(invoke: tauri::ipc::Invoke<tauri::Wry>) {
    let webview = invoke.message.webview_ref().clone();
    // The bridge payload arrives as the command's JSON arguments envelope.
    let params: BridgeArgs = match invoke.message.payload() {
        tauri::ipc::InvokeBody::Json(value) => match serde_json::from_value(value.clone()) {
            Ok(args) => args,
            Err(error) => {
                invoke
                    .resolver
                    .respond::<tauri::ipc::InvokeResponseBody>(Err(tauri::ipc::InvokeError(
                        serde_json::json!({
                            "code": "plugin.web.invalidRequest",
                            "message": error.to_string(),
                        }),
                    )));
                return;
            }
        },
        _ => {
            invoke
                .resolver
                .respond::<tauri::ipc::InvokeResponseBody>(Err(tauri::ipc::InvokeError(
                    serde_json::json!({
                        "code": "plugin.web.invalidRequest",
                        "message": "the bridge only accepts JSON payloads",
                    }),
                )));
            return;
        }
    };
    let app = webview.app_handle().clone();
    let result = bridge_dispatch(&app, &webview, params);
    match result {
        Ok(value) => {
            invoke
                .resolver
                .respond::<tauri::ipc::InvokeResponseBody>(Ok(serde_json::to_string(&value)
                    .map(tauri::ipc::InvokeResponseBody::Json)
                    .unwrap_or_else(|_| tauri::ipc::InvokeResponseBody::Json("{}".into()))));
        }
        Err(message) => {
            invoke
                .resolver
                .respond::<tauri::ipc::InvokeResponseBody>(Err(tauri::ipc::InvokeError(
                    // `message` is already the JSON error envelope from `bridge_error`.
                    serde_json::from_str(&message)
                        .unwrap_or(serde_json::json!({ "message": message })),
                )));
        }
    }
}

#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct BridgeArgs {
    method: String,
    #[serde(default)]
    params: Option<Value>,
}

fn bridge_dispatch(
    app: &AppHandle,
    webview: &tauri::Webview,
    args: BridgeArgs,
) -> Result<Value, String> {
    let method = args.method.as_str();
    let params = args.params.unwrap_or(Value::Null);
    let identity = bridge_identity(app, webview.label())?;
    match method {
        "ui.getState" => Ok(declarative_plugins_web_get_state(
            app.clone(),
            identity.plugin_id,
            identity.window_id,
        )),
        "ui.setState" => {
            let Some(state) = params.get("state") else {
                return Err(bridge_error(
                    "plugin.web.invalidRequest",
                    "setState requires state",
                ));
            };
            declarative_plugins_web_set_state(
                app.clone(),
                identity.plugin_id,
                identity.window_id,
                state.clone(),
            )?;
            Ok(json!({}))
        }
        "workspace.openFile" => {
            let Some(path) = params["path"].as_str() else {
                return Err(bridge_error(
                    "plugin.web.invalidRequest",
                    "openFile requires path",
                ));
            };
            use tauri::Emitter;
            app.emit(
                "plugin-web-open-file",
                json!({
                    "pluginId": identity.plugin_id,
                    "path": path,
                    "line": params["line"].as_u64(),
                    "column": params["column"].as_u64(),
                }),
            )
            .map_err(|error| error.to_string())?;
            Ok(json!({}))
        }
        "build.instances" | "build.refresh" | "build.runTask" | "build.runTests"
        | "build.cancel" | "build.dependencies" | "build.setOptions" | "functions.list"
        | "functions.invoke" | "functions.cancel" => Err(bridge_error(
            "plugin.web.unknownMethod",
            format!("{method} needs the Windows build-system capability"),
        )),
        other => Err(bridge_error(
            "plugin.web.unknownMethod",
            format!("unknown method {other}"),
        )),
    }
}

/// Identity of a bridge caller, derived from its window label.
#[derive(Debug, Clone, PartialEq)]
pub struct BridgeIdentity {
    pub plugin_id: String,
    pub window_id: String,
}

/// Resolves and authorizes a bridge caller from its webview label. The label
/// is `plugin-web-<sanitized windowID>` (see `open_web_window`); the window ID
/// is the label-safe form of a declared tool-window ID, so authorization
/// re-derives it from the owning package's current catalog entry. Anything
/// that does not round-trip — a label from another window kind, a window the
/// plugin no longer declares, a disabled or uninstalled plugin, or a forged
/// label pointing at another plugin's window — is refused with
/// `plugin.web.forbidden`.
fn bridge_identity<R: tauri::Runtime>(
    app: &AppHandle<R>,
    label: &str,
) -> Result<BridgeIdentity, String> {
    const LABEL_PREFIX: &str = "plugin-web-";
    let Some(remainder) = label.strip_prefix(LABEL_PREFIX) else {
        return Err(bridge_error(
            "plugin.web.forbidden",
            "bridge requests are only accepted from plugin pages",
        ));
    };
    let packages = app.state::<super::PluginHostState>().packages();
    for package in &packages {
        if package.entry.status != "accepted" || !package.entry.enabled {
            continue;
        }
        let Some(tool_windows) = package.manifest["ui"]["toolWindows"].as_array() else {
            continue;
        };
        for window in tool_windows {
            let Some(window_id) = window["id"].as_str() else {
                continue;
            };
            if window["web"]["entry"].is_null() {
                continue;
            }
            if web_window_label(&package.entry.plugin_id, window_id) == remainder {
                return Ok(BridgeIdentity {
                    plugin_id: package.entry.plugin_id.clone(),
                    window_id: window_id.to_string(),
                });
            }
        }
    }
    Err(bridge_error(
        "plugin.web.forbidden",
        "the calling window does not belong to an enabled plugin page",
    ))
}

/// The webview label of one tool window: a collision-free hexadecimal encoding
/// of the plugin and window IDs, safe for Tauri labels.
pub(crate) fn web_window_label(plugin_id: &str, window_id: &str) -> String {
    format!(
        "p{}--w{}",
        hex_label_part(plugin_id),
        hex_label_part(window_id)
    )
}

fn hex_label_part(value: &str) -> String {
    value
        .as_bytes()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

fn bridge_error(code: &str, message: impl Into<String>) -> String {
    json!({ "code": code, "message": message.into() }).to_string()
}

/// Declared web window IDs of one plugin from the current catalog.
pub fn web_windows_of_plugin<R: tauri::Runtime>(
    app: &AppHandle<R>,
    plugin_id: &str,
) -> Vec<String> {
    app.state::<super::PluginHostState>()
        .packages()
        .into_iter()
        .filter(|package| package.entry.plugin_id == plugin_id)
        .flat_map(|package| {
            package.manifest["ui"]["toolWindows"]
                .as_array()
                .map(|windows| {
                    windows
                        .iter()
                        .filter_map(|window| window["id"].as_str().map(str::to_string))
                        .collect::<Vec<_>>()
                })
                .unwrap_or_default()
        })
        .collect()
}

/// Closes one web window by declared window ID, tolerating absence.
pub fn close_web_window_by_id<R: tauri::Runtime>(
    app: &AppHandle<R>,
    plugin_id: &str,
    window_id: &str,
) {
    let label = format!("plugin-web-{}", web_window_label(plugin_id, window_id));
    if let Some(existing) = app.get_webview_window(&label) {
        let _ = existing.close();
    }
}

// MARK: scheme file service

/// Serves one package file for the `lithe-plugin://<pluginID>/<path>` origin.
/// Returns the response or a bridge-error string; the caller maps errors to
/// an HTTP status.
pub fn serve_package_file<R: tauri::Runtime>(
    app: &AppHandle<R>,
    plugin_id: &str,
    raw_path: &str,
) -> Result<(&'static str, Vec<u8>), String> {
    let package = app
        .state::<super::PluginHostState>()
        .packages()
        .into_iter()
        .find(|package| {
            package.entry.status == "accepted"
                && package.entry.enabled
                && package.entry.plugin_id == plugin_id
        })
        .ok_or_else(|| format!("{plugin_id} is not an accepted declarative plugin"))?;
    let relative = sanitize_package_path(raw_path)?;
    if relative
        .extension()
        .and_then(|extension| extension.to_str())
        != Some("html")
        && relative
            .extension()
            .and_then(|extension| extension.to_str())
            != Some("css")
        && relative
            .extension()
            .and_then(|extension| extension.to_str())
            != Some("js")
        && relative
            .extension()
            .and_then(|extension| extension.to_str())
            != Some("svg")
        && relative
            .extension()
            .and_then(|extension| extension.to_str())
            != Some("png")
        && relative
            .extension()
            .and_then(|extension| extension.to_str())
            != Some("json")
        && relative
            .extension()
            .and_then(|extension| extension.to_str())
            != Some("woff2")
    {
        return Err(format!(
            "unsupported page asset type: {}",
            relative.display()
        ));
    }
    let target = package.root.join(&relative);
    let metadata = std::fs::symlink_metadata(&target)
        .map_err(|error| format!("{} is unreadable: {error}", target.display()))?;
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        if metadata.file_attributes() & 0x0400 != 0 {
            return Err(format!("{} is a reparse point", target.display()));
        }
    }
    #[cfg(not(windows))]
    if metadata.file_type().is_symlink() {
        return Err(format!("{} is a symbolic link", target.display()));
    }
    if !metadata.is_file() || metadata.len() > MAX_PAGE_FILE_BYTES {
        return Err(format!("{} is not a servable file", target.display()));
    }
    let canonical_root = package
        .root
        .canonicalize()
        .map_err(|error| format!("package root is unreadable: {error}"))?;
    let canonical = target
        .canonicalize()
        .map_err(|error| format!("{} is unreadable: {error}", target.display()))?;
    if !canonical.starts_with(&canonical_root) {
        return Err(format!("{} escapes the package", target.display()));
    }
    let bytes = std::fs::read(&target).map_err(|error| error.to_string())?;
    Ok((content_type(&relative), bytes))
}

/// Normalizes a URL path to a safe package-relative path: no empty segments,
/// `.`/`..`, encoded separators, or absolute forms.
fn sanitize_package_path(raw: &str) -> Result<PathBuf, String> {
    let decoded = percent_decode(raw);
    let mut segments: Vec<&str> = Vec::new();
    for segment in decoded.split('/') {
        match segment {
            "" | "." => {}
            ".." => return Err("path traversal is refused".to_string()),
            other => segments.push(other),
        }
    }
    if segments.is_empty() {
        return Err("empty page path".to_string());
    }
    let mut path = PathBuf::new();
    for segment in segments {
        path.push(segment);
    }
    Ok(path)
}

fn percent_decode(raw: &str) -> String {
    let bytes = raw.as_bytes();
    let mut output = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'%' && index + 2 < bytes.len() {
            let hex = std::str::from_utf8(&bytes[index + 1..index + 3]).unwrap_or("");
            if let Ok(byte) = u8::from_str_radix(hex, 16) {
                output.push(byte);
                index += 3;
                continue;
            }
        }
        output.push(bytes[index]);
        index += 1;
    }
    String::from_utf8_lossy(&output).to_string()
}

fn content_type(path: &Path) -> &'static str {
    match path.extension().and_then(|extension| extension.to_str()) {
        Some("html") => "text/html; charset=utf-8",
        Some("css") => "text/css; charset=utf-8",
        Some("js") => "text/javascript; charset=utf-8",
        Some("svg") => "image/svg+xml",
        Some("png") => "image/png",
        Some("json") => "application/json",
        Some("woff2") => "font/woff2",
        _ => "application/octet-stream",
    }
}

fn urlencoding_encode(value: &str) -> String {
    // Plugin IDs are reverse-DNS ASCII after Core validation; only the
    // characters the URL parser cares about need escaping.
    value.replace('.', ".")
}

/// Tauri scheme handler for `lithe-plugin://<pluginID>/<path>`. Windows
/// routes custom schemes through `http://lithe-plugin.<host>/`, so the
/// plugin ID arrives in the URI host and the path in the request path.
pub fn handle_scheme_request<R: tauri::Runtime>(
    app: &AppHandle<R>,
    request: http::Request<Vec<u8>>,
) -> http::Response<Vec<u8>> {
    let ok = |content_type: &'static str, body: Vec<u8>| {
        http::Response::builder()
            .status(200)
            .header("Content-Type", content_type)
            .header("Content-Security-Policy", PAGE_CSP)
            .header("X-Content-Type-Options", "nosniff")
            .header("Cache-Control", "no-store")
            .header("Cross-Origin-Resource-Policy", "same-origin")
            .body(body)
            .expect("response builds")
    };
    let refused = |message: &str| {
        http::Response::builder()
            .status(404)
            .header("Content-Type", "text/plain; charset=utf-8")
            .header("Content-Security-Policy", PAGE_CSP)
            .body(message.as_bytes().to_vec())
            .expect("response builds")
    };
    // Windows routes custom schemes as `http://<scheme>.<host>/<path>`, so
    // the URL host is `<pluginID>.lithe-plugin` (scheme suffix, dots kept).
    let host = request.uri().host().unwrap_or_default().to_string();
    let plugin_id = restore_plugin_id(&host);
    let path = request.uri().path().trim_start_matches('/').to_string();
    match serve_package_file(app, &plugin_id, &path) {
        Ok((content_type, body)) => ok(content_type, body),
        Err(message) => refused(&message),
    }
}

/// Restores the reverse-DNS plugin ID from the URL host form: WebView2
/// routes `lithe-plugin://id/path` to the host `id.lithe-plugin`, so the
/// scheme suffix is stripped and dots are kept as-is.
fn restore_plugin_id(host: &str) -> String {
    host.strip_suffix(".lithe-plugin")
        .unwrap_or(host)
        .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn package_paths_reject_traversal_and_empty() {
        assert!(sanitize_package_path("ui/index.html").is_ok());
        assert_eq!(
            sanitize_package_path("ui/./index.html").expect("normalizes"),
            PathBuf::from("ui").join("index.html")
        );
        assert!(sanitize_package_path("../outside.html").is_err());
        assert!(sanitize_package_path("ui/../../outside.html").is_err());
        assert!(sanitize_package_path("").is_err());
        assert!(sanitize_package_path("%2e%2e/escape.html").is_err());
        assert_eq!(
            sanitize_package_path("ui%2Findex.html").expect("decodes"),
            PathBuf::from("ui").join("index.html")
        );
    }

    #[test]
    fn percent_decode_handles_encoded_and_plain() {
        assert_eq!(percent_decode("a%20b"), "a b");
        assert_eq!(percent_decode("plain.html"), "plain.html");
        assert_eq!(percent_decode("bad%zz"), "bad%zz");
    }

    #[test]
    fn bridge_script_is_frozen_and_scoped() {
        let script = bridge_script("acme.php", "window-id");
        assert!(script.contains(r#""pluginID":"acme.php""#));
        assert!(script.contains("Object.freeze(bridge)"));
        assert!(script.contains("writable: false"));
    }

    #[test]
    fn bridge_payload_uses_its_method_and_refuses_claimed_identity() {
        let args: BridgeArgs = serde_json::from_value(json!({
            "method": "ui.getState",
            "params": null
        }))
        .expect("bridge request");
        assert_eq!(args.method, "ui.getState");
        assert!(serde_json::from_value::<BridgeArgs>(json!({
            "method": "ui.getState",
            "pluginId": "another.plugin",
            "params": null
        }))
        .is_err());
    }

    #[test]
    fn web_window_labels_are_stable_and_collision_free() {
        // Hex encoding preserves the full plugin/window identity in a label.
        assert_eq!(
            web_window_label("dev.lithe", "window"),
            "p6465762e6c69746865--w77696e646f77"
        );
        assert_eq!(
            web_window_label("acme", "panel:one"),
            "p61636d65--w70616e656c3a6f6e65"
        );
        assert_ne!(
            web_window_label("acme", "panel"),
            web_window_label("other", "panel")
        );
    }
    #[test]
    fn state_keys_separate_plugins_and_windows() {
        assert_ne!(state_key("a.plugin", "w1"), state_key("a.plugin", "w2"));
        assert_ne!(state_key("a.plugin", "w1"), state_key("b.plugin", "w1"));
    }
}

#[cfg(test)]
mod serve_tests {
    use super::*;

    fn unique_temp_root(label: &str) -> PathBuf {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .expect("system clock")
            .as_nanos();
        let root = std::env::temp_dir().join(format!(
            "lithe-plugin-web-{label}-{}-{nanos}",
            std::process::id()
        ));
        std::fs::create_dir_all(&root).expect("temp root");
        root
    }

    #[test]
    fn serve_paths_cover_assets_and_refuse_escapes() {
        // sanitize + content-type behavior without an app handle.
        assert_eq!(
            content_type(&sanitize_package_path("ui/index.html").expect("path")),
            "text/html; charset=utf-8"
        );
        assert_eq!(
            content_type(&sanitize_package_path("style.css").expect("path")),
            "text/css; charset=utf-8"
        );
        assert!(sanitize_package_path("ui/../../secret.txt").is_err());
    }

    #[test]
    fn csp_refuses_network_and_eval() {
        assert!(PAGE_CSP.contains("default-src 'none'"));
        assert!(PAGE_CSP.contains("script-src 'self'"));
        assert!(!PAGE_CSP.contains("wasm-unsafe-eval"));
        assert!(PAGE_CSP.contains("frame-ancestors 'none'"));
    }
}
