use lithe_terminal::{
    shell::Shell, TerminalConfig, TerminalEvent, TerminalEventHandler, TerminalInput,
    TerminalManager, TerminalSize,
};
use std::{
    collections::{HashMap, HashSet},
    sync::{Arc, Mutex},
};
use tauri::{ipc::Channel, AppHandle, Manager, State};

#[derive(Default)]
pub struct FrontendTerminalSessions {
    windows: Mutex<HashMap<String, Option<FrontendTerminalSession>>>,
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

        if windows.get(&window_label).is_some_and(Option::is_none) {
            return Err("Frontend terminal session is no longer active".into());
        }
        if windows
            .get(&window_label)
            .and_then(Option::as_ref)
            .is_some_and(|session| session.session_id == session_id)
        {
            return Ok(Vec::new());
        }

        let stale = windows
            .remove(&window_label)
            .flatten()
            .map(|session| session.connection_ids.into_iter().collect())
            .unwrap_or_default();

        windows.insert(
            window_label,
            Some(FrontendTerminalSession {
                session_id,
                ..FrontendTerminalSession::default()
            }),
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
            .and_then(Option::as_mut)
            .filter(|session| session.session_id == session_id)
            .ok_or_else(|| "Frontend terminal session is no longer active".to_string())?;
        session.connection_ids.insert(connection_id);
        Ok(())
    }

    fn close_window(&self, window_label: &str) -> Vec<String> {
        let mut windows = self
            .windows
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        // Project window labels are process-unique. None permanently rejects late opens.
        windows
            .insert(window_label.to_owned(), None)
            .flatten()
            .map(|session| session.connection_ids.into_iter().collect())
            .unwrap_or_default()
    }

    fn unregister(&self, connection_id: &str) {
        let Ok(mut windows) = self.windows.lock() else {
            return;
        };

        for session in windows.values_mut().flatten() {
            session.connection_ids.remove(connection_id);
        }
    }
}

pub fn close_window_terminals(app: &AppHandle, window_label: &str) {
    let ids = app
        .state::<FrontendTerminalSessions>()
        .close_window(window_label);
    let manager = Arc::clone(&app.state::<Arc<TerminalManager>>());
    // Invalidate ownership synchronously; process cleanup stays off the UI thread.
    tauri::async_runtime::spawn_blocking(move || {
        for id in ids {
            let _ = manager.close_terminal(&id);
        }
    });
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

/// Starting the shell and its pseudo console runs off the UI thread.
#[tauri::command]
pub async fn create_terminal(
    config: TerminalConfig,
    on_event: Channel<TerminalEvent>,
    window_label: String,
    frontend_session_id: String,
    app: AppHandle,
) -> Result<String, String> {
    crate::blocking::run_blocking(move || {
        start_terminal(config, on_event, &window_label, &frontend_session_id, &app)
    })
    .await
}

fn start_terminal(
    mut config: TerminalConfig,
    on_event: Channel<TerminalEvent>,
    window_label: &str,
    frontend_session_id: &str,
    app: &AppHandle,
) -> Result<String, String> {
    let frontend_sessions = app.state::<FrontendTerminalSessions>();
    let terminal_manager = app.state::<Arc<TerminalManager>>();
    config.term_program_version = Some(app.package_info().version.to_string());
    let handler: TerminalEventHandler = Arc::new(move |_, event| on_event.send(event).is_ok());
    let connection_id = terminal_manager
        .create_terminal(config, handler)
        .map_err(|error| error.to_string())?;

    if let Err(error) =
        frontend_sessions.register(window_label, frontend_session_id, connection_id.clone())
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
pub async fn list_shells() -> Result<Vec<Shell>, String> {
    tauri::async_runtime::spawn_blocking(lithe_terminal::get_shells)
        .await
        .map_err(|error| format!("Failed to detect installed shells: {error}"))
}

#[cfg(test)]
mod lifecycle_tests {
    use super::*;

    #[test]
    fn destruction_drains_connections_and_rejects_queued_registration() {
        let sessions = FrontendTerminalSessions::default();
        sessions
            .begin_session("window".into(), "page".into())
            .unwrap();
        sessions.register("window", "page", "live".into()).unwrap();
        assert_eq!(sessions.close_window("window"), vec!["live"]);
        assert!(sessions.register("window", "page", "late".into()).is_err());
        assert!(sessions
            .begin_session("window".into(), "late-page".into())
            .is_err());
        assert!(sessions.close_window("window").is_empty());
        sessions
            .begin_session("other".into(), "page".into())
            .unwrap();
        assert!(sessions.register("other", "page", "new".into()).is_ok());
    }
}
