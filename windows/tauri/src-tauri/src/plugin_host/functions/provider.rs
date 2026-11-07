//! Function requests borrow the selected build/editor Provider. The request
//! guard owns cancellation; the Provider registry retains the process owner.
use super::super::build_registry::BuildModelContext;
use super::*;

pub(super) struct Call {
    app: AppHandle,
    review: super::super::provider::ProviderReview,
    context: BuildModelContext,
}
impl Drop for Call {
    fn drop(&mut self) {
        super::super::provider::discard_review(
            &self.app,
            &self.review.context.window,
            self.review.token,
        );
    }
}

pub(super) fn prepare(
    app: &AppHandle,
    window: &WebviewWindow,
    approved: &Review,
    system: &str,
    context: Option<BuildModelContext>,
) -> Reply<Call> {
    let context = if let Some(context) = context {
        context
    } else {
        tauri::async_runtime::block_on(super::super::build::run_build_task(app.clone(), {
            let host = window.label().to_owned();
            let root = approved.context.workspace_path.clone();
            let plugin = approved.context.plugin_id.clone();
            let system = system.to_owned();
            move |registry, source, _| {
                let view = registry.view(&host);
                registry.check_read_snapshot(&host, &root, view.generation)?;
                let instance = native::unique_root(&view.instances, &plugin, &system)?;
                let context = registry.model_context(&host, &root, &plugin, &system, instance)?;
                if source.package(&plugin).as_ref() != Some(&context.package) {
                    return Err("plugin.function.staleContext".into());
                }
                Ok(context)
            }
        }))
        .map_err(|_| Error::new("plugin.function.providerUnavailable"))?
    };
    if context.generation != approved.context.generation
        || context.plugin_id != approved.context.plugin_id
        || context.workspace_root != approved.context.workspace_path
        || context.build_system_id != system
    {
        return Err(Error::new("plugin.function.staleContext"));
    }
    tauri::async_runtime::block_on(super::super::provider::set_workspace(
        app,
        window,
        context.workspace_root.clone(),
        context.generation,
    ))
    .map_err(native::provider_error)?;
    let review = super::super::provider::prepare(
        app,
        window,
        context.workspace_root.clone(),
        context.generation,
        context.plugin_id.clone(),
        context.build_system_id.clone(),
        context.root.clone(),
        Default::default(),
    )
    .map_err(native::provider_error)?;
    let call = Call {
        app: app.clone(),
        review,
        context,
    };
    // Reusing a session cannot change the process or permissions the user saw.
    if call.review.program != approved.program || call.review.launch_plan != approved.launch_plan {
        return Err(Error::new("plugin.function.staleContext"));
    }
    Ok(call)
}

pub(super) fn check(app: &AppHandle, entry: &Operation) -> Reply<()> {
    if entry
        .provider
        .lock()
        .expect("function provider")
        .as_ref()
        .is_some_and(|call| {
            !app.state::<super::super::build::BuildHostState>()
                .function_context_is_current(&call.context)
        })
    {
        return Err(Error::new("plugin.function.staleContext"));
    }
    Ok(())
}

pub(super) async fn invoke(app: &AppHandle, entry: &Arc<Operation>) -> Reply<Value> {
    let review = entry
        .provider
        .lock()
        .expect("function provider")
        .as_ref()
        .map(|call| call.review.clone())
        .ok_or_else(|| Error::new("plugin.function.providerUnavailable"))?;
    let window = app
        .get_webview_window(&entry.review.context.window)
        .ok_or_else(|| Error::new("plugin.function.staleContext"))?;
    // Shared language confirm binds only an already authorized matching editor
    // owner. It never starts an isolated copy or adopts an arbitrary session.
    let binding = super::super::provider::confirm(app, &window, review.token)
        .await
        .map_err(native::provider_error)?;
    runtime::verify(app, entry).await?;
    entry.status.lock().expect("function state").phase = Phase::Running;
    let value = binding
        .function_request(
            app,
            &window,
            entry.review.context.operation_id.clone(),
            entry.review.context.function_id.clone(),
            entry.params(),
            |value| {
                if check_context(app, entry).is_ok() {
                    entry.status.lock().expect("function state").progress = Some(value);
                }
            },
        )
        .await
        .map_err(native::provider_error)?;
    runtime::verify(app, entry).await?;
    native::result(entry, value)
}
