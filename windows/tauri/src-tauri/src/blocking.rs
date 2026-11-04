//! Moves host work that can block off the thread that dispatches IPC.

/// Runs `work` on Tauri's blocking pool and returns its result to an `async`
/// command.
///
/// Tauri runs a synchronous `#[tauri::command]` inline on the thread that
/// dispatches IPC, which on Windows is the WebView2 UI thread. While such a
/// command reads a file, probes a JDK or deletes an index, the window stops
/// painting, input queues up and every other invoke waits behind it. Commands
/// that touch the file system or start processes are therefore `async` and run
/// their body here. The blocking pool, rather than an async worker, absorbs a
/// stalled network path or a slow child process.
pub async fn run_blocking<T, F>(work: F) -> Result<T, String>
where
    F: FnOnce() -> Result<T, String> + Send + 'static,
    T: Send + 'static,
{
    run_blocking_result(work).await
}

/// Keeps structured native failures intact while using the same blocking pool.
pub async fn run_blocking_result<T, E, F>(work: F) -> Result<T, E>
where
    F: FnOnce() -> Result<T, E> + Send + 'static,
    T: Send + 'static,
    E: From<String> + Send + 'static,
{
    tauri::async_runtime::spawn_blocking(work)
        .await
        .map_err(|error| E::from(format!("Host task failed: {error}")))?
}

#[cfg(test)]
mod tests {
    use super::run_blocking;

    #[test]
    fn returns_the_work_result_and_its_error() {
        assert_eq!(
            tauri::async_runtime::block_on(run_blocking(|| Ok(7))),
            Ok(7)
        );
        assert_eq!(
            tauri::async_runtime::block_on(run_blocking(|| Err::<(), _>("denied".to_string()))),
            Err("denied".to_string())
        );
    }

    #[test]
    fn runs_the_work_off_the_calling_thread() {
        let caller = std::thread::current().id();
        let worker =
            tauri::async_runtime::block_on(run_blocking(|| Ok(std::thread::current().id())))
                .expect("blocking work");
        assert_ne!(worker, caller);
    }
}
