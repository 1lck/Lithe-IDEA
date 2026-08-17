#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod core;
mod file_events;
mod host;
mod lsp;
mod platform;
mod run;
mod secure_storage;
mod terminal;
mod watcher;

use file_events::TauriFileChangeEmitter;
use lithe_project::FileWatcher;
use lithe_terminal::TerminalManager;
use std::sync::Arc;
use tauri::Manager;
use tauri_plugin_window_state::StateFlags;

fn main() {
    tauri::Builder::default()
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
        .setup(|app| {
            app.manage(Arc::new(FileWatcher::new(Arc::new(
                TauriFileChangeEmitter::new(app.handle().clone()),
            ))));
            app.manage(Arc::new(TerminalManager::new()));
            app.manage(terminal::FrontendTerminalSessions::default());
            app.manage(host::PendingCliOpenRequests::from_arguments(
                std::env::args().skip(1),
            ));
            app.manage(host::FileClipboard::default());
            app.manage(run::RunProcessManager::default());
            if let Some(window) = app.get_webview_window("main") {
                host::apply_window_taskbar_icon(&window);
            }
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            core::core_execute,
            core::core_cancel,
            platform::platform_invoke,
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
            secure_storage::store_secure_secret,
            secure_storage::get_secure_secret,
            secure_storage::remove_secure_secret,
            host::frontend_trace,
            host::record_startup_milestone,
            host::get_system_theme,
            host::set_native_window_appearance,
            host::get_system_fonts,
            host::get_monospace_fonts,
            host::validate_font,
            host::get_bundled_extensions_path,
            host::read_local_file,
            host::read_file_custom,
            host::write_file,
            host::move_file,
            host::rename_file,
            host::get_symlink_info,
            host::open_file_external,
            host::take_pending_cli_open_requests,
            host::clipboard_set,
            host::clipboard_get,
            host::clipboard_paste,
            host::clipboard_clear,
            host::create_app_window,
            lsp::lsp_resolve_java_launch,
            run::run_list_java_sources,
            run::run_write_generated,
            run::run_write_document,
            run::run_discover_toolchains,
            run::run_resolve_launch,
            run::run_start_process,
            run::run_stop_process,
        ])
        .run(tauri::generate_context!())
        .expect("error while running Lithe desktop shell");
}

fn window_state_flags() -> StateFlags {
    let mut flags = StateFlags::all();
    flags.remove(StateFlags::DECORATIONS);
    flags
}
