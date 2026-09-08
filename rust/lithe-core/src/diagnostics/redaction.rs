//! Text redaction rules applied to diagnostic bundles exported by any host.

use regex::Regex;
use serde::{Deserialize, Serialize};
use std::sync::LazyLock;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Raw text a host wants scrubbed before it leaves the machine in a diagnostic bundle.
pub struct RedactTextRequest {
    pub text: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
/// Text with credentials, tokens, and home-directory paths replaced by stable placeholders.
pub struct RedactTextResponse {
    pub redacted: String,
}

static AUTHORIZATION_HEADER: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)\b(authorization)\s*[:=]\s*(?:bearer|basic)\s+[^\s,;&]+").expect("valid regex")
});

// Matches a sensitive key followed by its value. The key may carry a trailing
// quote (JSON `"password":`), and the value is either a quoted string, which
// can contain spaces, or a bare run of non-delimiter characters. Matching the
// whole quoted value keeps secrets like `password="hunter two"` from leaking a
// trailing fragment past the first space.
static SENSITIVE_ASSIGNMENT: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(
        r#"(?i)\b(token|authorization|password|secret|api[_-]?key|cookie)["']?\s*[:=]\s*(?:"[^"]*"|'[^']*'|[^\s,;&]+)"#,
    )
    .expect("valid regex")
});

static SENSITIVE_QUERY_PARAMETER: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)([?&](?:access_token|api_key|token|key|auth))=[^&#\s]+").expect("valid regex")
});

static CREDENTIAL_SHAPE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(
        r"(?i)\b(?:gh[pousr]_[A-Za-z0-9_]{8,}|github_pat_[A-Za-z0-9_]{8,}|sk-[A-Za-z0-9_-]{8,})\b",
    )
    .expect("valid regex")
});

// Matches an absolute home-directory prefix on macOS/Linux (a path segment
// under a top-level "Users" or "home" directory) and on Windows (a drive
// letter followed by a "Users" segment), so a path collected on either host
// collapses to the same placeholder before leaving the machine.
static HOME_DIRECTORY_PATH: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)(?:/(?:Users|home)/[^/\s]+|[A-Z]:\\Users\\[^\\\s]+)").expect("valid regex")
});

/// Redacts credentials, tokens, and home-directory paths from diagnostic text.
///
/// Hosts run this over log lines, panic reports, and any other text bound for
/// a diagnostic bundle before it is written to disk or zipped. The
/// authorization-header and key/value patterns both collapse to the same
/// `key=<redacted>` shape, which makes re-running this function over already
/// redacted text a no-op instead of corrupting the separator.
pub fn redact_text(request: RedactTextRequest) -> RedactTextResponse {
    let mut text = request.text;
    text = AUTHORIZATION_HEADER
        .replace_all(&text, "$1=<redacted>")
        .into_owned();
    text = SENSITIVE_ASSIGNMENT
        .replace_all(&text, "$1=<redacted>")
        .into_owned();
    text = SENSITIVE_QUERY_PARAMETER
        .replace_all(&text, "$1=<redacted>")
        .into_owned();
    text = CREDENTIAL_SHAPE
        .replace_all(&text, "<redacted>")
        .into_owned();
    text = HOME_DIRECTORY_PATH
        .replace_all(&text, "<HOME>")
        .into_owned();

    RedactTextResponse { redacted: text }
}

#[cfg(test)]
mod tests {
    use super::{redact_text, RedactTextRequest};

    fn redact(text: &str) -> String {
        redact_text(RedactTextRequest {
            text: text.to_owned(),
        })
        .redacted
    }

    #[test]
    fn redacts_bearer_authorization_headers() {
        assert_eq!(
            redact("Authorization: Bearer abc123def456"),
            "Authorization=<redacted>"
        );
    }

    #[test]
    fn redacts_sensitive_key_value_pairs() {
        assert_eq!(redact("password=hunter2"), "password=<redacted>");
        assert_eq!(redact("api_key: sk-test-value"), "api_key=<redacted>");
    }

    #[test]
    fn redacts_quoted_values_containing_spaces() {
        // A quoted value must be redacted in full; matching only up to the
        // first space would leak the remainder (`two"`).
        assert_eq!(redact(r#"password="hunter two""#), "password=<redacted>");
        assert_eq!(redact("secret='multi word secret'"), "secret=<redacted>");
    }

    #[test]
    fn redacts_json_style_sensitive_fields() {
        // JSON quotes the key, so a quote sits between the key name and the
        // colon. The secret value must still be scrubbed.
        assert_eq!(
            redact(r#"{"password": "hunter2"}"#),
            r#"{"password=<redacted>}"#
        );
        assert_eq!(
            redact(r#"{"token":"ghp_value_here"}"#),
            r#"{"token=<redacted>}"#
        );
    }

    #[test]
    fn redacts_sensitive_query_parameters() {
        assert_eq!(
            redact("https://api.example.com/x?token=abc&user=me"),
            "https://api.example.com/x?token=<redacted>&user=me"
        );
    }

    #[test]
    fn redacts_known_credential_shapes() {
        assert_eq!(
            redact("token ghp_1234567890abcdef in log"),
            "token <redacted> in log"
        );
        assert_eq!(
            redact("uses github_pat_11ABCDEFG0123456789 here"),
            "uses <redacted> here"
        );
    }

    #[test]
    fn redacts_macos_home_directory_paths() {
        assert_eq!(
            redact("/Users/workspace-owner/src/website/file.log"),
            "<HOME>/src/website/file.log"
        );
    }

    #[test]
    fn redacts_windows_home_directory_paths() {
        assert_eq!(
            redact("C:\\Users\\workspace-owner\\AppData\\lithe.log"),
            "<HOME>\\AppData\\lithe.log"
        );
    }

    #[test]
    fn leaves_unrelated_text_untouched() {
        assert_eq!(
            redact("plain diagnostic line with no secrets"),
            "plain diagnostic line with no secrets"
        );
    }

    #[test]
    fn is_idempotent_when_applied_twice() {
        let once = redact("Authorization: Bearer abc123def456 token=xyz");
        let twice = redact_text(RedactTextRequest { text: once.clone() }).redacted;
        assert_eq!(once, twice);
    }
}
