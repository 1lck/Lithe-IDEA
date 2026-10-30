//! Native background colour of workbench windows.
//!
//! WebView2 paints its default white until the page renders its first frame,
//! which showed as a white flash on every cold start and new project window.
//! Windows are instead created with the background of the last applied
//! workbench theme. The window must stay visible from creation: the window
//! state plugin maximizes restored windows, and maximizing shows a hidden
//! window on Windows, so hiding it until the first frame cannot cover every
//! start.
//!
//! The colour is a Lithe-owned appearance preference in the app's local data
//! directory. It is never written next to the installation, and a missing or
//! unreadable file falls back to the bundled Lithe Dark background, which is
//! also the frontend's bootstrap theme.

use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use tauri::window::Color;
use tauri::{AppHandle, Manager, Runtime, WebviewWindow};

use crate::blocking::run_blocking;

const FILE_NAME: &str = "window-background.json";
/// Lithe Dark `background`, the frontend's bootstrap theme.
const DEFAULT_BACKGROUND: Color = Color(0x19, 0x1a, 0x1c, 0xff);

#[derive(Debug, Serialize, Deserialize, PartialEq)]
struct StoredBackground {
    background: String,
}

/// Parses `#rrggbb` or `#rrggbbaa`. The alpha is dropped: the native window is
/// opaque, and a translucent colour would let the desktop show through.
fn parse_color(value: &str) -> Option<Color> {
    let hex = value.trim().strip_prefix('#')?;
    if !matches!(hex.len(), 6 | 8) || !hex.is_ascii() {
        return None;
    }
    let channel = |index: usize| u8::from_str_radix(&hex[index..index + 2], 16).ok();
    Some(Color(channel(0)?, channel(2)?, channel(4)?, 0xff))
}

fn format_color(color: Color) -> String {
    format!("#{:02x}{:02x}{:02x}", color.0, color.1, color.2)
}

fn storage_path<R: Runtime>(app: &AppHandle<R>) -> Option<PathBuf> {
    app.path()
        .app_local_data_dir()
        .ok()
        .map(|directory| directory.join(FILE_NAME))
}

fn read_stored(path: &Path) -> Option<Color> {
    let text = fs::read_to_string(path).ok()?;
    let stored: StoredBackground = serde_json::from_str(&text).ok()?;
    parse_color(&stored.background)
}

/// Every window records the theme it applies, often at the same moment;
/// they share one temporary file, so writes take turns.
static WRITE_LOCK: Mutex<()> = Mutex::new(());

/// Writes through a sibling temporary file so a crash never leaves a
/// truncated file that would silently reset the colour on the next start.
fn write_stored(path: &Path, color: Color) -> Result<(), String> {
    let _turn = WRITE_LOCK.lock().unwrap_or_else(|error| error.into_inner());
    let text = serde_json::to_string(&StoredBackground {
        background: format_color(color),
    })
    .map_err(|error| error.to_string())?;
    if fs::read_to_string(path).is_ok_and(|current| current == text) {
        return Ok(());
    }
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|error| error.to_string())?;
    }
    let temporary = path.with_extension("json.tmp");
    fs::write(&temporary, text).map_err(|error| error.to_string())?;
    fs::rename(&temporary, path).map_err(|error| {
        let _ = fs::remove_file(&temporary);
        error.to_string()
    })
}

/// The colour a new workbench window starts with: the last applied theme's
/// background, or Lithe Dark before any theme was recorded.
pub fn initial_background<R: Runtime>(app: &AppHandle<R>) -> Color {
    storage_path(app)
        .as_deref()
        .and_then(read_stored)
        .unwrap_or(DEFAULT_BACKGROUND)
}

/// Paints `window` with the applied theme's background and records it for the
/// windows of the next start.
pub async fn apply(window: &WebviewWindow, background: &str) -> Result<(), String> {
    let color = parse_color(background)
        .ok_or_else(|| format!("Window background must be #rrggbb, got {background:?}"))?;
    window
        .set_background_color(Some(color))
        .map_err(|error| error.to_string())?;
    let path = storage_path(window.app_handle())
        .ok_or_else(|| "The app data directory is unavailable".to_string())?;
    run_blocking(move || write_stored(&path, color)).await
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temporary_directory(name: &str) -> PathBuf {
        let directory = std::env::temp_dir().join(format!(
            "lithe-window-background-{name}-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&directory);
        directory
    }

    #[test]
    fn parses_theme_hex_colours_as_opaque() {
        assert_eq!(parse_color("#191a1c"), Some(Color(0x19, 0x1a, 0x1c, 0xff)));
        assert_eq!(
            parse_color(" #FFFFFF80 "),
            Some(Color(0xff, 0xff, 0xff, 0xff))
        );
    }

    #[test]
    fn rejects_values_that_are_not_hex_colours() {
        for value in ["", "191a1c", "#191a1", "#gg1a1c", "rgb(1, 2, 3)", "#ééé"] {
            assert_eq!(parse_color(value), None, "{value:?}");
        }
    }

    #[test]
    fn a_recorded_background_is_read_back() {
        let directory = temporary_directory("roundtrip");
        let path = directory.join(FILE_NAME);
        write_stored(&path, Color(0xef, 0xf1, 0xf5, 0xff)).expect("write background");

        assert_eq!(read_stored(&path), Some(Color(0xef, 0xf1, 0xf5, 0xff)));
        assert!(!path.with_extension("json.tmp").exists());
        fs::remove_dir_all(&directory).expect("remove fixture");
    }

    #[test]
    fn a_missing_or_corrupt_file_has_no_recorded_background() {
        let directory = temporary_directory("corrupt");
        let path = directory.join(FILE_NAME);
        assert_eq!(read_stored(&path), None);

        fs::create_dir_all(&directory).expect("create fixture");
        fs::write(&path, "{\"background\":").expect("write corrupt file");
        assert_eq!(read_stored(&path), None);
        fs::remove_dir_all(&directory).expect("remove fixture");
    }
}
