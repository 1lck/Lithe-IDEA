use lithe_terminal::{
    shell::Shell, TerminalConfig, TerminalEvent, TerminalEventHandler, TerminalInput,
    TerminalManager, TerminalSize,
};
use std::{
    collections::{HashMap, HashSet},
    sync::{Arc, Mutex},
};
use tauri::{ipc::Channel, AppHandle, State};

#[derive(Default)]
pub struct FrontendTerminalSessions {
    windows: Mutex<HashMap<String, FrontendTerminalSession>>,
}

#[derive(Default)]
struct FrontendTerminalSession {
    session_id: String,
    connection_ids: HashSet<String>,
}

impl FrontendTerminalSessions {
    fn begin_session(
        &self,
        window_label: String,
        session_id: String,
    ) -> Result<Vec<String>, String> {
        let mut windows = self
            .windows
            .lock()
            .map_err(|error| format!("Failed to lock terminal sessions: {error}"))?;

        if windows
            .get(&window_label)
            .is_some_and(|session| session.session_id == session_id)
        {
            return Ok(Vec::new());
        }

        let stale = windows
            .remove(&window_label)
            .map(|session| session.connection_ids.into_iter().collect())
            .unwrap_or_default();

        windows.insert(
            window_label,
            FrontendTerminalSession {
                session_id,
                ..FrontendTerminalSession::default()
            },
        );

        Ok(stale)
    }

    fn register(
        &self,
        window_label: &str,
        session_id: &str,
        connection_id: String,
    ) -> Result<(), String> {
        let mut windows = self
            .windows
            .lock()
            .map_err(|error| format!("Failed to lock terminal sessions: {error}"))?;
        let session = windows
            .get_mut(window_label)
            .filter(|session| session.session_id == session_id)
            .ok_or_else(|| "Frontend terminal session is no longer active".to_string())?;
        session.connection_ids.insert(connection_id);
        Ok(())
    }

    fn unregister(&self, connection_id: &str) {
        let Ok(mut windows) = self.windows.lock() else {
            return;
        };

        for session in windows.values_mut() {
            session.connection_ids.remove(connection_id);
        }
    }
}

#[tauri::command]
pub fn begin_frontend_terminal_session(
    window_label: String,
    session_id: String,
    frontend_sessions: State<'_, FrontendTerminalSessions>,
    terminal_manager: State<'_, Arc<TerminalManager>>,
) -> Result<(), String> {
    for connection_id in frontend_sessions.begin_session(window_label, session_id)? {
        terminal_manager
            .close_terminal(&connection_id)
            .map_err(|error| error.to_string())?;
    }
    Ok(())
}

#[tauri::command]
pub fn warm_terminal_environment(terminal_manager: State<'_, Arc<TerminalManager>>) {
    terminal_manager.warm_user_environment();
}

#[tauri::command]
pub fn create_terminal(
    mut config: TerminalConfig,
    on_event: Channel<TerminalEvent>,
    window_label: String,
    frontend_session_id: String,
    app: AppHandle,
    frontend_sessions: State<'_, FrontendTerminalSessions>,
    terminal_manager: State<'_, Arc<TerminalManager>>,
) -> Result<String, String> {
    config.term_program_version = Some(app.package_info().version.to_string());
    let handler: TerminalEventHandler = Arc::new(move |_, event| on_event.send(event).is_ok());
    let connection_id = terminal_manager
        .create_terminal(config, handler)
        .map_err(|error| error.to_string())?;

    if let Err(error) =
        frontend_sessions.register(&window_label, &frontend_session_id, connection_id.clone())
    {
        let _ = terminal_manager.close_terminal(&connection_id);
        return Err(error);
    }

    Ok(connection_id)
}

#[tauri::command]
pub fn terminal_write(
    id: String,
    input: TerminalInput,
    terminal_manager: State<'_, Arc<TerminalManager>>,
) -> Result<(), String> {
    terminal_manager
        .write_to_terminal(&id, input)
        .map_err(|error| error.to_string())
}

#[tauri::command]
pub fn terminal_resize(
    id: String,
    size: TerminalSize,
    terminal_manager: State<'_, Arc<TerminalManager>>,
) -> Result<(), String> {
    terminal_manager
        .resize_terminal(&id, size)
        .map_err(|error| error.to_string())
}

#[tauri::command]
pub fn terminal_set_paused(
    id: String,
    paused: bool,
    terminal_manager: State<'_, Arc<TerminalManager>>,
) -> Result<(), String> {
    terminal_manager
        .set_terminal_paused(&id, paused)
        .map_err(|error| error.to_string())
}

#[tauri::command]
pub fn close_terminal(
    id: String,
    frontend_sessions: State<'_, FrontendTerminalSessions>,
    terminal_manager: State<'_, Arc<TerminalManager>>,
) -> Result<(), String> {
    frontend_sessions.unregister(&id);
    terminal_manager
        .close_terminal(&id)
        .map_err(|error| error.to_string())
}

#[tauri::command]
pub fn list_shells() -> Vec<Shell> {
    lithe_terminal::get_shells()
}
