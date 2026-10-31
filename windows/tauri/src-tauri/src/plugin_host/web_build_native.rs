//! Thin page binding to the existing native operation owner. No plans,
//! process execution or decoding are implemented at the page boundary.
use super::*;
use std::sync::Arc;

#[derive(Clone)]
pub(crate) struct PageOperation {
    app: AppHandle,
    operation: Arc<operation::ModelOperation>,
}
impl PageOperation {
    pub fn id(&self) -> &str {
        &self.operation.id
    }
    pub fn finished(&self) -> bool {
        self.operation.finished()
    }
    pub fn cancelled(&self) -> bool {
        self.operation.cancelled()
    }
    pub fn context(&self) -> &super::super::build_registry::BuildModelContext {
        &self.operation.context
    }
    pub fn revoke(&self) {
        let operation = self.operation.clone();
        let owned = self.clone();
        defer_revoke(
            move || operation.cancel(),
            async move { owned.cancel().await },
        );
    }
    pub async fn cancel(&self) -> Result<(), String> {
        host::cancel(
            self.app.clone(),
            self.operation.context.window_label.clone(),
            self.operation.id.clone(),
        )
        .await
    }
    pub async fn execute(&self, kind: &str) -> Result<Value, String> {
        let app = self.app.clone();
        let host = self.operation.context.window_label.clone();
        let id = self.operation.id.clone();
        match kind {
            "build.refresh" => {
                serde_json::to_value(host::load(app, host, id).await?).map_err(|e| e.to_string())
            }
            "build.dependencies" => serde_json::to_value(dependencies::load(app, host, id).await?)
                .map_err(|e| e.to_string()),
            _ => serde_json::to_value(host::execute_run(app, host, id).await?)
                .map_err(|e| e.to_string()),
        }
    }
}

/// Page revocation can hold the page-owner and workflow-map locks. Native
/// publication takes its own mutex and then the registry, whose notifications
/// take the page-owner lock, so cancellation must start after leaving them.
fn defer_revoke(
    cancel: impl FnOnce() + Send + 'static,
    cleanup: impl std::future::Future<Output = Result<(), String>> + Send + 'static,
) {
    tauri::async_runtime::spawn(async move {
        if let Err(error) = tauri::async_runtime::spawn_blocking(cancel).await {
            eprintln!("page build cancellation worker failed: {error}");
        }
        if let Err(error) = cleanup.await {
            eprintln!("page build cleanup retained native owner: {error}");
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;
    use std::time::Duration;

    #[tokio::test]
    async fn page_revocation_returns_before_waiting_for_native_publication() {
        let publication = Arc::new(Mutex::new(()));
        let locked = publication.lock().unwrap();
        let (started, observed) = tokio::sync::oneshot::channel();
        let (finished, completed) = tokio::sync::oneshot::channel();
        let cancelling = publication.clone();
        defer_revoke(
            move || {
                let _ = started.send(());
                let _publication = cancelling.lock().unwrap();
            },
            async move {
                let _ = finished.send(());
                Ok(())
            },
        );
        // Simulate revocation still owning the page lock while a native
        // publication is held elsewhere. Scheduling must not block this owner.
        tokio::time::timeout(Duration::from_secs(2), observed)
            .await
            .unwrap()
            .unwrap();
        drop(locked);
        tokio::time::timeout(Duration::from_secs(2), completed)
            .await
            .unwrap()
            .unwrap();
    }
}

pub(crate) async fn prepare(
    app: AppHandle,
    context: &super::super::build_registry::BuildModelContext,
    method: &str,
    selection: Value,
) -> Result<(Value, PageOperation), String> {
    let host = context.window_label.clone();
    let workspace = context.workspace_root.clone();
    let plugin = context.plugin_id.clone();
    let system = context.build_system_id.clone();
    let root = context.root.clone();
    let review = match method {
        "build.refresh" => serde_json::to_value(
            host::prepare_with_refresh(
                app.clone(),
                host.clone(),
                workspace,
                plugin,
                system,
                root,
                Default::default(),
                true,
            )
            .await?,
        )
        .map_err(|e| e.to_string())?,
        "build.dependencies" => serde_json::to_value(
            dependencies::prepare(
                app.clone(),
                host.clone(),
                workspace,
                plugin,
                system,
                root,
                BuildDependenciesSelection {
                    project_id: selection["projectId"].as_str().map(str::to_string),
                },
            )
            .await?,
        )
        .map_err(|e| e.to_string())?,
        _ => serde_json::to_value(
            host::prepare_run(
                app.clone(),
                host.clone(),
                workspace,
                plugin,
                system,
                root,
                serde_json::from_value(selection).map_err(|_| "plugin.build.invalidSelection")?,
            )
            .await?,
        )
        .map_err(|e| e.to_string())?,
    };
    let id = review["operationId"]
        .as_str()
        .ok_or("plugin.build.invalidOutput")?;
    let operation = app.state::<BuildHostState>().operations.get(&host, id)?;
    Ok((review, PageOperation { app, operation }))
}

/// Reload only the requested passive instance. A page refresh must not
/// re-detect sibling plugins, rewrite their options or cancel their runs.
pub(crate) fn refresh_passive(
    registry: &mut BuildRegistry,
    source: &dyn BuildPackageSource,
    context: &super::super::build_registry::BuildModelContext,
) -> Result<super::super::build_registry::BuildView, String> {
    if source.package(&context.plugin_id).as_ref() != Some(&context.package) {
        return Err("plugin.build.packageChanged".into());
    }
    let before = registry.model_fingerprint(&HostCoreExecutor, context)?;
    let response = host_integration::read_passive_model(
        &HostCoreExecutor,
        &context.package.manifest,
        &context.build_system_id,
        &context.workspace_root,
        &context.root,
        &context.options,
    )?;
    if response["status"] != "ok" || !response["model"].is_object() {
        return Err("plugin.build.invalidOutput".into());
    }
    if source.package(&context.plugin_id).as_ref() != Some(&context.package) {
        return Err("plugin.build.packageChanged".into());
    }
    registry.apply_command_model(
        &HostCoreExecutor,
        context,
        response["model"].clone(),
        &before,
    )
}
