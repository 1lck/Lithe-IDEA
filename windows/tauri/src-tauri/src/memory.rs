use crate::logging::LogManager;
use serde::Serialize;
use serde_json::json;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use tauri::State;

static MEMORY_SAMPLING_WARNING_RECORDED: AtomicBool = AtomicBool::new(false);

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ApplicationMemoryUsage {
    lithe_bytes: u64,
    total_bytes: u64,
}

#[tauri::command]
pub async fn get_application_memory_usage(
    log_manager: State<'_, Arc<LogManager>>,
) -> Result<ApplicationMemoryUsage, String> {
    let result =
        match tauri::async_runtime::spawn_blocking(platform::application_memory_usage).await {
            Ok(result) => result,
            Err(error) => Err(format!("Memory sampling task failed: {error}")),
        };

    if let Err(error) = &result {
        record_sampling_failure_once(&log_manager, error);
    }
    result
}

fn record_sampling_failure_once(log_manager: &LogManager, error: &str) {
    if !take_sampling_warning_slot(&MEMORY_SAMPLING_WARNING_RECORDED) {
        return;
    }
    log_manager.emit_json(
        "warn",
        "windows.memory".to_string(),
        "application memory sampling failed".to_string(),
        Some(json!({ "error": error })),
    );
}

fn take_sampling_warning_slot(gate: &AtomicBool) -> bool {
    !gate.swap(true, Ordering::Relaxed)
}

#[cfg(target_os = "windows")]
mod platform {
    use super::ApplicationMemoryUsage;
    use std::collections::HashSet;
    use std::mem::size_of;
    use windows_sys::Win32::Foundation::{
        CloseHandle, GetLastError, ERROR_NO_MORE_FILES, HANDLE, INVALID_HANDLE_VALUE,
    };
    use windows_sys::Win32::System::Diagnostics::ToolHelp::{
        CreateToolhelp32Snapshot, Process32FirstW, Process32NextW, PROCESSENTRY32W,
        TH32CS_SNAPPROCESS,
    };
    use windows_sys::Win32::System::ProcessStatus::{
        K32GetProcessMemoryInfo, PROCESS_MEMORY_COUNTERS, PROCESS_MEMORY_COUNTERS_EX2,
    };
    use windows_sys::Win32::System::Threading::{
        GetCurrentProcess, GetCurrentProcessId, OpenProcess, PROCESS_QUERY_LIMITED_INFORMATION,
    };

    const WEBVIEW2_EXECUTABLE_NAME: &str = "msedgewebview2.exe";

    #[derive(Debug, Clone, PartialEq, Eq)]
    struct ProcessRecord {
        process_id: u32,
        parent_process_id: u32,
        executable_name: String,
    }

    struct OwnedHandle(HANDLE);

    impl Drop for OwnedHandle {
        fn drop(&mut self) {
            unsafe {
                let _ = CloseHandle(self.0);
            }
        }
    }

    pub(super) fn application_memory_usage() -> Result<ApplicationMemoryUsage, String> {
        let lithe_bytes = current_process_private_working_set_bytes()?;
        let processes = process_snapshot()?;
        let webview_process_ids =
            owned_webview_process_ids(&processes, unsafe { GetCurrentProcessId() });
        let webview_bytes = webview_process_ids
            .into_iter()
            // WebView2 processes can exit between the snapshot and this query.
            .filter_map(process_private_working_set_bytes)
            .fold(0_u64, u64::saturating_add);

        Ok(ApplicationMemoryUsage {
            lithe_bytes,
            total_bytes: lithe_bytes.saturating_add(webview_bytes),
        })
    }

    fn current_process_private_working_set_bytes() -> Result<u64, String> {
        private_working_set_bytes(unsafe { GetCurrentProcess() })
            .ok_or_else(|| "Failed to read the Lithe process private working set".to_string())
    }

    fn process_private_working_set_bytes(process_id: u32) -> Option<u64> {
        let handle = unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, process_id) };
        if handle.is_null() {
            return None;
        }
        let handle = OwnedHandle(handle);
        private_working_set_bytes(handle.0)
    }

    fn private_working_set_bytes(handle: HANDLE) -> Option<u64> {
        let counters_size = size_of::<PROCESS_MEMORY_COUNTERS_EX2>() as u32;
        let mut counters = PROCESS_MEMORY_COUNTERS_EX2 {
            cb: counters_size,
            ..Default::default()
        };
        let succeeded = unsafe {
            K32GetProcessMemoryInfo(
                handle,
                (&mut counters as *mut PROCESS_MEMORY_COUNTERS_EX2)
                    .cast::<PROCESS_MEMORY_COUNTERS>(),
                counters_size,
            )
        };
        // Task Manager's default Memory column reports the private working set,
        // so shared WebView2 pages are not counted once per process.
        (succeeded != 0).then_some(counters.PrivateWorkingSetSize as u64)
    }

    fn process_snapshot() -> Result<Vec<ProcessRecord>, String> {
        let snapshot = unsafe { CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0) };
        if snapshot == INVALID_HANDLE_VALUE {
            return Err(format!(
                "Failed to create the process snapshot: Windows error {}",
                unsafe { GetLastError() }
            ));
        }
        let snapshot = OwnedHandle(snapshot);
        let mut entry = PROCESSENTRY32W {
            dwSize: size_of::<PROCESSENTRY32W>() as u32,
            ..Default::default()
        };
        if unsafe { Process32FirstW(snapshot.0, &mut entry) } == 0 {
            return Err(format!(
                "Failed to enumerate the process snapshot: Windows error {}",
                unsafe { GetLastError() }
            ));
        }

        let mut processes = Vec::new();
        loop {
            processes.push(ProcessRecord {
                process_id: entry.th32ProcessID,
                parent_process_id: entry.th32ParentProcessID,
                executable_name: executable_name(&entry.szExeFile),
            });

            if unsafe { Process32NextW(snapshot.0, &mut entry) } != 0 {
                continue;
            }
            let error = unsafe { GetLastError() };
            if error == ERROR_NO_MORE_FILES {
                break;
            }
            return Err(format!(
                "Failed while enumerating the process snapshot: Windows error {error}"
            ));
        }
        Ok(processes)
    }

    fn executable_name(buffer: &[u16]) -> String {
        let length = buffer
            .iter()
            .position(|character| *character == 0)
            .unwrap_or(buffer.len());
        String::from_utf16_lossy(&buffer[..length])
    }

    fn owned_webview_process_ids(processes: &[ProcessRecord], lithe_process_id: u32) -> Vec<u32> {
        // A WebView2 app launched inside Lithe's terminal is also a descendant
        // of Lithe. Requiring the WebView2 root to be a direct child keeps that
        // unrelated process tree out of the application total.
        let mut owned: HashSet<u32> = processes
            .iter()
            .filter(|process| {
                process.parent_process_id == lithe_process_id
                    && process
                        .executable_name
                        .eq_ignore_ascii_case(WEBVIEW2_EXECUTABLE_NAME)
            })
            .map(|process| process.process_id)
            .collect();

        loop {
            let before = owned.len();
            for process in processes {
                if owned.contains(&process.parent_process_id)
                    && process
                        .executable_name
                        .eq_ignore_ascii_case(WEBVIEW2_EXECUTABLE_NAME)
                {
                    owned.insert(process.process_id);
                }
            }
            if owned.len() == before {
                break;
            }
        }

        let mut process_ids: Vec<u32> = owned.into_iter().collect();
        process_ids.sort_unstable();
        process_ids
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        fn process(
            process_id: u32,
            parent_process_id: u32,
            executable_name: &str,
        ) -> ProcessRecord {
            ProcessRecord {
                process_id,
                parent_process_id,
                executable_name: executable_name.to_string(),
            }
        }

        #[test]
        fn selects_only_webview_tree_started_directly_by_lithe() {
            let processes = vec![
                process(10, 1, "lithe-windows.exe"),
                process(20, 10, "msedgewebview2.exe"),
                process(21, 20, "msedgewebview2.exe"),
                process(22, 20, "MSEDGEWEBVIEW2.EXE"),
                process(30, 10, "pwsh.exe"),
                process(31, 30, "other-tauri-app.exe"),
                process(32, 31, "msedgewebview2.exe"),
                process(40, 99, "msedgewebview2.exe"),
            ];

            assert_eq!(owned_webview_process_ids(&processes, 10), vec![20, 21, 22]);
        }

        #[test]
        fn current_process_private_working_set_is_available() {
            let usage =
                application_memory_usage().expect("current process memory should be readable");

            assert!(usage.lithe_bytes > 0);
            assert!(usage.total_bytes >= usage.lithe_bytes);
            assert!(process_private_working_set_bytes(unsafe { GetCurrentProcessId() }).is_some());
        }
    }
}

#[cfg(test)]
mod warning_tests {
    use super::*;

    #[test]
    fn sampling_warning_gate_opens_only_once() {
        let gate = AtomicBool::new(false);

        assert!(take_sampling_warning_slot(&gate));
        assert!(!take_sampling_warning_slot(&gate));
    }
}

#[cfg(not(target_os = "windows"))]
mod platform {
    use super::ApplicationMemoryUsage;

    pub(super) fn application_memory_usage() -> Result<ApplicationMemoryUsage, String> {
        Err("Application memory usage is available only on Windows".to_string())
    }
}
