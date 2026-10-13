//! Read-only system date/time presentation, including Windows user format overrides.

use chrono::{DateTime, Datelike, Local, Timelike, Utc};
use serde::Serialize;

#[derive(Serialize)]
pub struct DateTimePresentation {
    date: String,
    time: String,
}

#[tauri::command]
pub fn format_system_date_time(timestamp: i64) -> Result<DateTimePresentation, String> {
    let instant = DateTime::<Utc>::from_timestamp_millis(timestamp)
        .ok_or_else(|| "Invalid date/time timestamp".to_string())?;
    let local = instant.with_timezone(&Local);
    #[cfg(windows)]
    {
        use windows_sys::Win32::Foundation::SYSTEMTIME;
        let date = SYSTEMTIME {
            wYear: u16::try_from(local.year())
                .map_err(|_| "Date is outside the system format range")?,
            wMonth: local.month() as u16,
            wDay: local.day() as u16,
            wDayOfWeek: local.weekday().num_days_from_sunday() as u16,
            wHour: local.hour() as u16,
            wMinute: local.minute() as u16,
            wSecond: local.second() as u16,
            wMilliseconds: 0,
        };
        format_windows_date_time(&date, std::ptr::null())
    }
    #[cfg(not(windows))]
    Ok(DateTimePresentation {
        date: local.format("%x").to_string(),
        time: local.format("%H:%M").to_string(),
    })
}

#[cfg(windows)]
fn format_windows_date_time(
    date: &windows_sys::Win32::Foundation::SYSTEMTIME,
    locale: *const u16,
) -> Result<DateTimePresentation, String> {
    use windows_sys::Win32::Globalization::{
        GetDateFormatEx, GetLocaleInfoEx, GetTimeFormatEx, DATE_SHORTDATE, LOCALE_NOUSEROVERRIDE,
        LOCALE_SSHORTTIME,
    };
    let flags = if locale.is_null() {
        0
    } else {
        LOCALE_NOUSEROVERRIDE
    };
    // Removing seconds from the long-time format can disagree with the independently configured short time.
    let mut short_time_pattern = vec![0u16; 128];
    let pattern_length = unsafe {
        GetLocaleInfoEx(
            locale,
            LOCALE_SSHORTTIME | flags,
            short_time_pattern.as_mut_ptr(),
            short_time_pattern.len() as i32,
        )
    };
    if pattern_length <= 1 {
        return Err(format!(
            "Could not read system short time format: {}",
            std::io::Error::last_os_error()
        ));
    }
    // Null locale/format selects the user's Windows settings. No registry or installed resources are written.
    let read = |is_date: bool| -> Result<String, String> {
        let call = |buffer: *mut u16, capacity: i32| unsafe {
            // SYSTEMTIME and UTF-16 buffers remain alive throughout the synchronous OS call.
            if is_date {
                GetDateFormatEx(
                    locale,
                    DATE_SHORTDATE | flags,
                    date,
                    std::ptr::null(),
                    buffer,
                    capacity,
                    std::ptr::null(),
                )
            } else {
                GetTimeFormatEx(
                    locale,
                    // An explicit pattern requires zero flags; user overrides were selected above.
                    0,
                    date,
                    short_time_pattern.as_ptr(),
                    buffer,
                    capacity,
                )
            }
        };
        let length = call(std::ptr::null_mut(), 0);
        if length <= 1 {
            return Err(format!(
                "Could not read system date/time format: {}",
                std::io::Error::last_os_error()
            ));
        }
        let mut buffer = vec![0u16; length as usize];
        let written = call(buffer.as_mut_ptr(), length);
        if written <= 1 {
            return Err(format!(
                "Could not format system date/time: {}",
                std::io::Error::last_os_error()
            ));
        }
        String::from_utf16(&buffer[..written as usize - 1]).map_err(|error| error.to_string())
    };
    Ok(DateTimePresentation {
        date: read(true)?,
        time: read(false)?,
    })
}

#[cfg(all(test, windows))]
mod tests {
    use super::*;
    use windows_sys::Win32::Foundation::SYSTEMTIME;

    #[test]
    fn native_english_formats_follow_regional_date_order_and_time_cycle() {
        // Explicit locales keep this integration test independent of the developer's Windows settings.
        let date = SYSTEMTIME {
            wYear: 2026,
            wMonth: 10,
            wDay: 4,
            wHour: 16,
            wMinute: 44,
            ..Default::default()
        };
        let us: Vec<u16> = "en-US\0".encode_utf16().collect();
        let gb: Vec<u16> = "en-GB\0".encode_utf16().collect();
        let american = format_windows_date_time(&date, us.as_ptr()).unwrap();
        let british = format_windows_date_time(&date, gb.as_ptr()).unwrap();
        assert_eq!(american.date, "10/4/2026");
        assert!(american.time.starts_with("4:44 "));
        assert_eq!(british.date, "04/10/2026");
        assert_eq!(british.time, "16:44");
    }

    #[test]
    fn invalid_timestamp_is_rejected_before_native_formatting() {
        assert!(format_system_date_time(i64::MAX).is_err());
    }
}
