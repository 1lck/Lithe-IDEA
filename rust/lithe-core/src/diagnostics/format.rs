//! Formats validated canonical redacted records for issue reports, without native I/O or UI copy.

use super::channel::LogError;
use super::query_v2::redact_record;
use super::record::{decode_line, render, DecodedLogLine};
use serde::{Deserialize, Serialize};
use serde_json::json;

const MAX_LINES: usize = 10000;
const MAX_BYTES: usize = 4 * 1024 * 1024;

/// Fixed technical export format; these names are not localized interface text.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum LogRecordsFormat {
    /// Pretty JSON record, array, or environment envelope.
    Json,
    /// Issue-readable environment header and canonical ndjson evidence block.
    Markdown,
}
/// Host-gathered optional environment facts, owned for this formatting operation.
#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LogRecordsEnvironment {
    /// Host-reported Lithe version.
    pub app_version: String,
    /// Host-reported operating system version.
    pub os_version: String,
    /// Host-reported CPU architecture.
    pub architecture: String,
    /// Host-reported installed plugin identities, in supplied order.
    pub plugins: Vec<String>,
}
/// Only previously returned canonical redacted lines are accepted; arbitrary text is rejected.
#[derive(Debug, Deserialize)]
pub struct FormatLogRecordsRequest {
    /// Canonical redacted records, at most 10000 lines and 4 MiB including separators.
    pub lines: Vec<String>,
    /// Technical report encoding selected by the host.
    pub format: LogRecordsFormat,
    /// Optional bounded native environment snapshot.
    #[serde(default)]
    pub environment: Option<LogRecordsEnvironment>,
}
/// Fixed English technical headings and JSON keys are report syntax, not translatable UI copy.
#[derive(Debug, Serialize)]
pub struct FormattedLogRecords {
    /// Complete copy payload owned by the caller.
    pub text: String,
}
/// Revalidates canonical grammar and redaction before copying. -32062 is a copy-input budget,
/// -32063 is a noncanonical/unsafe record; decoder errors retain their existing precise meanings.
pub fn format_log_records(
    request: FormatLogRecordsRequest,
) -> Result<FormattedLogRecords, LogError> {
    let bytes = request
        .lines
        .iter()
        .try_fold(0usize, |sum, line| sum.checked_add(line.len() + 1));
    let environment_bytes = request.environment.as_ref().map_or(0, |e| {
        e.app_version
            .len()
            .saturating_add(e.os_version.len())
            .saturating_add(e.architecture.len())
            .saturating_add(
                e.plugins
                    .iter()
                    .fold(0usize, |sum, p| sum.saturating_add(p.len())),
            )
    });
    if request.lines.len() > MAX_LINES
        || bytes.is_none_or(|n| n > MAX_BYTES)
        || environment_bytes > 64 * 1024
        || request
            .environment
            .as_ref()
            .is_some_and(|e| e.plugins.len() > 1000)
    {
        return Err(LogError::new(-32062, "Log copy input exceeds budget"));
    }
    let mut records = Vec::with_capacity(request.lines.len());
    for line in &request.lines {
        let DecodedLogLine::Record(record) = decode_line(line)? else {
            return Err(LogError::new(
                -32063,
                "Expected canonical redacted log record",
            ));
        };
        if render(&redact_record(record.clone())) != *line {
            return Err(LogError::new(
                -32063,
                "Expected canonical redacted log record",
            ));
        }
        records.push(record);
    }
    let text = match request.format {
        LogRecordsFormat::Json => {
            let value = if let Some(environment) = request.environment {
                json!({"environment":environment,"records":records})
            } else if records.len() == 1 {
                json!(records[0])
            } else {
                json!(records)
            };
            serde_json::to_string_pretty(&value).expect("owned report values serialize")
        }
        LogRecordsFormat::Markdown => {
            let mut text = "**Lithe**".to_owned();
            if let Some(e) = request.environment {
                // JSON string escaping keeps untrusted environment values on one technical line.
                for value in [&e.app_version, &e.os_version, &e.architecture] {
                    text.push_str(" · ");
                    text.push_str(&serde_json::to_string(value).expect("string serializes"));
                }
                if !e.plugins.is_empty() {
                    text.push_str("\n\nPlugins: ");
                    text.push_str(&serde_json::to_string(&e.plugins).expect("plugins serialize"));
                }
            }
            // A longer fence prevents any record content from ending the evidence block.
            let longest = request
                .lines
                .iter()
                .flat_map(|s| s.split(|c| c != '`'))
                .map(str::len)
                .max()
                .unwrap_or(0);
            let fence = "`".repeat(3.max(longest + 1));
            text.push_str(&format!("\n\n{fence}ndjson\n"));
            for line in request.lines {
                text.push_str(&line);
                text.push('\n');
            }
            text.push_str(&fence);
            text.push('\n');
            text
        }
    };
    Ok(FormattedLogRecords { text })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn copy_formats_and_environment_preserve_validated_evidence() {
        let line = "2026-11-03T00:00:00.000Z WARN seq=1 event=app.failed msg=failed";
        for (count, environment) in [(1, false), (2, false), (1, true), (0, false)] {
            let input = json!({"lines":vec![line; count],"format":"json","environment":if environment { json!({"appVersion":"1","osVersion":"macOS","architecture":"arm64","plugins":["p"]}) } else { serde_json::Value::Null }});
            let text = format_log_records(serde_json::from_value(input).unwrap())
                .unwrap()
                .text;
            let value: serde_json::Value = serde_json::from_str(&text).unwrap();
            if environment {
                assert_eq!(value["records"].as_array().unwrap().len(), count);
            } else if count == 1 {
                assert_eq!(value["msg"], "failed");
            } else {
                assert_eq!(value.as_array().unwrap().len(), count);
            }
        }
        let text = format_log_records(
            serde_json::from_value(json!({"lines":[line],"format":"markdown"})).unwrap(),
        )
        .unwrap()
        .text;
        assert_eq!(text, format!("**Lithe**\n\n```ndjson\n{line}\n```\n"));
        for (lines, code) in [
            (vec!["invalid".into()], -32035),
            (vec![format!("{line} token=unsafe")], -32063),
            (vec![line.into(); 10001], -32062),
            (vec!["x".repeat(MAX_BYTES)], -32062),
        ] {
            assert_eq!(
                format_log_records(FormatLogRecordsRequest {
                    lines,
                    format: LogRecordsFormat::Json,
                    environment: None
                })
                .unwrap_err()
                .code,
                code
            );
        }
    }
}
