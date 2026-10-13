//! Read-only Windows font catalog. DirectWrite supplies real family names,
//! localized labels and pitch, including fonts installed for the current user.
//! Enumeration runs off the UI thread; no registry subprocess, downloads or
//! font-file writes are involved. Installed font ownership stays with Windows.
use serde::Serialize;

#[derive(Debug, Clone, Serialize)]
pub struct FontInfo {
    name: String,
    family: String,
    style: String,
    is_monospace: bool,
}

/// Reads the current system collection without blocking the WebView thread.
#[tauri::command]
pub async fn get_system_fonts() -> Result<Vec<FontInfo>, String> {
    tauri::async_runtime::spawn_blocking(system_fonts)
        .await
        .map_err(|error| format!("Font enumeration task failed: {error}"))?
}

/// Retains the terminal's optional fixed-pitch filter; editor choices use all fonts.
#[tauri::command]
pub async fn get_monospace_fonts() -> Result<Vec<FontInfo>, String> {
    Ok(get_system_fonts()
        .await?
        .into_iter()
        .filter(|font| font.is_monospace)
        .collect())
}

/// Matches either the canonical or the localized family name from the OS.
#[tauri::command]
pub async fn validate_font(font_family: String) -> Result<bool, String> {
    let wanted = font_family.trim().to_lowercase();
    Ok(get_system_fonts()
        .await?
        .iter()
        .any(|font| font.family.to_lowercase() == wanted || font.name.to_lowercase() == wanted))
}

/// Normalizes catalog presentation, not font identity or fallback resolution.
fn normalize_catalog(mut fonts: Vec<FontInfo>) -> Vec<FontInfo> {
    for font in &mut fonts {
        font.family = font.family.trim().to_owned();
        font.name = font.name.trim().to_owned();
        if font.name.is_empty() {
            font.name = font.family.clone();
        }
    }
    fonts.retain(|font| !font.family.is_empty());
    fonts.sort_by_key(|font| font.family.to_lowercase());
    fonts.dedup_by(|left, right| left.family.to_lowercase() == right.family.to_lowercase());
    fonts
}

#[cfg(target_os = "windows")]
fn system_fonts() -> Result<Vec<FontInfo>, String> {
    use windows::core::{Interface, BOOL, PCWSTR};
    use windows::Win32::Globalization::GetUserDefaultLocaleName;
    use windows::Win32::Graphics::DirectWrite::{
        DWriteCreateFactory, IDWriteFactory, IDWriteFont1, IDWriteLocalizedStrings,
        DWRITE_FACTORY_TYPE_SHARED, DWRITE_FONT_STRETCH_NORMAL, DWRITE_FONT_STYLE_NORMAL,
        DWRITE_FONT_WEIGHT_NORMAL,
    };

    // The UTF-16 buffers outlive each call; GetString receives its full slice,
    // including a terminator. COM wrappers release the read-only collection.
    unsafe fn localized_index(names: &IDWriteLocalizedStrings, locale: &[u16]) -> u32 {
        let mut index = 0;
        let mut found = BOOL::default();
        if names
            .FindLocaleName(PCWSTR(locale.as_ptr()), &mut index, &mut found)
            .is_ok()
            && found.as_bool()
        {
            index
        } else {
            0
        }
    }
    unsafe fn name_at(names: &IDWriteLocalizedStrings, index: u32) -> Result<String, String> {
        let length = names.GetStringLength(index).map_err(|e| e.to_string())? as usize;
        if length > 32_768 {
            return Err("Invalid system font family length".into());
        }
        let mut buffer = vec![0u16; length + 1];
        names
            .GetString(index, &mut buffer)
            .map_err(|e| e.to_string())?;
        String::from_utf16(&buffer[..length]).map_err(|e| e.to_string())
    }
    unsafe {
        let factory: IDWriteFactory = DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED)
            .map_err(|error| format!("DirectWrite font catalog unavailable: {error}"))?;
        let mut collection = None;
        factory
            .GetSystemFontCollection(&mut collection, true)
            .map_err(|e| e.to_string())?;
        let collection = collection.ok_or("Windows returned no font collection")?;
        let english: Vec<u16> = "en-us\0".encode_utf16().collect();
        let mut user_locale = [0u16; 85];
        let locale_length = GetUserDefaultLocaleName(&mut user_locale);
        let locale = if locale_length > 0 {
            &user_locale[..]
        } else {
            &english[..]
        };
        let mut fonts = Vec::new();
        for index in 0..collection.GetFontFamilyCount() {
            let family = collection.GetFontFamily(index).map_err(|e| e.to_string())?;
            let names = family.GetFamilyNames().map_err(|e| e.to_string())?;
            let canonical = name_at(&names, localized_index(&names, &english))?;
            let label = name_at(&names, localized_index(&names, locale))?;
            let monospace = family
                .GetFirstMatchingFont(
                    DWRITE_FONT_WEIGHT_NORMAL,
                    DWRITE_FONT_STRETCH_NORMAL,
                    DWRITE_FONT_STYLE_NORMAL,
                )
                .and_then(|font| font.cast::<IDWriteFont1>())
                .map(|font| font.IsMonospacedFont().as_bool())
                .unwrap_or(false);
            fonts.push(FontInfo {
                name: label,
                family: canonical,
                style: "Regular".into(),
                is_monospace: monospace,
            });
        }
        Ok(normalize_catalog(fonts))
    }
}

#[cfg(not(target_os = "windows"))]
fn system_fonts() -> Result<Vec<FontInfo>, String> {
    Err("This font catalog adapter requires Windows".into())
}

#[cfg(test)]
mod tests {
    use super::*;
    fn font(family: &str, name: &str, mono: bool) -> FontInfo {
        FontInfo {
            family: family.into(),
            name: name.into(),
            style: "Regular".into(),
            is_monospace: mono,
        }
    }
    #[test]
    fn catalog_keeps_localized_names_and_non_monospace_families() {
        let fonts = normalize_catalog(vec![
            font("Microsoft YaHei", "微软雅黑", false),
            font("Consolas", "Consolas", true),
        ]);
        assert_eq!(fonts[0].family, "Consolas");
        assert!(fonts[0].is_monospace);
        assert_eq!(fonts[1].name, "微软雅黑");
        assert!(!fonts[1].is_monospace);
    }
    #[test]
    fn catalog_deduplicates_case_and_drops_empty_names_without_inventing_fonts() {
        let fonts = normalize_catalog(vec![
            font(" Consolas ", "", true),
            font("consolas", "Consolas", true),
            font(" ", "", false),
        ]);
        assert_eq!(fonts.len(), 1);
        assert_eq!(fonts[0].family, "Consolas");
        assert_eq!(fonts[0].name, "Consolas");
        assert!(normalize_catalog(vec![]).is_empty());
    }
    #[cfg(target_os = "windows")]
    #[test]
    #[ignore = "integration: reads the machine's installed Windows fonts"]
    fn directwrite_reads_installed_system_fonts() {
        let fonts = system_fonts().expect("DirectWrite system collection");
        assert!(!fonts.is_empty());
        assert!(fonts.iter().any(|font| font.is_monospace));
        println!("DirectWrite font families: {}", fonts.len());
    }
}
