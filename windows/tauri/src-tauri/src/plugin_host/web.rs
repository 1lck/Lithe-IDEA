//! Web tool windows (ui capability 2): package pages in a WebView2 shell.
//!
//! The contract rules (shared/contracts/plugins/v1/README.md, "Web content
//! (ui 2)") put the security boundary in the file service: only files of the
//! owning installed package are served, read-only, from a plugin-private
//! origin, with a CSP that refuses network access, remote resources, frames,
//! inline scripts and eval. The window shell (dock, title, order, lifecycle)
//! is host-owned; the page fills the body only. The build submodule routes
//! instance reads, option edits and approved build operations through the owning workbench.

use super::scan::ScannedPackage;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::{BTreeMap, HashMap};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use tauri::{AppHandle, Manager, WebviewUrl, WebviewWindowBuilder};

#[path = "web_build.rs"]
pub mod build;

#[cfg(windows)]
#[path = "web_network.rs"]
mod network;

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
/// Reserved same-origin host script, served before any package-authored code.
const HOST_BRIDGE_PATH: &str = "__lithe_host__/bridge.js";

#[derive(Default)]
pub struct WebPageHostState {
    states: Mutex<HashMap<String, Value>>,
    owners: Mutex<HashMap<String, PageOwner>>,
    workspace_generations: Mutex<HashMap<String, u64>>,
    open_files: Mutex<HashMap<String, PendingOpenFile>>,
    appearances: Mutex<HashMap<String, WebPageAppearance>>,
    builds: build::BuildRequests,
}

struct PendingOpenFile {
    host_label: String,
    page_label: String,
    completion: tokio::sync::oneshot::Sender<Result<(), String>>,
}

#[derive(Clone, Debug, PartialEq)]
struct PageOwner {
    generation: u64,
    workspace_generation: u64,
    host_label: String,
    workspace_id: String,
    workspace_path: String,
    plugin_id: String,
    window_id: String,
    state_id: String,
}

static OPEN_PAGE_SEQUENCE: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);

fn workspace_generation(state: &WebPageHostState, host: &str, workspace: &str) -> u64 {
    state
        .workspace_generations
        .lock()
        .expect("workspace page generations")
        .get(&workspace_label_suffix(host, workspace))
        .copied()
        .unwrap_or(0)
}

/// Effects and revocation share the owners lock. A request cloned before
/// close cannot recreate state or register an event after authority is gone.
fn with_page_owner<T>(
    state: &WebPageHostState,
    label: &str,
    identity: &BridgeIdentity,
    effect: impl FnOnce() -> Result<T, String>,
) -> Result<T, String> {
    let owners = state.owners.lock().expect("page owners");
    if !owners.get(label).is_some_and(|owner| {
        owner.generation == identity.generation
            && owner.workspace_generation == identity.workspace_generation
            && owner.plugin_id == identity.plugin_id
            && owner.window_id == identity.window_id
            && owner.host_label == identity.host_label
            && owner.workspace_id == identity.workspace_id
            && owner.workspace_path == identity.workspace_path
            && owner.state_id == identity.state_id
            && owned_label(owner) == label
            && owner.workspace_generation
                == workspace_generation(state, &owner.host_label, &owner.workspace_id)
    }) {
        return Err(bridge_error(
            "plugin.web.forbidden",
            "page ownership was revoked",
        ));
    }
    effect()
}

fn revoke_owners(
    state: &WebPageHostState,
    matches: impl Fn(&PageOwner) -> bool,
    clear_state: bool,
) -> Vec<String> {
    let mut owners = state.owners.lock().expect("page owners");
    let labels: Vec<_> = owners
        .iter()
        .filter(|(_, owner)| matches(owner))
        .map(|(label, _)| label.clone())
        .collect();
    owners.retain(|label, _| !labels.contains(label));
    state.builds.revoke_pages(&labels);
    state
        .open_files
        .lock()
        .expect("open file requests")
        .retain(|_, request| !labels.contains(&request.page_label));
    state
        .appearances
        .lock()
        .expect("page appearances")
        .retain(|label, _| !labels.contains(label));
    if clear_state {
        state
            .states
            .lock()
            .expect("page state")
            .retain(|key, _| !labels.iter().any(|label| key.ends_with(label)));
    }
    labels
}

/// A new document retains page state but loses every old request's authority.
fn navigate_page(state: &WebPageHostState, label: &str) {
    let mut owners = state.owners.lock().expect("page owners");
    if let Some(owner) = owners.get_mut(label) {
        owner.generation = OPEN_PAGE_SEQUENCE.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        state.builds.revoke_pages(&[label.to_string()]);
        state
            .open_files
            .lock()
            .expect("open file requests")
            .retain(|_, request| request.page_label != label);
    }
}

fn workspace_label_suffix(host_label: &str, workspace_id: &str) -> String {
    format!(
        "--h{}--s{}",
        hex_label_part(host_label),
        hex_label_part(workspace_id)
    )
}

fn owned_label(owner: &PageOwner) -> String {
    format!(
        "plugin-web-{}{}",
        web_window_label(&owner.plugin_id, &owner.window_id),
        workspace_label_suffix(&owner.host_label, &owner.workspace_id)
    )
}

/// Resolved workbench locale and theme tokens; supplied only by host windows.
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WebPageAppearance {
    pub locale: String,
    pub theme: String,
    pub variables: BTreeMap<String, String>,
}

/// Checks the real document origin, including WebView2's custom-scheme mapping.
/// Navigation and IPC share this predicate so a window label alone grants nothing.
fn is_package_url(url: &url::Url, plugin_id: &str) -> bool {
    if !url.username().is_empty() || url.password().is_some() || url.port().is_some() {
        return false;
    }
    let private_origin = url.scheme() == "lithe-plugin" && url.host_str() == Some(plugin_id);
    let mapped_origin = cfg!(windows)
        && url.scheme() == "http"
        && url.host_str() == Some(format!("lithe-plugin.{plugin_id}").as_str());
    (private_origin || mapped_origin) && sanitize_package_path(url.path()).is_ok()
}

fn require_package_url(url: &url::Url, plugin_id: &str) -> Result<(), String> {
    if is_package_url(url, plugin_id) {
        Ok(())
    } else {
        Err(bridge_error(
            "plugin.web.forbidden",
            "the document is outside its plugin package",
        ))
    }
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
        if package.entry.status != "accepted"
            || !package.entry.enabled
            || app
                .state::<super::lifecycle::LifecycleState>()
                .blocked(&package.entry.plugin_id)
        {
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
        let entry = match window["web"]["entry"].as_str() {
            Some(entry) => entry.to_string(),
            None if window["text"].is_string() => format!(
                "__lithe_host__/text/{}.html",
                hex_label_part(window["id"].as_str().unwrap_or_default())
            ),
            _ => continue,
        };
        windows.push(WebToolWindow {
            window_id: window["id"].as_str().unwrap_or_default().to_string(),
            plugin_id: package.entry.plugin_id.clone(),
            title: window["title"].as_str().unwrap_or_default().to_string(),
            placement: window["placement"].as_str().unwrap_or("bottom").to_string(),
            order: window["order"].as_u64().map(|order| order as u32),
            entry,
        });
    }
}

/// Opens (or focuses) the web view of one tool window. The URL is the
/// plugin-private scheme origin with the declared entry path.
#[tauri::command]
pub async fn declarative_plugins_open_web_window(
    app: AppHandle,
    caller: tauri::WebviewWindow,
    plugin_id: String,
    window_id: String,
    workspace_id: String,
    workspace_path: String,
    appearance: WebPageAppearance,
) -> Result<(), String> {
    if workspace_id.is_empty()
        || workspace_path.is_empty()
        || app
            .state::<super::lifecycle::LifecycleState>()
            .blocked(&plugin_id)
    {
        return Err("plugin page requires an active workspace and package".into());
    }
    // Register the whole asynchronous creation, not just resource reads.
    // Mutation waits for this lease before collecting and closing owners.
    let _native_page = app
        .state::<super::lifecycle::LifecycleState>()
        .acquire(&plugin_id)?;
    let owner = PageOwner {
        generation: OPEN_PAGE_SEQUENCE.fetch_add(1, std::sync::atomic::Ordering::Relaxed),
        workspace_generation: workspace_generation(
            &app.state::<WebPageHostState>(),
            caller.label(),
            &workspace_id,
        ),
        host_label: caller.label().into(),
        workspace_id,
        workspace_path,
        plugin_id: plugin_id.clone(),
        window_id: window_id.clone(),
        state_id: String::new(),
    };
    let label = owned_label(&owner);
    let owner = PageOwner {
        state_id: label.clone(),
        ..owner
    };
    let Some(window) = declarative_plugins_web_windows(app.clone())
        .into_iter()
        .find(|window| window.plugin_id == plugin_id && window.window_id == window_id)
    else {
        return Err(format!(
            "{plugin_id}/{window_id} is not a declared web tool window"
        ));
    };
    {
        let state = app.state::<WebPageHostState>();
        let mut owners = state.owners.lock().expect("page owners");
        state.builds.revoke_pages(&[label.clone()]);
        state
            .open_files
            .lock()
            .expect("open file requests")
            .retain(|_, request| request.page_label != label);
        owners.insert(label.clone(), owner);
    }
    app.state::<WebPageHostState>()
        .appearances
        .lock()
        .expect("appearance mutex")
        .insert(label.clone(), appearance.clone());
    if let Some(existing) = app.get_webview_window(&label) {
        let _ = existing.set_focus();
        return Ok(());
    }
    let target_url = package_page_url(&window.plugin_id, &window.entry)?;
    let request_plugin_id = window.plugin_id.clone();
    let plugin_id = window.plugin_id.clone();
    let navigation_app = app.clone();
    let navigation_label = label.clone();
    // Start inert. The request filter must be installed before package code
    // can navigate or otherwise cause an outbound request.
    let view = WebviewWindowBuilder::new(
        &app,
        &label,
        WebviewUrl::External("about:blank".parse().expect("blank URL")),
    )
    .title(window.title)
    .incognito(true)
    .on_navigation(move |url| {
        let allowed = is_package_url(url, &plugin_id);
        if allowed {
            navigate_page(
                &navigation_app.state::<WebPageHostState>(),
                &navigation_label,
            );
        }
        allowed
    })
    .on_new_window(|_, _| tauri::webview::NewWindowResponse::Deny)
    .on_download(|_, _| false)
    .build()
    .map_err(|error| format!("web window could not open: {error}"))?;
    let setup: Result<(), String> = async {
        #[cfg(windows)]
        network::restrict_requests(&view, request_plugin_id).await?;
        bridge_identity(&app, &label)?;
        view.navigate(target_url).map_err(|error| error.to_string())
    }
    .await;
    if let Err(error) = setup {
        forget_window_appearance(&app, &label);
        if let Err(close_error) = view.close() {
            return Err(format!(
                "{error}; failed to close the inactive page: {close_error}"
            ));
        }
        return Err(error);
    }
    Ok(())
}

fn package_page_url(plugin_id: &str, entry: &str) -> Result<url::Url, String> {
    // Wry maps custom schemes only at creation. A later navigate() reaches
    // WebView2 directly, so it must use the same mapped origin explicitly.
    #[cfg(windows)]
    let url = format!("http://lithe-plugin.{plugin_id}/{entry}");
    #[cfg(not(windows))]
    let url = format!("lithe-plugin://{plugin_id}/{entry}");
    url.parse()
        .map_err(|error: url::ParseError| error.to_string())
}

fn appearance_script(appearance: &WebPageAppearance) -> String {
    format!(
        "window.__litheDeliverEvent?.('ui.themeChanged', {});",
        json!(appearance)
    )
}

/// Applies a workbench change to existing pages and their next reload.
#[tauri::command]
pub fn declarative_plugins_web_update_appearance(
    app: AppHandle,
    caller: tauri::WebviewWindow,
    appearance: WebPageAppearance,
) -> Result<(), String> {
    let windows: Vec<_> = app
        .webview_windows()
        .into_iter()
        .filter(|(label, _)| {
            app.state::<WebPageHostState>()
                .owners
                .lock()
                .expect("page owners")
                .get(label)
                .is_some_and(|owner| owner.host_label == caller.label())
        })
        .collect();
    {
        let state = app.state::<WebPageHostState>();
        let mut appearances = state.appearances.lock().expect("appearance mutex");
        for (label, _) in &windows {
            appearances.insert(label.clone(), appearance.clone());
        }
    }
    let mut failures = Vec::new();
    for (label, window) in windows {
        if let Err(error) = window.eval(appearance_script(&appearance)) {
            failures.push(format!("{label}: {error}"));
        }
    }
    if failures.is_empty() {
        Ok(())
    } else {
        Err(failures.join("; "))
    }
}

/// Native window destruction releases its cached appearance, including X-close.
pub fn forget_window_appearance<R: tauri::Runtime>(app: &AppHandle<R>, label: &str) {
    let state = app.state::<WebPageHostState>();
    let children = revoke_owners(
        &state,
        |owner| owner.host_label == label || owned_label(owner) == label,
        !label.starts_with("plugin-web-"),
    );
    let host_prefix = format!("--h{}--s", hex_label_part(label));
    state
        .states
        .lock()
        .expect("page state")
        .retain(|key, _| !key.contains(&host_prefix));
    state
        .workspace_generations
        .lock()
        .expect("workspace page generations")
        .retain(|scope, _| !scope.starts_with(&host_prefix));
    for child in children {
        if child != label {
            if let Some(view) = app.get_webview_window(&child) {
                let _ = view.close();
            }
        }
    }
}

/// Destroys the web view of one tool window; used on plugin disable,
/// uninstall, and window teardown.
#[tauri::command]
pub fn declarative_plugins_close_web_window(
    app: AppHandle,
    caller: tauri::WebviewWindow,
    workspace_id: String,
    plugin_id: String,
    window_id: String,
) -> Result<(), String> {
    let label = owned_label(&PageOwner {
        generation: 0,
        workspace_generation: 0,
        host_label: caller.label().into(),
        workspace_id,
        workspace_path: String::new(),
        plugin_id,
        window_id,
        state_id: String::new(),
    });
    // Hide/close preserves saved page state, but revokes pending effects
    // before the asynchronous native destruction event can arrive.
    revoke_owners(
        &app.state::<WebPageHostState>(),
        |owner| owned_label(owner) == label,
        false,
    );
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

/// The first parser-blocking script defines the frozen `window.lithe` bridge.
/// Build requests remain page-owned and require the workbench's native approval.
fn bridge_script(
    plugin_id: &str,
    window_id: &str,
    appearance: &WebPageAppearance,
    generation: u64,
) -> String {
    let context = json!({
        "pluginID": plugin_id,
        "windowID": window_id,
        "platform": "windows",
        "locale": appearance.locale,
    });
    const_bridge_script()
        .replace("__LITHE_CONTEXT__", &context.to_string())
        .replace("__LITHE_APPEARANCE__", &json!(appearance).to_string())
        .replace("__LITHE_PLUGIN__", &json!(plugin_id).to_string())
        .replace("__LITHE_WINDOW__", &json!(window_id).to_string())
        .replace("__LITHE_PAGE_GENERATION__", &generation.to_string())
}

/// Bridge bootstrap as a plain string; placeholders are replaced with JSON
/// literals so no brace escaping is involved.
fn const_bridge_script() -> &'static str {
    r#"(() => {
  "use strict";
  const initial = __LITHE_CONTEXT__;
  Object.defineProperty(window, '__lithePageGeneration', {value: __LITHE_PAGE_GENERATION__, writable:false});
  // Never expose a bridge in another document, even if native navigation
  // policy regresses or a page fetches this reserved script explicitly.
  const url = new URL(window.location.href);
  if (window !== window.top || url.username || url.password || url.port ||
      !((url.protocol === 'lithe-plugin:' && url.hostname === initial.pluginID) ||
        (url.protocol === 'http:' && url.hostname === 'lithe-plugin.' + initial.pluginID))) return;
  let appearance = __LITHE_APPEARANCE__;
  const context = Object.freeze({ ...initial,
    get locale() { return appearance.locale; },
    get theme() { return appearance.theme; },
  });
  const applyTheme = () => {
    const root = document.documentElement;
    if (!root) { document.addEventListener('readystatechange', applyTheme, { once: true }); return; }
    root.setAttribute('data-theme', appearance.theme);
    root.lang = appearance.locale;
    for (const [name, value] of Object.entries(appearance.variables)) root.style.setProperty(name, value);
  };
  const listeners = new Map();
  const invoke = (method, params) => window.__TAURI_INTERNALS__.invoke(
    "plugin:declarative-web|request",
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
    if (event === 'ui.themeChanged') {
      appearance = payload;
      applyTheme();
      payload = { theme: appearance.theme };
    }
    const set = listeners.get(event);
    if (set) for (const listener of [...set]) {
      try { listener(payload); } catch { /* a failing listener must not break the pump */ }
    }
  };
  applyTheme();
})();"#
}

/// Minimal Tauri plugin namespace so custom-protocol pages can receive one
/// ACL-granted command without changing the main application's command ACL.
pub fn bridge_plugin() -> tauri::plugin::TauriPlugin<tauri::Wry> {
    tauri::plugin::Builder::new("declarative-web")
        .invoke_handler(|invoke| {
            if invoke.message.command() != "request" {
                return false;
            }
            handle_bridge_request(invoke);
            true
        })
        .build()
}

/// The single Tauri entry behind `lithe.request`. The calling page's
/// identity is derived from the invoking webview's label
/// (`plugin-web-<windowID>`), never from arguments the page supplies; the
/// plugin is then resolved from the accepted catalog and must currently
/// declare this window and be enabled. A page can only reach its own
/// plugin's state and the workspace layer.
///
/// The inlined plugin's ACL admits only this request, and this handler then
/// enforces document and package identity before dispatching any method.
fn handle_bridge_request(invoke: tauri::ipc::Invoke<tauri::Wry>) {
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
    tauri::async_runtime::spawn(async move {
        let result = bridge_dispatch(&app, &webview, params).await;
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
    });
}

#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct BridgeArgs {
    method: String,
    #[serde(default)]
    params: Option<Value>,
}

async fn bridge_dispatch(
    app: &AppHandle,
    webview: &tauri::Webview,
    args: BridgeArgs,
) -> Result<Value, String> {
    let method = args.method.as_str();
    let params = args.params.unwrap_or(Value::Null);
    let identity = bridge_identity(app, webview.label())?;
    let url = webview
        .url()
        .map_err(|error| bridge_error("plugin.web.forbidden", error.to_string()))?;
    require_package_url(&url, &identity.plugin_id)?;
    match method {
        "ui.getState" => with_page_owner(
            &app.state::<WebPageHostState>(),
            webview.label(),
            &identity,
            || {
                Ok(json!({
                    "state": declarative_plugins_web_get_state(app.clone(), identity.plugin_id.clone(), identity.state_id.clone())
                }))
            },
        ),
        "ui.setState" => {
            let state = params.get("state").ok_or_else(|| {
                bridge_error("plugin.web.invalidRequest", "setState requires state")
            })?;
            with_page_owner(
                &app.state::<WebPageHostState>(),
                webview.label(),
                &identity,
                || {
                    declarative_plugins_web_set_state(
                        app.clone(),
                        identity.plugin_id.clone(),
                        identity.state_id.clone(),
                        state.clone(),
                    )?;
                    Ok(json!({}))
                },
            )
        }
        "workspace.openFile" => {
            let Some(path) = params["path"].as_str() else {
                return Err(bridge_error(
                    "plugin.web.invalidRequest",
                    "openFile requires path",
                ));
            };
            use tauri::Emitter;
            let operation_id = format!(
                "{}-{}",
                webview.label(),
                OPEN_FILE_SEQUENCE.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
            );
            let (sender, receiver) = tokio::sync::oneshot::channel();
            let pending = OpenFileRequest {
                app: app.clone(),
                operation_id: operation_id.clone(),
            };
            with_page_owner(
                &app.state::<WebPageHostState>(),
                webview.label(),
                &identity,
                || {
                    let state = app.state::<WebPageHostState>();
                    let mut requests = state.open_files.lock().expect("open file requests");
                    if requests.len() >= 128 {
                        return Err(bridge_error(
                            "plugin.web.invalidRequest",
                            "too many pending file open requests",
                        ));
                    }
                    requests.insert(
                        operation_id.clone(),
                        PendingOpenFile {
                            host_label: identity.host_label.clone(),
                            page_label: webview.label().into(),
                            completion: sender,
                        },
                    );
                    drop(requests);
                    app.emit_to(
                        &identity.host_label,
                        "plugin-web-open-file",
                        json!({
                            "pluginId": identity.plugin_id,
                            "operationId": operation_id,
                            "workspaceId": identity.workspace_id,
                            "workspacePath": identity.workspace_path,
                            "path": path,
                            "line": params["line"].as_u64(),
                            "column": params["column"].as_u64(),
                        }),
                    )
                    .map_err(|error| error.to_string())
                },
            )?;
            tokio::time::timeout(std::time::Duration::from_secs(10), receiver)
                .await
                .map_err(|_| {
                    bridge_error(
                        "plugin.web.openFileFailed",
                        "file open acknowledgement timed out",
                    )
                })?
                .map_err(|_| bridge_error("plugin.web.forbidden", "page was closed"))?
                .map_err(|error| bridge_error("plugin.web.openFileFailed", error))?;
            drop(pending);
            with_page_owner(
                &app.state::<WebPageHostState>(),
                webview.label(),
                &identity,
                || Ok(json!({})),
            )
        }
        "build.instances" | "build.setOptions" | "build.refresh" | "build.runTask"
        | "build.runTests" | "build.cancel" | "build.dependencies" => {
            build::request(app, webview.label(), identity, method, params).await
        }
        "functions.list" | "functions.invoke" | "functions.cancel" => Err(bridge_error(
            "plugin.web.unknownMethod",
            format!("{method} needs the Windows build-system capability"),
        )),
        other => Err(bridge_error(
            "plugin.web.unknownMethod",
            format!("unknown method {other}"),
        )),
    }
}

static OPEN_FILE_SEQUENCE: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);
struct OpenFileRequest {
    app: AppHandle,
    operation_id: String,
}
impl Drop for OpenFileRequest {
    fn drop(&mut self) {
        self.app
            .state::<WebPageHostState>()
            .open_files
            .lock()
            .expect("open file requests")
            .remove(&self.operation_id);
    }
}

#[tauri::command]
pub fn declarative_plugins_web_open_file_ack(
    app: AppHandle,
    caller: tauri::WebviewWindow,
    operation_id: String,
    error: Option<String>,
) -> Result<(), String> {
    let state = app.state::<WebPageHostState>();
    let mut pending = state.open_files.lock().expect("open file requests");
    if !pending
        .get(&operation_id)
        .is_some_and(|request| request.host_label == caller.label())
    {
        return Err("file request does not belong to this product window".into());
    }
    if let Some(request) = pending.remove(&operation_id) {
        let _ = request.completion.send(error.map_or(Ok(()), Err));
    }
    Ok(())
}

/// Identity of a bridge caller, derived from its window label.
#[derive(Debug, Clone, PartialEq)]
pub struct BridgeIdentity {
    pub generation: u64,
    pub workspace_generation: u64,
    pub plugin_id: String,
    pub window_id: String,
    pub host_label: String,
    pub workspace_id: String,
    pub workspace_path: String,
    pub state_id: String,
}

/// Resolves and authorizes a bridge caller from its webview label. The label
/// includes a collision-free encoding of plugin and window IDs; authorization
/// re-derives it from the owning package's current catalog entry. Anything
/// that does not round-trip — a label from another window kind, a window the
/// plugin no longer declares, a disabled or uninstalled plugin, or a forged
/// label pointing at another plugin's window — is refused with
/// `plugin.web.forbidden`.
fn bridge_identity<R: tauri::Runtime>(
    app: &AppHandle<R>,
    label: &str,
) -> Result<BridgeIdentity, String> {
    let owner = app
        .state::<WebPageHostState>()
        .owners
        .lock()
        .expect("page owners")
        .get(label)
        .cloned()
        .ok_or_else(|| bridge_error("plugin.web.forbidden", "page ownership was revoked"))?;
    if owner.workspace_generation
        != workspace_generation(
            &app.state::<WebPageHostState>(),
            &owner.host_label,
            &owner.workspace_id,
        )
        || owned_label(&owner) != label
        || app.get_webview_window(&owner.host_label).is_none()
        || app
            .state::<super::lifecycle::LifecycleState>()
            .blocked(&owner.plugin_id)
    {
        return Err(bridge_error(
            "plugin.web.forbidden",
            "page owner is inactive",
        ));
    }
    let declared = declarative_windows_for(app)
        .into_iter()
        .any(|window| window.plugin_id == owner.plugin_id && window.window_id == owner.window_id);
    if !declared {
        return Err(bridge_error(
            "plugin.web.forbidden",
            "package no longer declares this page",
        ));
    }
    Ok(BridgeIdentity {
        generation: owner.generation,
        workspace_generation: owner.workspace_generation,
        plugin_id: owner.plugin_id,
        window_id: owner.window_id,
        host_label: owner.host_label,
        workspace_id: owner.workspace_id,
        workspace_path: owner.workspace_path,
        state_id: owner.state_id,
    })
}

fn declarative_windows_for<R: tauri::Runtime>(app: &AppHandle<R>) -> Vec<WebToolWindow> {
    let mut windows = Vec::new();
    for package in app.state::<super::PluginHostState>().packages() {
        if package.entry.status == "accepted" && package.entry.enabled {
            collect_web_windows(&package, &mut windows);
        }
    }
    windows
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

/// Resolves symlinks/junctions before the workspace file-open entry can read.
/// Returning the canonical target also avoids re-resolving the original link
/// using stale file-tree metadata in `handleFileSelect`.
#[tauri::command]
pub fn declarative_plugins_web_resolve_file(
    workspace_path: PathBuf,
    path: PathBuf,
) -> Result<String, String> {
    let root = workspace_path.canonicalize().map_err(|error| {
        bridge_error(
            "plugin.web.forbidden",
            format!("workspace is unreadable: {error}"),
        )
    })?;
    let target = if path.is_absolute() {
        path
    } else {
        root.join(path)
    };
    let target = target.canonicalize().map_err(|error| {
        bridge_error(
            "plugin.web.forbidden",
            format!("file is unreadable: {error}"),
        )
    })?;
    if target == root || !target.starts_with(&root) || !target.is_file() {
        return Err(bridge_error(
            "plugin.web.forbidden",
            "the file is outside the workspace",
        ));
    }
    let path = target.to_string_lossy().replace('\\', "/");
    // Keep the editor's conventional drive/UNC spelling after canonicalize.
    Ok(if let Some(unc) = path.strip_prefix("//?/UNC/") {
        format!("//{unc}")
    } else {
        path.strip_prefix("//?/").unwrap_or(&path).to_string()
    })
}

/// Revoke bridge access before closing; close failures stop package mutation.
pub fn close_plugin_windows(app: &AppHandle, plugin_id: &str) -> Result<(), String> {
    close_owned_pages(app, |owner| owner.plugin_id == plugin_id)?;
    forget_plugin_state(app, plugin_id);
    Ok(())
}

fn close_owned_pages(app: &AppHandle, matches: impl Fn(&PageOwner) -> bool) -> Result<(), String> {
    let labels = revoke_owners(&app.state::<WebPageHostState>(), matches, true);
    let mut failures = Vec::new();
    for label in labels {
        if let Some(view) = app.get_webview_window(&label) {
            if let Err(error) = view.close() {
                failures.push(error.to_string());
            }
        }
    }
    if failures.is_empty() {
        Ok(())
    } else {
        Err(failures.join("; "))
    }
}

#[tauri::command]
pub fn declarative_plugins_close_workspace_pages(
    app: AppHandle,
    caller: tauri::WebviewWindow,
    workspace_id: String,
) -> Result<(), String> {
    let scope = workspace_label_suffix(caller.label(), &workspace_id);
    {
        let state = app.state::<WebPageHostState>();
        let mut generations = state
            .workspace_generations
            .lock()
            .expect("workspace page generations");
        *generations.entry(scope).or_default() += 1;
    }
    close_owned_pages(&app, |owner| {
        owner.host_label == caller.label() && owner.workspace_id == workspace_id
    })?;
    let suffix = workspace_label_suffix(caller.label(), &workspace_id);
    app.state::<WebPageHostState>()
        .states
        .lock()
        .expect("page state")
        .retain(|key, _| !key.ends_with(&suffix));
    Ok(())
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

/// Tauri scheme handler for `lithe-plugin://<pluginID>/<path>`. Wry restores
/// the original URI before delivery; its context supplies the trusted label.
pub fn handle_scheme_request<R: tauri::Runtime>(
    app: &AppHandle<R>,
    webview_label: &str,
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
    // Wry restores `http://lithe-plugin.<pluginID>/...` to the original
    // `lithe-plugin://<pluginID>/...` before invoking this scheme handler.
    let plugin_id = request.uri().host().unwrap_or_default();
    let _native_read = match app
        .state::<super::lifecycle::LifecycleState>()
        .acquire(plugin_id)
    {
        Ok(lease) => lease,
        Err(_) => return refused("plugin package is changing"),
    };
    let identity = match bridge_identity(app, webview_label) {
        Ok(identity) if identity.plugin_id == plugin_id => identity,
        _ => return refused("resource request is outside its plugin page"),
    };
    let path = request.uri().path().trim_start_matches('/');
    if path.starts_with("__lithe_host__/text/") {
        let package = app
            .state::<super::PluginHostState>()
            .packages()
            .into_iter()
            .find(|package| package.entry.plugin_id == identity.plugin_id);
        let text = package
            .as_ref()
            .and_then(|package| package.manifest["ui"]["toolWindows"].as_array())
            .and_then(|windows| {
                windows
                    .iter()
                    .find(|window| window["id"].as_str() == Some(&identity.window_id))
            })
            .and_then(|window| window["text"].as_str());
        return match text {
            Some(text) => ok("text/html; charset=utf-8", text_page(text)),
            None => refused("text window is no longer declared"),
        };
    }
    if path == HOST_BRIDGE_PATH {
        let appearance = app
            .state::<WebPageHostState>()
            .appearances
            .lock()
            .expect("appearance mutex")
            .get(webview_label)
            .cloned();
        return match appearance {
            Some(appearance) => ok(
                "text/javascript; charset=utf-8",
                bridge_script(
                    &identity.plugin_id,
                    &identity.window_id,
                    &appearance,
                    identity.generation,
                )
                .into_bytes(),
            ),
            None => refused("page is no longer active"),
        };
    }
    match serve_package_file(app, plugin_id, path) {
        Ok((content_type, body)) if content_type.starts_with("text/html") => {
            ok(content_type, page_with_host_bridge(body))
        }
        Ok((content_type, body)) => ok(content_type, body),
        Err(message) => refused(&message),
    }
}

/// ui:1 text is literal content, escaped into a host-owned shell. No package
/// markup or scripts execute; theme follows the same host bridge as web pages.
fn text_page(text: &str) -> Vec<u8> {
    let escaped = text
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&#39;");
    page_with_host_bridge(format!("<!doctype html><html><head><meta charset=\"utf-8\"><style>body{{margin:16px;background:var(--lithe-background);color:var(--lithe-foreground);font:var(--lithe-font-size) var(--lithe-font-family)}}pre{{white-space:pre-wrap;font:inherit}}</style></head><body><pre>{escaped}</pre></body></html>").into_bytes())
}

/// Inserts the host script before package code without rewriting the package.
/// Only the HTML prologue is scanned: comments/declarations and the optional
/// html/head opening tags. Stop before any other tag or text, so a literal
/// <head> inside script/style content is never interpreted as markup here.
fn page_with_host_bridge(body: Vec<u8>) -> Vec<u8> {
    let offset = bridge_insertion_offset(&body);
    let tag = format!("<script src=\"/{HOST_BRIDGE_PATH}\"></script>");
    let mut response = Vec::with_capacity(body.len() + tag.len());
    response.extend_from_slice(&body[..offset]);
    response.extend_from_slice(tag.as_bytes());
    response.extend_from_slice(&body[offset..]);
    response
}

fn bridge_insertion_offset(body: &[u8]) -> usize {
    let mut index = if body.starts_with(b"\xef\xbb\xbf") {
        3
    } else {
        0
    };
    let mut fallback = index;
    loop {
        while body.get(index).is_some_and(u8::is_ascii_whitespace) {
            index += 1;
        }
        if body[index..].starts_with(b"<!--") {
            let Some(end) = body[index + 4..].windows(3).position(|part| part == b"-->") else {
                return fallback;
            };
            index += 4 + end + 3;
            fallback = index;
            continue;
        }
        if body[index..].starts_with(b"<!") || body[index..].starts_with(b"<?") {
            let Some(end) = opening_tag_end(body, index + 2) else {
                return fallback;
            };
            index = end;
            fallback = index;
            continue;
        }
        if body.get(index) != Some(&b'<') {
            return fallback;
        }
        let name_start = index + 1;
        let mut name_end = name_start;
        while body.get(name_end).is_some_and(u8::is_ascii_alphabetic) {
            name_end += 1;
        }
        let name = &body[name_start..name_end];
        if !body
            .get(name_end)
            .is_some_and(|value| value.is_ascii_whitespace() || *value == b'>' || *value == b'/')
        {
            return fallback;
        }
        if !name.eq_ignore_ascii_case(b"html") && !name.eq_ignore_ascii_case(b"head") {
            return fallback;
        }
        let Some(end) = opening_tag_end(body, name_end) else {
            return fallback;
        };
        if name.eq_ignore_ascii_case(b"head") {
            return end;
        }
        index = end;
        fallback = end;
    }
}

/// HTML attribute quotes can contain `>`; they do not close the opening tag.
fn opening_tag_end(body: &[u8], mut index: usize) -> Option<usize> {
    let mut quote = None;
    while let Some(&value) = body.get(index) {
        match quote {
            Some(expected) if value == expected => quote = None,
            Some(_) => {}
            None if value == b'\'' || value == b'"' => quote = Some(value),
            None if value == b'>' => return Some(index + 1),
            None => {}
        }
        index += 1;
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn compiled_acl_grants_only_the_bridge_to_plugin_private_origins() {
        // Exercise Tauri's actual compiled capability resolution, including
        // its distinction between the app's origin and custom-protocol pages.
        let mut context: tauri::Context<tauri::Wry> = tauri::generate_context!();
        let acl = context.runtime_authority_mut();
        let label = "plugin-web-fixture";
        let own = tauri::ipc::Origin::Remote {
            url: url::Url::parse("http://lithe-plugin.acme.php/ui/index.html").unwrap(),
        };
        assert!(acl
            .resolve_access("plugin:declarative-web|request", label, label, &own)
            .is_some());
        for command in [
            "plugin:fs|read_text_file",
            "plugin:http|fetch",
            "plugin:event|emit",
            "core_execute",
            "read_local_file",
            "declarative_plugins_web_build_handle",
            "declarative_plugins_web_build_action",
        ] {
            assert!(
                acl.resolve_access(command, label, label, &own).is_none(),
                "{command}"
            );
        }
        let foreign = tauri::ipc::Origin::Remote {
            url: url::Url::parse("https://example.test/ui/index.html").unwrap(),
        };
        assert!(acl
            .resolve_access("plugin:declarative-web|request", label, label, &foreign)
            .is_none());
        assert!(acl
            .resolve_access("plugin:declarative-web|request", "main", "main", &own)
            .is_none());
        let manifests: Value = serde_json::from_str(include_str!(concat!(
            env!("OUT_DIR"),
            "/acl-manifests.json"
        )))
        .unwrap();
        assert!(
            manifests.get("__app__").is_none(),
            "the product's custom-command ACL must stay unchanged"
        );
    }

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
        let script = bridge_script(
            "acme.php",
            "window-id",
            &WebPageAppearance {
                locale: "zh-CN".into(),
                theme: "dark".into(),
                variables: BTreeMap::new(),
            },
            1,
        );
        assert!(script.contains(r#""pluginID":"acme.php""#));
        assert!(script.contains("Object.freeze(bridge)"));
        assert!(script.contains("writable: false"));
    }

    #[test]
    fn html_loads_the_fresh_host_bridge_before_package_code() {
        let tag = "<script src=\"/__lithe_host__/bridge.js\"></script>";
        let prologue = "<!doctype html><!-- <head>ignored</head> --><HTML style=\"--package-gap:8px\"><HEAD data-test=\"x>y\">";
        let tail = "<script src=\"page.js\"></script></HEAD><body></body></HTML>";
        for bom in ["", "\u{feff}"] {
            let body = format!("{bom}{prologue}{tail}");
            let response = String::from_utf8(page_with_host_bridge(body.into_bytes())).unwrap();
            assert_eq!(response, format!("{bom}{prologue}{tag}{tail}"));
        }
        // No synthetic doctype or root tags: preserve the package's HTML mode
        // and attributes even when its html/head tags are legitimately omitted.
        for (prefix, tail) in [
            (
                "<!doctype html><html style='--gap:8px'>",
                "<body><script src='page.js'></script></body>",
            ),
            (
                "<!doctype html><head data-test='a>b'>",
                "<script src='page.js'></script>",
            ),
            (
                "<!doctype html><!-- header -->",
                "<script src='page.js'></script>",
            ),
            ("", "<script>const text='<head>';</script>"),
        ] {
            assert_eq!(
                String::from_utf8(page_with_host_bridge(
                    format!("{prefix}{tail}").into_bytes()
                ))
                .unwrap(),
                format!("{prefix}{tag}{tail}")
            );
        }
        assert!(!PAGE_CSP.contains("script-src 'self' 'unsafe-inline'"));
    }

    #[test]
    fn navigation_and_bridge_refuse_foreign_documents() {
        let initial = package_page_url("acme.php", "ui/index.html").unwrap();
        assert!(is_package_url(&initial, "acme.php"));
        assert_eq!(
            initial.as_str(),
            if cfg!(windows) {
                "http://lithe-plugin.acme.php/ui/index.html"
            } else {
                "lithe-plugin://acme.php/ui/index.html"
            }
        );
        for address in [
            "lithe-plugin://acme.php/ui/index.html",
            "lithe-plugin://acme.php/ui/next.html#section",
        ] {
            assert!(require_package_url(&url::Url::parse(address).unwrap(), "acme.php").is_ok());
        }
        for address in [
            "https://example.com/ui/index.html",
            "http://lithe-plugin.acme.php.evil.test/ui/index.html",
            "lithe-plugin://other.plugin/ui/index.html",
            "lithe-plugin://user@acme.php/ui/index.html",
            "lithe-plugin://acme.php:1234/ui/index.html",
            "about:blank",
            "data:text/html,evil",
            "file:///tmp/index.html",
            "lithe-plugin://acme.php/%2e%2e%2foutside.html",
        ] {
            let error =
                require_package_url(&url::Url::parse(address).unwrap(), "acme.php").unwrap_err();
            assert!(error.contains("plugin.web.forbidden"), "{address}");
        }
        assert_eq!(
            is_package_url(
                &url::Url::parse("http://lithe-plugin.acme.php/ui/index.html").unwrap(),
                "acme.php"
            ),
            cfg!(windows)
        );
    }

    #[test]
    fn open_file_resolves_targets_before_checking_workspace_boundary() {
        struct TempRoot(PathBuf);
        impl Drop for TempRoot {
            fn drop(&mut self) {
                let _ = std::fs::remove_dir_all(&self.0);
            }
        }
        let root = TempRoot(super::serve_tests::unique_temp_root("workspace-paths"));
        let workspace = root.0.join("workspace");
        std::fs::create_dir(&workspace).unwrap();
        let inside = workspace.join("inside");
        let outside = root.0.join("outside");
        std::fs::create_dir(&inside).unwrap();
        std::fs::create_dir(&outside).unwrap();
        std::fs::write(inside.join("file.txt"), "inside").unwrap();
        std::fs::write(outside.join("file.txt"), "outside").unwrap();
        assert!(
            declarative_plugins_web_resolve_file(workspace.clone(), "inside/file.txt".into())
                .is_ok()
        );
        assert!(
            declarative_plugins_web_resolve_file(workspace.clone(), outside.join("file.txt"))
                .is_err()
        );
        link_directory(&inside, &workspace.join("inside-link"));
        link_directory(&outside, &workspace.join("outside-link"));
        let resolved =
            declarative_plugins_web_resolve_file(workspace.clone(), "inside-link/file.txt".into())
                .unwrap();
        assert!(resolved.ends_with("/inside/file.txt"));
        assert!(declarative_plugins_web_resolve_file(
            workspace.clone(),
            "outside-link/file.txt".into()
        )
        .is_err());
        // Canonicalize both sides so a workspace opened through a link works.
        link_directory(&workspace, &root.0.join("linked-root"));
        assert!(declarative_plugins_web_resolve_file(
            root.0.join("linked-root"),
            "inside/file.txt".into()
        )
        .is_ok());
    }

    fn link_directory(target: &Path, link: &Path) {
        #[cfg(windows)]
        {
            // Junctions need no developer-mode/admin privilege and protect
            // the same reparse-point escape boundary as directory symlinks.
            let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
            let mut command = std::process::Command::new("cmd");
            command
                .args(["/D", "/C", "mklink", "/J"])
                .arg(link)
                .arg(target);
            let outcome = lithe_git_host::run(
                &mut command,
                None,
                || std::time::Instant::now() >= deadline,
                || {},
                |_, _| {},
            );
            assert!(
                outcome.failure.is_none() && outcome.status.is_some_and(|status| status.success()),
                "junction creation failed: {}",
                String::from_utf8_lossy(&outcome.stderr)
            );
        }
        #[cfg(unix)]
        std::os::unix::fs::symlink(target, link).expect("directory symlink");
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
    fn workspace_pages_have_distinct_labels_and_state() {
        let first = PageOwner {
            generation: 1,
            workspace_generation: 0,
            host_label: "main".into(),
            workspace_id: "a".into(),
            workspace_path: "C:/a".into(),
            plugin_id: "test.plugin".into(),
            window_id: "panel".into(),
            state_id: String::new(),
        };
        let second = PageOwner {
            workspace_id: "b".into(),
            ..first.clone()
        };
        let other_window = PageOwner {
            generation: 1,
            workspace_generation: 0,
            host_label: "workspace-other".into(),
            ..first.clone()
        };
        assert_ne!(owned_label(&first), owned_label(&second));
        assert_ne!(owned_label(&first), owned_label(&other_window));
        assert_ne!(
            state_key("test.plugin", &owned_label(&first)),
            state_key("test.plugin", &owned_label(&second))
        );
    }

    #[test]
    fn text_window_is_literal_and_hello_fixture_is_registered() {
        let page = String::from_utf8(text_page("<script>alert('test')</script>&")).unwrap();
        assert!(!page.contains("<script>alert"));
        assert!(page.contains("&lt;script&gt;"));
        assert!(page.contains("/__lithe_host__/bridge.js"));
        let manifest: Value = serde_json::from_str(include_str!(
            "../../../../../shared/contracts/plugins/v1/fixtures/hello-lithe.plugin.json"
        ))
        .unwrap();
        assert!(manifest["ui"]["toolWindows"][0]["text"].is_string());
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

    pub(super) fn unique_temp_root(label: &str) -> PathBuf {
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
    fn registered_test_page(state: &WebPageHostState) -> (String, BridgeIdentity) {
        let owner = PageOwner {
            generation: 1,
            workspace_generation: 0,
            host_label: "main".into(),
            workspace_id: "a".into(),
            workspace_path: "C:/a".into(),
            plugin_id: "test.plugin".into(),
            window_id: "test.window".into(),
            state_id: String::new(),
        };
        let label = owned_label(&owner);
        let identity = BridgeIdentity {
            generation: owner.generation,
            workspace_generation: owner.workspace_generation,
            plugin_id: owner.plugin_id.clone(),
            window_id: owner.window_id.clone(),
            host_label: owner.host_label.clone(),
            workspace_id: owner.workspace_id.clone(),
            workspace_path: owner.workspace_path.clone(),
            state_id: label.clone(),
        };
        state.owners.lock().unwrap().insert(
            label.clone(),
            PageOwner {
                state_id: label.clone(),
                ..owner
            },
        );
        (label, identity)
    }

    #[test]
    fn page_revocation_clears_committed_effects_and_refuses_late_effects() {
        use std::sync::{mpsc, Arc};
        use std::time::Duration;
        let state = Arc::new(WebPageHostState::default());
        let (label, identity) = registered_test_page(&state);
        let (entered_tx, entered_rx) = mpsc::channel();
        let (release_tx, release_rx) = mpsc::channel();
        let (done_tx, done_rx) = mpsc::channel();
        let (sender, mut receiver) = tokio::sync::oneshot::channel();
        std::thread::scope(|scope| {
            let writing = state.clone();
            let label = label.clone();
            let identity = identity.clone();
            scope.spawn(move || {
                with_page_owner(&writing, &label, &identity, || {
                    entered_tx.send(()).unwrap();
                    release_rx.recv_timeout(Duration::from_secs(2)).unwrap();
                    writing
                        .states
                        .lock()
                        .unwrap()
                        .insert(state_key(&identity.plugin_id, &label), json!({"a":1}));
                    writing.open_files.lock().unwrap().insert(
                        "request".into(),
                        PendingOpenFile {
                            host_label: identity.host_label.clone(),
                            page_label: label.clone(),
                            completion: sender,
                        },
                    );
                    Ok(())
                })
                .unwrap();
            });
            entered_rx.recv_timeout(Duration::from_secs(2)).unwrap();
            assert!(state.owners.try_lock().is_err());
            let closing = state.clone();
            scope.spawn(move || {
                revoke_owners(&closing, |_| true, true);
                done_tx.send(()).unwrap();
            });
            release_tx.send(()).unwrap();
            done_rx.recv_timeout(Duration::from_secs(2)).unwrap();
        });
        assert!(state.states.lock().unwrap().is_empty());
        assert!(state.open_files.lock().unwrap().is_empty());
        assert_eq!(
            receiver.try_recv(),
            Err(tokio::sync::oneshot::error::TryRecvError::Closed)
        );
        let mut applied = false;
        assert!(with_page_owner(&state, &label, &identity, || {
            applied = true;
            Ok(())
        })
        .is_err());
        assert!(!applied);
        // Reopening the same logical page cannot revive a request from its old instance.
        let (_, mut replacement) = registered_test_page(&state);
        state
            .owners
            .lock()
            .unwrap()
            .get_mut(&label)
            .unwrap()
            .generation = 2;
        assert!(with_page_owner(&state, &label, &identity, || Ok(())).is_err());
        replacement.generation = 2;
        assert!(with_page_owner(&state, &label, &replacement, || Ok(())).is_ok());
    }

    #[test]
    fn workspace_close_revokes_a_page_created_from_an_older_workspace_epoch() {
        let state = WebPageHostState::default();
        let (label, mut identity) = registered_test_page(&state);
        state
            .workspace_generations
            .lock()
            .unwrap()
            .insert(workspace_label_suffix("main", "a"), 1);
        assert!(with_page_owner(&state, &label, &identity, || Ok(())).is_err());
        state
            .owners
            .lock()
            .unwrap()
            .get_mut(&label)
            .unwrap()
            .workspace_generation = 1;
        // A newly obtained identity must carry the updated workspace epoch;
        // the old receipt remains invalid even if the logical page reopens.
        assert!(with_page_owner(&state, &label, &identity, || Ok(())).is_err());
        identity.workspace_generation = 1;
        assert!(with_page_owner(&state, &label, &identity, || Ok(())).is_ok());
    }
}
