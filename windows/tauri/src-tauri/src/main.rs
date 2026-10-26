#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod agent;
mod agent_clipboard;
mod agent_provider_settings;
mod ai_commit;
mod core;
mod date_time;
mod debug;
mod diagnostics;
mod document;
mod extension_store_placeholder;
mod file_events;
mod file_publication;
mod fonts;
mod host;
mod html_browser;
mod language_tools;
mod logging;
mod lsp;
mod maven;
mod memory;
mod owned_processes;
mod platform;
mod plugin_host;
mod profile_migration;
mod project_window_registry;
mod project_windows;
mod run;
mod secure_storage;
mod shelf_storage;
mod terminal;
mod watcher;
mod window_title;

use file_events::TauriFileChangeEmitter;
use lithe_project::document_watcher::DocumentWatcher;
use lithe_project::git_watcher::GitMetadataWatcher;
use lithe_project::FileWatcher;
use lithe_terminal::TerminalManager;
use std::sync::Arc;
use tauri::Manager;
use tauri_plugin_window_state::StateFlags;

fn main() {
    let mut arguments = std::env::args().skip(1);
    if arguments.next().as_deref() == Some("--lithe-git-askpass") {
        std::process::exit(lithe_core::git_askpass_main(
            &arguments.next().unwrap_or_default(),
        ));
    }
    if std::env::var("LITHE_GIT_ASKPASS_MODE").as_deref() == Ok("1") && std::env::args().len() == 2
    {
        std::process::exit(lithe_core::git_askpass_main(
            &std::env::args().nth(1).unwrap_or_default(),
        ));
    }
    // Tauri normally constructs configured WebViews before the setup callback.
    // Defer them until settings/workspace migration and native managers are ready.
    let mut context = tauri::generate_context!();
    let initial_windows = context.config().app.windows.clone();
    for window in &mut context.config_mut().app.windows {
        window.create = false;
    }
    let application = tauri::Builder::default()
        .plugin(plugin_host::web::bridge_plugin())
        .register_uri_scheme_protocol("lithe-plugin", |context, request| {
            plugin_host::web::handle_scheme_request(
                context.app_handle(),
                context.webview_label(),
                request,
            )
        })
        .plugin(tauri_plugin_single_instance::init(|app, arguments, _| {
            host::enqueue_cli_arguments(app, arguments);
        }))
        .plugin(tauri_plugin_store::Builder::default().build())
        .plugin(tauri_plugin_clipboard_manager::init())
        .plugin(
            tauri_plugin_window_state::Builder::new()
                .with_state_flags(window_state_flags())
                .build(),
        )
        .plugin(tauri_plugin_fs::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_shell::init())
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_os::init())
        .plugin(tauri_plugin_http::init())
        .plugin(tauri_plugin_process::init())
        .plugin(tauri_plugin_deep_link::init())
        .plugin(tauri_plugin_updater::Builder::new().build())
        .setup(move |app| {
            match profile_migration::prepare(app.handle()) {
                Ok(true) => {
                    app.handle().plugin(
                        tauri::plugin::Builder::<_, ()>::new("profile-import-bootstrap")
                            .js_init_script(profile_migration::IMPORT_BOOTSTRAP)
                            .build(),
                    )?;
                }
                Ok(false) => {}
                Err(error) => {
                    use tauri_plugin_dialog::DialogExt;
                    let handle = app.handle().clone();
                    handle
                        .clone()
                        .dialog()
                        .message(error)
                        .title("Lithe-Dev")
                        .show(move |_| handle.exit(1));
                    return Ok(());
                }
            }
            app.manage(Arc::new(diagnostics::DiagnosticBundleStore::default()));
            match logging::LogManager::initialize(app.handle()) {
                Ok(log_manager) => {
                    app.manage(log_manager);
                }
                Err(error) => {
                    // Logging is diagnostic infrastructure; an unavailable log
                    // directory or writer must never prevent the product from starting.
                    eprintln!("[logging] application file logging is unavailable: {error}");
                    app.manage(logging::LogManager::degraded(app.handle(), error));
                }
            }
            app.manage(Arc::new(FileWatcher::new(Arc::new(
                TauriFileChangeEmitter::new(app.handle().clone()),
            ))));
            app.manage(Arc::new(GitMetadataWatcher::new(Arc::new(
                TauriFileChangeEmitter::new(app.handle().clone()),
            ))));
            app.manage(Arc::new(DocumentWatcher::new(Arc::new(
                TauriFileChangeEmitter::new(app.handle().clone()),
            ))?));
            app.manage(Arc::new(TerminalManager::new()));
            app.manage(terminal::FrontendTerminalSessions::default());
            app.manage(host::PendingCliOpenRequests::from_arguments(
                std::env::args().skip(1),
            ));
            app.manage(host::FileClipboard::default());
            app.manage(project_windows::ProjectWindows::default());
            app.manage(window_title::WindowTitles::default());
            app.manage(run::RunProcessManager::default());
            app.manage(plugin_host::run_plans::ExecutionState::default());
            app.manage(debug::DebugAdapterManager::default());
            app.manage(plugin_host::PluginHostState::default());
            app.manage(plugin_host::provider::ProviderHostState::default());
            app.manage(plugin_host::build::BuildHostState::default());
            app.manage(plugin_host::web::WebPageHostState::default());
            app.manage(plugin_host::lifecycle::LifecycleState::default());
            app.manage(plugin_host::marketplace::MarketplaceState::default());
            run::cleanup_legacy_appdata(app.handle());
            maven::clear_dependency_outputs(app.handle());
            plugin_host::install::cleanup_stale_snapshots(app.handle());
            for config in initial_windows.iter().filter(|config| config.create) {
                tauri::WebviewWindowBuilder::from_config(app.handle(), config)?.build()?;
            }
            if let Some(window) = app.get_webview_window("main") {
                host::apply_window_taskbar_icon(&window);
            }
            Ok(())
        })
        .on_window_event(|window, event| {
            if matches!(event, tauri::WindowEvent::Destroyed) {
                plugin_host::run_plans::window_destroyed(window.app_handle(), window.label());
                plugin_host::web::forget_window_appearance(window.app_handle(), window.label());
                plugin_host::lifecycle::window_destroyed(window.app_handle(), window.label());
                plugin_host::marketplace::window_destroyed(window.app_handle(), window.label());
                let build_app = window.app_handle().clone();
                let build_window = window.label().to_owned();
                tauri::async_runtime::spawn(async move {
                    if let Err(error) = plugin_host::provider::close_window(&build_app, &build_window).await {
                        eprintln!("Could not release plugin Provider sessions: {}", error.detail);
                    }
                    if let Err(error) = plugin_host::build::close_build_window(build_app, build_window).await {
                        eprintln!("Could not release plugin build operations: {error}");
                    }
                });
                run::release_window_processes(window.label());
                core::close_ide_hosts(window.label());
                agent::close_window_connections(window.label());
                project_windows::release_window(window.app_handle(), window.label().to_owned());
                window_title::remove_window(window.app_handle(), window.label());
                if let Some(watcher) = window.try_state::<Arc<DocumentWatcher>>() {
                    if let Err(error) = watcher.remove_owner(window.label()) {
                        eprintln!("Could not release document watches: {error}");
                    }
                }
                if let Some(watcher) = window.try_state::<Arc<GitMetadataWatcher>>() {
                    if let Err(error) = watcher.remove(window.label(), None) {
                        eprintln!("Could not release Git metadata watches: {error}");
                    }
                }
            }
        })
        // Plugin commands have their own ACL. The dedicated page bridge is
        // registered above; plugin pages reach no product application command.
        .invoke_handler(
            |invoke: tauri::ipc::Invoke<tauri::Wry>| match plugin_gate(invoke) {
                PluginGate::Handled => true,
                PluginGate::Pass(invoke) => {
                    let handler: Box<tauri::ipc::InvokeHandler<tauri::Wry>> =
                        Box::new(tauri::generate_handler![
                            date_time::format_system_date_time,
                            agent::agent_open,
                            agent::agent_send,
                            agent::agent_close,
                            document::read_document_file,
                            document::read_document_file_details,
                            document::read_document_file_change,
                            document::save_document_file,
                            document::resolve_agent_document_path,
                            document::save_agent_document,
                            document::trash_agent_document,
                            document::set_document_watches,
                            core::core_execute,
                            core::core_cancel,
                            core::ide_host_paths,
                            diagnostics::preview_diagnostic_bundle,
                            diagnostics::export_diagnostic_bundle,
                            debug::debug_start_session,
                            debug::debug_connect_session,
                            debug::debug_allocate_loopback_port,
                            debug::debug_wait_for_port,
                            debug::debug_session_ready,
                            debug::debug_send_request,
                            debug::debug_stop_session,
                            debug::debug_stop_workspace_sessions,
                            platform::platform_invoke,
                            memory::get_application_memory_usage,
                            terminal::begin_frontend_terminal_session,
                            terminal::warm_terminal_environment,
                            terminal::create_terminal,
                            terminal::terminal_write,
                            terminal::terminal_resize,
                            terminal::terminal_set_paused,
                            terminal::close_terminal,
                            terminal::list_shells,
                            watcher::start_watching,
                            watcher::stop_watching,
                            watcher::set_project_root,
                            watcher::watch_git_repository,
                            watcher::unwatch_git_repository,
                            secure_storage::store_secure_secret,
                            secure_storage::get_secure_secret,
                            secure_storage::remove_secure_secret,
                            agent_provider_settings::commit_agent_panel_settings,
                            logging::get_log_settings,
                            logging::set_log_directory,
                            logging::set_diagnostic_logging,
                            logging::read_lithe_log,
                            logging::query_lithe_logs,
                            diagnostics::discard_diagnostic_bundle,
                            logging::clear_lithe_logs,
                            logging::resolve_previous_log_cleanup,
                            logging::open_log_directory,
                            logging::frontend_trace,
                            logging::record_startup_milestone,
                            host::get_system_theme,
                            host::set_native_window_appearance,
                            fonts::get_system_fonts,
                            fonts::get_monospace_fonts,
                            fonts::validate_font,
                            host::get_bundled_extensions_path,
                            host::read_local_file,
                            host::read_local_file_bounded,
                            host::read_file_custom,
                            host::write_file,
                            host::write_patch_file,
                            shelf_storage::saved_changes_storage,
                            host::move_file,
                            host::rename_file,
                            host::get_symlink_info,
                            host::open_file_external,
                            host::open_html_in_browser,
                            host::take_pending_cli_open_requests,
                            host::clipboard_set,
                            host::clipboard_get,
                            host::clipboard_paste,
                            host::clipboard_clear,
                            host::clipboard_sequence_number,
                            agent_clipboard::agent_clipboard_file_paths,
                            host::wsl_automount_root,
                            host::create_app_window,
                            project_windows::claim_project_window,
                            project_windows::release_project_window,
                            project_windows::release_pending_project_window,
                            window_title::update_window_title_context,
                            lsp::lsp_resolve_java_launch,
                            lsp::lsp_rebuild_java_index,
                            language_tools::get_tool_path,
                            language_tools::install_language_tools,
                            language_tools::check_language_tool_requirements,
                            language_tools::cancel_language_tool_install,
                            language_tools::uninstall_language_tools,
                            maven::maven_load_configuration,
                            maven::maven_resolve_effective_configuration,
                            maven::maven_write_configuration,
                            maven::maven_create_dependency_output,
                            maven::maven_remove_dependency_output,
                            run::run_list_java_sources,
                            run::run_write_generated,
                            run::run_write_documents,
                            run::run_write_stdin,
                            run::maven_resolve_installation,
                            run::run_discover_toolchains,
                            run::run_resolve_launch,
                            run::run_resolve_toolchains,
                            run::run_execute_prelaunch,
                            run::run_start_process,
                            run::run_stop_process,
                            run::run_list_owned_processes,
                            run::run_stop_owned_processes,
                            plugin_host::lifecycle::declarative_plugins_lifecycle_ack,
                            plugin_host::declarative_plugins_rescan,
                            plugin_host::declarative_plugins_state,
                            plugin_host::details::declarative_plugins_details,
                            plugin_host::web::declarative_plugins_web_open_file_ack,
                            plugin_host::web::build::declarative_plugins_web_build_handle,
                            plugin_host::web::declarative_plugins_web_resolve_file,
                            plugin_host::web::declarative_plugins_web_update_appearance,
                            plugin_host::declarative_plugins_manifest,
                            plugin_host::launch::declarative_plugins_language_launch,
                            plugin_host::launch::declarative_plugins_language_owner,
                            plugin_host::install::declarative_plugins_prepare_disk_install,
                            plugin_host::marketplace::declarative_marketplace_list,
                            plugin_host::marketplace::declarative_marketplace_refresh,
                            plugin_host::marketplace::declarative_marketplace_prepare,
                            plugin_host::marketplace::declarative_marketplace_confirm,
                            plugin_host::marketplace::declarative_marketplace_cancel,
                            plugin_host::install::declarative_plugins_confirm_disk_install,
                            plugin_host::install::declarative_plugins_cancel_disk_install,
                            plugin_host::install::declarative_plugins_uninstall,
                            plugin_host::install::declarative_plugins_set_enabled,
                            plugin_host::install::declarative_plugins_rollback,
                            plugin_host::settings::declarative_plugins_resolve_settings,
                            plugin_host::settings::declarative_plugins_store_setting,
                            plugin_host::settings::declarative_plugins_workspace_configuration,
                            plugin_host::marketplace_sources::declarative_marketplace_sources_state,
                            plugin_host::marketplace_sources::declarative_marketplace_sources_add,
                            plugin_host::marketplace_sources::declarative_marketplace_sources_set_enabled,
                            plugin_host::marketplace_sources::declarative_marketplace_sources_remove,
                            plugin_host::run_plans::declarative_plugins_run_plan,
                            plugin_host::run_plans::declarative_plugins_test_plan,
                            plugin_host::run_plans::declarative_plugins_discover_tests,
                            plugin_host::run_plans::declarative_plugins_start_execution,
                            plugin_host::run_plans::declarative_plugins_execution_context,
                            plugin_host::run_plans::declarative_plugins_close_execution_workspace,
                            plugin_host::build::declarative_plugins_build_catalog,
                            plugin_host::build::declarative_plugins_build_language_import,
                            plugin_host::build::declarative_plugins_build_refresh,
                            plugin_host::build::declarative_plugins_build_set_option,
                            plugin_host::build::declarative_plugins_build_sync_check,
                            plugin_host::build::declarative_plugins_build_plugins_changed,
                            plugin_host::build::declarative_plugins_build_close_workspace,
                            plugin_host::build::declarative_plugins_build_prepare_model,
                            plugin_host::build::declarative_plugins_build_load_model,
                            plugin_host::build::declarative_plugins_build_cancel_operation,
                            plugin_host::build::declarative_plugins_build_prepare_run,
                            plugin_host::build::declarative_plugins_build_prepare_dependencies,
                            plugin_host::build::declarative_plugins_build_load_dependencies,
                            plugin_host::build::declarative_plugins_build_execute_run,
                            plugin_host::web::declarative_plugins_close_workspace_pages,
                            plugin_host::web::declarative_plugins_web_windows,
                            plugin_host::web::declarative_plugins_open_web_window,
                            plugin_host::web::declarative_plugins_close_web_window,
                            extension_store_placeholder::install_extension_from_url,
                            extension_store_placeholder::uninstall_extension_new,
                            extension_store_placeholder::get_extension_path,
                            extension_store_placeholder::read_extension_entrypoint,
                            extension_store_placeholder::get_importable_ide_projects,
                            owned_processes::app_prepare_update_install,
                        ]);
                    handler(invoke)
                }
            },
        )
        .build(context)
        .expect("error while building Lithe desktop shell");

    application.run(|app, event| {
        if matches!(event, tauri::RunEvent::Exit) {
            owned_processes::shutdown();
            if let Some(manager) = app.try_state::<Arc<logging::LogManager>>() {
                manager.shutdown();
            }
        }
    });
}

/// Result of the plugin-page gate: either the request was answered (or
/// rejected) by the bridge, or it passes through to the normal handlers.
enum PluginGate {
    Handled,
    Pass(tauri::ipc::Invoke<tauri::Wry>),
}

/// Intercepts plugin-page traffic before the generated handlers run.
fn plugin_gate(invoke: tauri::ipc::Invoke<tauri::Wry>) -> PluginGate {
    if invoke
        .message
        .webview_ref()
        .label()
        .starts_with("plugin-web-")
    {
        let command = invoke.message.command().to_string();
        invoke.resolver.reject(format!(
            "command {command} is not available to plugin pages"
        ));
        return PluginGate::Handled;
    }
    PluginGate::Pass(invoke)
}

fn window_state_flags() -> StateFlags {
    let mut flags = StateFlags::all();
    flags.remove(StateFlags::DECORATIONS);
    flags
}
