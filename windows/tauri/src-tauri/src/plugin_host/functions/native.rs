//! Declaration-bound native panels reuse the settings/web function owner.
//! A renderer supplies values, never a function, provider, program or permission.
use super::super::build_registry::BuildModelContext;
use super::*;
use serde_json::Map;

#[derive(Default)]
pub(super) struct Panels(Mutex<HashMap<String, Arc<Binding>>>);
pub(super) struct Binding {
    id: String,
    registration: u64,
    pub(super) window: String,
    pub(super) workspace: String,
    pub(super) plugin_id: String,
    tool_window: String,
    ui: Value,
    package_identity: String,
    setting_identity: String,
    pub(super) owner: Arc<WindowOwner>,
    context: BuildModelContext,
    alive: AtomicBool,
    busy: AtomicBool,
}
impl Panels {
    pub(super) fn revoke(&self, predicate: impl Fn(&Binding) -> bool) {
        self.0.lock().expect("native panels").retain(|_, binding| {
            if predicate(binding) {
                binding.alive.store(false, Ordering::Release);
                false
            } else {
                true
            }
        });
    }
    fn get(&self, id: &str, owner: &WindowOwner) -> Reply<Arc<Binding>> {
        self.0
            .lock()
            .expect("native panels")
            .get(id)
            .filter(|binding| binding.owner.id == owner.id && binding.alive.load(Ordering::Acquire))
            .cloned()
            .ok_or_else(|| Error::new("plugin.function.staleContext"))
    }
    fn insert(
        &self,
        binding: Arc<Binding>,
        check: impl FnOnce(&Binding) -> Reply<()>,
    ) -> Reply<()> {
        let mut panels = self.0.lock().expect("native panels");
        check(&binding)?;
        let same_slot = |old: &Binding| {
            old.owner.id == binding.owner.id
                && old.plugin_id == binding.plugin_id
                && old.tool_window == binding.tool_window
                && old.workspace == binding.workspace
        };
        if panels
            .values()
            .any(|old| same_slot(old) && old.registration > binding.registration)
        {
            return Err(Error::new("plugin.function.staleContext"));
        }
        // Replace this precise slot before returning its new handle. A late
        // close uses its old token and cannot revoke the replacement.
        panels.retain(|_, old| {
            if same_slot(old) {
                old.alive.store(false, Ordering::Release);
                false
            } else {
                true
            }
        });
        if panels.len() >= 128 {
            return Err(Error::new("plugin.function.busy"));
        }
        panels.insert(binding.id.clone(), binding);
        Ok(())
    }
}

struct Permit {
    binding: Arc<Binding>,
    released: AtomicBool,
}
impl Permit {
    fn release(&self) {
        if !self.released.swap(true, Ordering::AcqRel) {
            self.binding.busy.store(false, Ordering::Release);
        }
    }
}
impl Drop for Permit {
    fn drop(&mut self) {
        self.release();
    }
}
pub(super) struct Call {
    binding: Arc<Binding>,
    _permit: Permit,
    action: Option<String>,
    ui: Value,
    pub(super) params: Value,
}
impl Call {
    pub(super) fn selection(&self, manifest: &Value) -> Reply<(Value, String)> {
        let ui = declaration(manifest, &self.binding.tool_window)?;
        if ui != self.binding.ui {
            return Err(Error::new("plugin.function.staleContext"));
        }
        selection(&ui, self.action.as_deref())
    }
}

fn declaration(manifest: &Value, tool_window: &str) -> Reply<Value> {
    manifest["ui"]["toolWindows"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|window| window["id"] == tool_window)
        .and_then(|window| window.get("native"))
        .filter(|ui| ui.is_object())
        .cloned()
        .ok_or_else(|| Error::new("plugin.function.unavailable"))
}
fn selection(ui: &Value, action: Option<&str>) -> Reply<(Value, String)> {
    let build = ui["source"]["buildSystemID"]
        .as_str()
        .ok_or_else(|| Error::new("plugin.function.providerUnavailable"))?;
    let (function, title) = if let Some(id) = action {
        let action = ui["actions"]
            .as_array()
            .into_iter()
            .flatten()
            .find(|action| action["id"] == id && action["kind"] == "invoke")
            .ok_or_else(|| Error::new("plugin.function.unknownAction"))?;
        (action["function"].as_str(), action["title"].as_str())
    } else {
        (ui["source"]["function"].as_str(), ui["id"].as_str())
    };
    Ok((
        json!({"function":function.ok_or_else(|| Error::new("plugin.function.invalidReference"))?,
        "title":title.unwrap_or_default(),"confirm":true}),
        build.into(),
    ))
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PanelReceipt {
    binding_id: String,
    setting_identity: String,
    package_identity: String,
}

/// Register only an accepted native contribution and its unique detected
/// instance. All identity inputs are lookup hints checked against native facts.
#[tauri::command]
pub async fn declarative_plugins_native_function_open(
    app: AppHandle,
    window: WebviewWindow,
    plugin_id: String,
    window_id: String,
    workspace_path: String,
    expected_package_identity: String,
) -> Reply<PanelReceipt> {
    // Capture request order before any await: a slow old mount must not
    // replace a newer registration that has already become usable.
    static NEXT: AtomicU64 = AtomicU64::new(1);
    let registration = NEXT.fetch_add(1, Ordering::Relaxed);
    let owner = native_window_owner(&window.as_ref().window());
    let host = window.label().to_owned();
    let identity = expected_package_identity;
    let (ui, snapshot) = tauri::async_runtime::spawn_blocking({
        let app = app.clone();
        let plugin = plugin_id.clone();
        let tool = window_id.clone();
        let root = workspace_path.clone();
        move || {
            let catalog = super::super::native_ui::catalog(&app)
                .map_err(|_| Error::new("plugin.function.unavailable"))?;
            let entry = catalog
                .iter()
                .find(|entry| {
                    entry["pluginId"] == plugin
                        && entry["windowId"] == tool
                        && entry["packageIdentity"] == identity
                })
                .ok_or_else(|| Error::new("plugin.function.staleContext"))?;
            let snapshot = settings::read_snapshot(&app, &plugin, &root)
                .map_err(|_| Error::new("plugin.function.unavailable"))?;
            let ui = declaration(&snapshot.manifest, &tool)?;
            if ui != entry["native"] {
                return Err(Error::new("plugin.function.staleContext"));
            }
            if !super::super::native_ui::catalog(&app)
                .map_err(|_| Error::new("plugin.function.staleContext"))?
                .iter()
                .any(|entry| {
                    entry["pluginId"] == plugin
                        && entry["windowId"] == tool
                        && entry["packageIdentity"] == identity
                })
            {
                return Err(Error::new("plugin.function.staleContext"));
            }
            let (_, build) = selection(&ui, None)?;
            let system = snapshot.manifest["buildSystems"]
                .as_array()
                .into_iter()
                .flatten()
                .find(|system| system["id"] == build)
                .ok_or_else(|| Error::new("plugin.function.providerUnavailable"))?;
            if !system["provider"].is_object() || system["provider"]["languageServer"].is_string() {
                return Err(Error::new("plugin.function.providerUnavailable"));
            }
            Ok((ui, snapshot))
        }
    })
    .await
    .map_err(|_| Error::new("plugin.function.unavailable"))??;
    let system = ui["source"]["buildSystemID"]
        .as_str()
        .unwrap_or_default()
        .to_owned();
    let context = super::super::build::run_build_task(app.clone(), {
        let host = host.clone();
        let root = workspace_path.clone();
        let plugin = plugin_id.clone();
        move |registry, source, _| {
            let view = registry.view(&host);
            registry.check_read_snapshot(&host, &root, view.generation)?;
            let instance_root = unique_root(&view.instances, &plugin, &system)?;
            let context = registry.model_context(&host, &root, &plugin, &system, instance_root)?;
            if source.package(&plugin).as_ref() != Some(&context.package) {
                return Err("plugin.function.staleContext".into());
            }
            Ok(context)
        }
    })
    .await
    .map_err(|_| Error::new("plugin.function.providerUnavailable"))?;
    let binding = Arc::new(Binding {
        id: format!("native-{registration}"),
        registration,
        window: host,
        workspace: workspace_path,
        plugin_id,
        tool_window: window_id,
        ui,
        package_identity: snapshot.package_identity,
        setting_identity: snapshot.identity,
        owner,
        context,
        alive: AtomicBool::new(true),
        busy: AtomicBool::new(false),
    });
    check_binding(&app, &binding)?;
    let receipt = PanelReceipt {
        binding_id: binding.id.clone(),
        setting_identity: binding.setting_identity.clone(),
        package_identity: binding.package_identity.clone(),
    };
    app.state::<FunctionsState>()
        .native
        .insert(binding, |binding| check_binding(&app, binding))?;
    Ok(receipt)
}

fn unique_root<'a>(instances: &'a [Value], plugin: &str, system: &str) -> Result<&'a str, String> {
    let mut rows = instances
        .iter()
        .filter(|row| row["pluginID"] == plugin && row["buildSystemID"] == system);
    let root = rows
        .next()
        .and_then(|row| row["root"].as_str())
        .ok_or("plugin.function.providerUnavailable")?;
    if rows.next().is_some() {
        return Err("plugin.function.providerUnavailable".into());
    }
    Ok(root)
}

fn check_binding(app: &AppHandle, binding: &Binding) -> Reply<()> {
    if !binding.alive.load(Ordering::Acquire)
        || !binding.owner.alive.load(Ordering::Acquire)
        || app
            .state::<super::super::lifecycle::LifecycleState>()
            .blocked(&binding.plugin_id)
        || !app
            .state::<super::super::build::BuildHostState>()
            .function_context_is_current(&binding.context)
    {
        return Err(Error::new("plugin.function.staleContext"));
    }
    Ok(())
}
pub(super) fn check(app: &AppHandle, entry: &Operation) -> Reply<()> {
    if let Some(call) = entry.native.lock().expect("native function call").as_ref() {
        check_binding(app, &call.binding)?;
    }
    Ok(())
}
pub(super) fn begin(app: &AppHandle, entry: &Operation) -> Reply<()> {
    let state = app.state::<FunctionsState>();
    let _panels = state.native.0.lock().expect("native panels");
    check(app, entry)?;
    entry.begin()
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Request {
    binding_id: String,
    action_id: Option<String>,
    selected_id: Option<String>,
    values: Option<Map<String, Value>>,
    operation_id: String,
}
fn parameters(
    ui: &Value,
    action: Option<&str>,
    selected: Option<&str>,
    values: Option<Map<String, Value>>,
) -> Reply<(Value, Value)> {
    let mut checked = ui.clone();
    let form = ui["kind"] == "form";
    if form {
        let controls = checked["controls"]
            .as_array_mut()
            .ok_or_else(|| Error::new("plugin.function.invalidParams"))?;
        let values = values
            .as_ref()
            .ok_or_else(|| Error::new("plugin.function.invalidParams"))?;
        if values.len() != controls.len() {
            return Err(Error::new("plugin.function.invalidParams"));
        }
        for control in controls {
            control["value"] = values
                .get(control["id"].as_str().unwrap_or_default())
                .cloned()
                .ok_or_else(|| Error::new("plugin.function.invalidParams"))?;
        }
    } else if values.is_some() {
        return Err(Error::new("plugin.function.invalidParams"));
    }
    if selected.is_some_and(|id| {
        id.is_empty()
            || id.len() > 128
            || !id
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
    }) || (form && selected.is_some())
    {
        return Err(Error::new("plugin.function.invalidParams"));
    }
    if let Some(action) = action {
        let declaration = ui["actions"]
            .as_array()
            .into_iter()
            .flatten()
            .find(|item| item["id"] == action)
            .ok_or_else(|| Error::new("plugin.function.unknownAction"))?;
        if declaration["requiresSelection"] == true && selected.is_none() {
            return Err(Error::new("plugin.function.invalidParams"));
        }
    }
    let result = super::super::scan::core_execute(
        "plugins.nativeUI.validateData",
        json!({"ui":checked,"data":{"nodes":ui["nodes"]}}),
    )
    .map_err(|_| Error::new("plugin.function.invalidParams"))?;
    if result["status"] != "ok" {
        return Err(Error::new("plugin.function.invalidParams"));
    }
    let mut params = Map::new();
    if action.is_some() {
        params.insert("selectedID".into(), json!(selected));
    }
    if form {
        params.insert("values".into(), json!(values));
    }
    Ok((checked, Value::Object(params)))
}

#[tauri::command]
pub async fn declarative_plugins_native_function_prepare(
    app: AppHandle,
    window: WebviewWindow,
    request: Request,
) -> Reply<Review> {
    let owner = native_window_owner(&window.as_ref().window());
    let binding = app
        .state::<FunctionsState>()
        .native
        .get(&request.binding_id, &owner)?;
    check_binding(&app, &binding)?;
    if binding
        .busy
        .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
        .is_err()
    {
        return Err(Error::new("plugin.function.busy"));
    }
    let permit = Permit {
        binding: binding.clone(),
        released: AtomicBool::new(false),
    };
    let (ui, params) = parameters(
        &binding.ui,
        request.action_id.as_deref(),
        request.selected_id.as_deref(),
        request.values,
    )?;
    let call = Call {
        binding: binding.clone(),
        _permit: permit,
        action: request.action_id.clone(),
        ui,
        params,
    };
    let action = format!(
        "__native__:{}:{}",
        binding.id,
        request.action_id.as_deref().unwrap_or("")
    );
    prepare_owned(
        app,
        window,
        binding.plugin_id.clone(),
        action,
        binding.workspace.clone(),
        binding.setting_identity.clone(),
        request.operation_id,
        Some(call),
    )
    .await
}

#[tauri::command]
pub async fn declarative_plugins_native_function_close(
    app: AppHandle,
    window: WebviewWindow,
    binding_id: String,
) -> Reply<()> {
    let owner = native_window_owner(&window.as_ref().window());
    let state = app.state::<FunctionsState>();
    // A previously replaced/closed token is harmless, but never selects a new owner.
    state
        .native
        .revoke(|binding| binding.id == binding_id && binding.owner.id == owner.id);
    let prefix = format!("__native__:{binding_id}:");
    close_matching(&app, |context| {
        context.window_incarnation == owner.id && context.action_id.starts_with(&prefix)
    })
    .await
    .map_err(|_| Error::new("plugin.function.cleanupFailed"))
}

pub(super) fn result(entry: &Operation, value: Value) -> Reply<Value> {
    let native = entry.native.lock().expect("native function call");
    let Some(call) = native.as_ref() else {
        return Ok(value);
    };
    validate_result(call, value)
}

fn validate_result(call: &Call, value: Value) -> Reply<Value> {
    if serde_json::to_vec(&value).map_or(true, |bytes| bytes.len() > 1024 * 1024) {
        return Err(Error::new("plugin.function.resultTooLarge"));
    }
    if call.action.is_none() {
        let checked = super::super::scan::core_execute(
            "plugins.nativeUI.validateData",
            json!({"ui":call.ui,"data":value}),
        )
        .map_err(|_| Error::new("plugin.function.invalidResult"))?;
        if checked["status"] != "ok" {
            return Err(Error::new("plugin.function.invalidResult"));
        }
    }
    Ok(value)
}

pub(super) fn release(entry: &Operation) {
    if let Some(call) = entry.native.lock().expect("native function call").as_ref() {
        call._permit.release();
    }
}

#[cfg(test)]
mod tests;
