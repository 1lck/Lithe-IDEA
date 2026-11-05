//! Output link matchers: patterns a plugin declares so the Run and Test
//! consoles turn matching text, such as a traceback frame, into a link.
//!
//! Core owns the whole decision. It checks declarations, finds matches in
//! console lines, and turns a match into a workspace location, or into the
//! groups a plugin backend resolves. A host only shows links and opens them.

use super::declarative::{invalid, Validation};
use crate::protocol::{CoreError, ErrorCode};
use regex::{Regex, RegexBuilder};
use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use std::collections::{BTreeSet, HashMap};
use std::sync::{Mutex, OnceLock};

/// Most matchers one plugin declares.
pub(crate) const MAX_MATCHERS: usize = 16;
/// Longest pattern source, in bytes.
const MAX_PATTERN_BYTES: usize = 512;
/// Compiled program budget; a pattern beyond it is refused, not truncated.
const REGEX_SIZE_LIMIT: usize = 256 * 1024;
/// Most named groups a pattern captures.
const MAX_GROUPS: usize = 8;
/// Longest matcher ID or group name.
const MAX_NAME: usize = 64;
/// Most console lines one match request carries.
const MAX_LINES: usize = 256;
/// Bytes of each line that are scanned; the rest is not linked.
const MAX_SCANNED_LINE_BYTES: usize = 4096;
/// Most links reported for one line.
const MAX_LINKS_PER_LINE: usize = 8;
/// Most plugins whose matchers one request applies.
const MAX_SOURCES: usize = 64;
/// Most workspace roots a relative path is resolved against.
const MAX_ROOTS: usize = 16;
/// Compiled patterns kept between requests.
const MAX_CACHED_PATTERNS: usize = 512;
/// Groups the host interprets itself when no `resolve` function is declared.
const LOCATION_GROUPS: &[&str] = &["path", "line", "column"];

/// One declared matcher.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct OutputLinkMatcher {
    /// Plugin-local ID.
    pub(crate) id: String,
    /// A Rust `regex` pattern matched against one console line.
    pub(crate) pattern: String,
    /// The console it applies to; both when absent.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) scope: Option<OutputScope>,
    /// A backend function that turns the named groups into a location.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) resolve: Option<OutputLinkResolve>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) enum OutputScope {
    Run,
    Test,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct OutputLinkResolve {
    /// A function of the plugin's `backend` 2 process.
    pub(crate) function: String,
}

/// Checks every declaration and sorts them by ID. `has_backend_functions`
/// says whether the plugin has a `backend` 2 process to call `resolve` on.
pub(crate) fn validate_declarations(
    matchers: &mut [OutputLinkMatcher],
    has_backend_functions: bool,
) -> Validation<()> {
    if matchers.len() > MAX_MATCHERS {
        return Err(invalid(
            "outputLinkMatchers",
            format!("A plugin declares at most {MAX_MATCHERS} output link matchers."),
        ));
    }
    let mut ids = BTreeSet::new();
    for (index, matcher) in matchers.iter().enumerate() {
        let field = format!("outputLinkMatchers[{index}]");
        if !is_name(&matcher.id, false) {
            return Err(invalid(
                format!("{field}.id"),
                "A matcher ID is a lowercase letter followed by up to 63 lowercase letters, digits, dots, underscores, or hyphens.",
            ));
        }
        if !ids.insert(matcher.id.as_str()) {
            return Err(invalid(
                format!("{field}.id"),
                "An output link matcher is declared more than once.",
            ));
        }
        if let Some(resolve) = &matcher.resolve {
            if !has_backend_functions {
                return Err(invalid(
                    format!("{field}.resolve"),
                    "A resolve function needs a backend 2 process.",
                ));
            }
            if !crate::lsp::interface::plugin_function::is_function_id(&resolve.function) {
                return Err(invalid(
                    format!("{field}.resolve.function"),
                    "The resolve function is not a valid function ID.",
                ));
            }
        }
        compile(&matcher.pattern, matcher.resolve.is_some())
            .map_err(|message| invalid(format!("{field}.pattern"), message))?;
    }
    matchers.sort_by(|left, right| left.id.cmp(&right.id));
    Ok(())
}

/// A lowercase local ID, or with `group` a camelCase capture group name.
fn is_name(value: &str, group: bool) -> bool {
    let mut chars = value.chars();
    value.len() <= MAX_NAME
        && chars.next().is_some_and(|first| first.is_ascii_lowercase())
        && chars.all(|next| {
            if group {
                next.is_ascii_alphanumeric()
            } else {
                next.is_ascii_lowercase()
                    || next.is_ascii_digit()
                    || matches!(next, '.' | '_' | '-')
            }
        })
}

/// Compiles a pattern and checks its groups. A pattern the host resolves
/// itself must capture `path` and no group other than the location ones.
fn compile(pattern: &str, resolved_by_backend: bool) -> Result<Regex, &'static str> {
    if pattern.is_empty() || pattern.len() > MAX_PATTERN_BYTES {
        return Err("A pattern is 1 to 512 bytes.");
    }
    let regex = RegexBuilder::new(pattern)
        .size_limit(REGEX_SIZE_LIMIT)
        .dfa_size_limit(REGEX_SIZE_LIMIT)
        .build()
        .map_err(|_| "The pattern is not a valid regular expression within the size limit.")?;
    let names: Vec<&str> = regex.capture_names().flatten().collect();
    if names.len() > MAX_GROUPS || names.iter().any(|name| !is_name(name, true)) {
        return Err("A pattern names at most 8 groups, each a camelCase name.");
    }
    if !resolved_by_backend {
        if !names.contains(&"path") {
            return Err("A pattern without a resolve function must capture a path group.");
        }
        if names.iter().any(|name| !LOCATION_GROUPS.contains(name)) {
            return Err(
                "Without a resolve function a pattern names only path, line, and column groups.",
            );
        }
    }
    if regex.is_match("") {
        return Err("A pattern must not match empty text.");
    }
    Ok(regex)
}

/// Compiled patterns by source and kind, so repeated requests do not
/// recompile them. Declarations were checked on load; a request is checked
/// again because it arrives from the host.
fn compiled(pattern: &str, resolved_by_backend: bool) -> Result<Regex, &'static str> {
    static CACHE: OnceLock<Mutex<HashMap<(String, bool), Regex>>> = OnceLock::new();
    let cache = CACHE.get_or_init(|| Mutex::new(HashMap::new()));
    let key = (pattern.to_string(), resolved_by_backend);
    if let Some(regex) = cache.lock().ok().and_then(|cache| cache.get(&key).cloned()) {
        return Ok(regex);
    }
    let regex = compile(pattern, resolved_by_backend)?;
    if let Ok(mut cache) = cache.lock() {
        if cache.len() >= MAX_CACHED_PATTERNS {
            cache.clear();
        }
        cache.insert(key, regex.clone());
    }
    Ok(regex)
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct MatchRequest {
    scope: OutputScope,
    platform: String,
    #[serde(default)]
    case_sensitive: Option<bool>,
    workspace_roots: Vec<String>,
    sources: Vec<MatchSource>,
    lines: Vec<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct MatchSource {
    #[serde(rename = "pluginID")]
    plugin_id: String,
    matchers: Vec<OutputLinkMatcher>,
}

fn request_error(message: &str) -> CoreError {
    CoreError::new(ErrorCode::InvalidRequest, message)
}

/// `outputLinks.match`: finds links in console lines with the matchers of
/// every installed plugin, in source order and then declaration order.
///
/// Each link reports its line index, its UTF-16 `start` and `length`, the
/// plugin and matcher, and either `location` with `paths` the host opens the
/// first existing one of, or `resolve` with the groups the backend function
/// receives. Matches overlapping an earlier link on the line are skipped.
pub(crate) fn match_lines(payload: Value) -> Result<Value, CoreError> {
    let request: MatchRequest = serde_json::from_value(payload).map_err(|error| {
        request_error("Invalid output link match request.").with_details(error.to_string())
    })?;
    if !matches!(request.platform.as_str(), "macos" | "windows" | "linux") {
        return Err(request_error("The platform is not supported."));
    }
    if request.lines.len() > MAX_LINES
        || request.sources.len() > MAX_SOURCES
        || request.workspace_roots.len() > MAX_ROOTS
        || request
            .sources
            .iter()
            .any(|source| source.matchers.len() > MAX_MATCHERS)
    {
        return Err(request_error("The output link match request is too large."));
    }
    let case_sensitive = request
        .case_sensitive
        .unwrap_or(request.platform == "linux");
    let mut active = Vec::new();
    for source in &request.sources {
        for matcher in &source.matchers {
            if matcher.scope.is_some_and(|scope| scope != request.scope) {
                continue;
            }
            let regex =
                compiled(&matcher.pattern, matcher.resolve.is_some()).map_err(|message| {
                    request_error("An output link matcher is invalid.")
                        .with_details(message.to_string())
                })?;
            active.push((source.plugin_id.as_str(), matcher, regex));
        }
    }
    let mut links = Vec::new();
    for (line_index, line) in request.lines.iter().enumerate() {
        let scanned = prefix(line, MAX_SCANNED_LINE_BYTES);
        let mut taken: Vec<(usize, usize)> = Vec::new();
        'matchers: for (plugin_id, matcher, regex) in &active {
            for captures in regex.captures_iter(scanned) {
                if taken.len() >= MAX_LINKS_PER_LINE {
                    break 'matchers;
                }
                let whole = captures.get(0).expect("group 0 always participates");
                if whole.start() == whole.end()
                    || taken
                        .iter()
                        .any(|(start, end)| whole.start() < *end && *start < whole.end())
                {
                    continue;
                }
                let mut groups = Map::new();
                for name in regex.capture_names().flatten() {
                    if let Some(group) = captures.name(name) {
                        groups.insert(name.to_string(), Value::from(group.as_str()));
                    }
                }
                let target = match &matcher.resolve {
                    Some(resolve) => json!({
                        "resolve": { "function": resolve.function, "groups": groups }
                    }),
                    None => match location(
                        &groups,
                        &request.workspace_roots,
                        &request.platform,
                        case_sensitive,
                    ) {
                        Some(location) => json!({ "location": location }),
                        None => continue,
                    },
                };
                taken.push((whole.start(), whole.end()));
                let mut link = json!({
                    "line": line_index,
                    "start": utf16_len(&scanned[..whole.start()]),
                    "length": utf16_len(whole.as_str()),
                    "pluginID": plugin_id,
                    "matcherID": matcher.id,
                });
                link.as_object_mut()
                    .expect("link is an object")
                    .extend(target.as_object().expect("target is an object").clone());
                links.push(link);
            }
        }
    }
    Ok(json!({ "links": links }))
}

/// The longest prefix of `line` within `limit` bytes that ends on a
/// character boundary.
fn prefix(line: &str, limit: usize) -> &str {
    if line.len() <= limit {
        return line;
    }
    let mut end = limit;
    while !line.is_char_boundary(end) {
        end -= 1;
    }
    &line[..end]
}

fn utf16_len(text: &str) -> usize {
    text.encode_utf16().count()
}

/// A location the host can open from the `path`, `line`, and `column`
/// groups. An absolute path must be inside a workspace root; a relative one
/// becomes one candidate per root. Nothing outside the workspace is linked.
fn location(
    groups: &Map<String, Value>,
    roots: &[String],
    platform: &str,
    case_sensitive: bool,
) -> Option<Value> {
    let raw = groups.get("path")?.as_str()?;
    let number = |name: &str| -> Option<Option<u64>> {
        match groups.get(name).and_then(Value::as_str) {
            None => Some(None),
            Some(text) => text
                .parse::<u64>()
                .ok()
                .filter(|value| (1..=u64::from(u32::MAX)).contains(value))
                .map(Some),
        }
    };
    let line = number("line")?;
    let column = number("column")?;
    let windows = platform == "windows";
    let text = if windows {
        raw.replace('\\', "/")
    } else {
        raw.to_string()
    };
    let absolute = text.starts_with('/') || (windows && text.as_bytes().get(1) == Some(&b':'));
    let mut paths = Vec::new();
    if absolute {
        let path = crate::toolchain::paths::normalize(&text, platform, true)?;
        if roots
            .iter()
            .any(|root| crate::toolchain::paths::within(&path, root, platform, case_sensitive))
        {
            paths.push(path);
        }
    } else {
        let relative = text.strip_prefix("./").unwrap_or(&text);
        for root in roots {
            if let Some(path) = crate::toolchain::paths::join(root, relative, platform) {
                if crate::toolchain::paths::within(&path, root, platform, case_sensitive) {
                    paths.push(path);
                }
            }
        }
    }
    if paths.is_empty() {
        return None;
    }
    let mut location = json!({ "paths": paths });
    let object = location.as_object_mut().expect("location is an object");
    if let Some(line) = line {
        object.insert("line".to_string(), Value::from(line));
    }
    if let Some(column) = column {
        object.insert("column".to_string(), Value::from(column));
    }
    Some(location)
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ResolutionRequest {
    reply: Value,
}

/// `outputLinks.decodeResolution`: checks a `resolve` function's reply,
/// `{uri, range?}` or `null`, and returns the 1-based location to open, or
/// `null` when the backend found nothing. Only `file:` URIs open.
pub(crate) fn decode_resolution(payload: Value) -> Result<Value, CoreError> {
    let request: ResolutionRequest = serde_json::from_value(payload).map_err(|error| {
        request_error("Invalid output link resolution.").with_details(error.to_string())
    })?;
    let reply = match request.reply {
        Value::Null => return Ok(Value::Null),
        Value::Object(reply) => reply,
        _ => return Err(request_error("A resolve reply is an object or null.")),
    };
    if reply
        .keys()
        .any(|key| !matches!(key.as_str(), "uri" | "range"))
    {
        return Err(request_error("A resolve reply has only uri and range."));
    }
    let uri = reply
        .get("uri")
        .and_then(Value::as_str)
        .filter(|uri| uri.len() <= 8192)
        .ok_or_else(|| request_error("A resolve reply needs a uri."))?;
    let path = uri
        .strip_prefix("file://")
        .filter(|path| path.starts_with('/'))
        .map(crate::lsp::interface::percent_decode)
        .filter(|path| !path.chars().any(char::is_control))
        .ok_or_else(|| request_error("A resolve reply names a local file URI."))?;
    let position = |name: &str| -> Result<Option<u64>, CoreError> {
        match reply
            .get("range")
            .map(|range| range.get("start").and_then(|start| start.get(name)))
        {
            None => Ok(None),
            Some(value) => value
                .and_then(Value::as_u64)
                .filter(|value| *value < u64::from(u32::MAX))
                .map(|value| Some(value + 1))
                .ok_or_else(|| {
                    request_error("A resolve reply range starts at a 0-based position.")
                }),
        }
    };
    let mut location = json!({ "path": path });
    let object = location.as_object_mut().expect("location is an object");
    if let Some(line) = position("line")? {
        object.insert("line".to_string(), Value::from(line));
    }
    if let Some(column) = position("character")? {
        object.insert("column".to_string(), Value::from(column));
    }
    Ok(location)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn matcher(value: Value) -> OutputLinkMatcher {
        serde_json::from_value(value).unwrap()
    }

    const PYTHON_FRAME: &str = r#"File "(?P<path>[^"]+)", line (?P<line>\d+)"#;
    const GO_PANIC: &str = r"^\s+(?P<path>/[^\s:]+\.go):(?P<line>\d+)";

    #[test]
    fn declarations_check_patterns_groups_and_resolve_functions() {
        let mut ok = vec![
            matcher(json!({"id": "python-frame", "pattern": PYTHON_FRAME, "scope": "run"})),
            matcher(json!({"id": "go-panic", "pattern": GO_PANIC})),
        ];
        validate_declarations(&mut ok, false).unwrap();
        assert_eq!(ok[0].id, "go-panic");

        for (value, backend, field) in [
            (
                json!({"id": "a", "pattern": r"(?P<line>\d+)"}),
                false,
                "pattern",
            ),
            (
                json!({"id": "a", "pattern": r"(?P<path>\S+)(?P<module>\w+)"}),
                false,
                "pattern",
            ),
            (
                json!({"id": "a", "pattern": r"(?P<path>\S*)"}),
                false,
                "pattern",
            ),
            (json!({"id": "a", "pattern": "("}), false, "pattern"),
            (json!({"id": "A", "pattern": PYTHON_FRAME}), false, "id"),
            (
                json!({"id": "a", "pattern": r"(?P<package>\w+)\.go", "resolve": {"function": "links.resolve"}}),
                false,
                "resolve",
            ),
        ] {
            let error = validate_declarations(&mut [matcher(value)], backend).unwrap_err();
            let at = error.field.clone().unwrap_or_default();
            assert!(at.ends_with(field), "{at} {}", error.message);
        }
        // A backend-resolved pattern names its own groups.
        validate_declarations(
            &mut [matcher(
                json!({"id": "a", "pattern": r"(?P<package>[\w/]+)\.(?P<symbol>\w+)\(",
                "resolve": {"function": "links.resolve"}}),
            )],
            true,
        )
        .unwrap();
        let duplicate = validate_declarations(
            &mut [
                matcher(json!({"id": "a", "pattern": PYTHON_FRAME})),
                matcher(json!({"id": "a", "pattern": GO_PANIC})),
            ],
            false,
        )
        .unwrap_err();
        assert!(duplicate.message.contains("more than once"));
    }

    #[test]
    fn matches_link_workspace_locations_with_utf16_ranges() {
        let reply = match_lines(json!({
            "scope": "run",
            "platform": "macos",
            "workspaceRoots": ["/work/app"],
            "sources": [{"pluginID": "example.python", "matchers": [
                {"id": "python-frame", "pattern": PYTHON_FRAME},
                {"id": "test-only", "pattern": r"(?P<path>\S+\.py)", "scope": "test"}
            ]}],
            "lines": [
                "  File \"/work/app/main.py\", line 12, in <module>",
                "é File \"./pkg/util.py\", line 3",
                "  File \"/usr/lib/python3/os.py\", line 1",
                "  File \"../outside.py\", line 1"
            ]
        }))
        .unwrap();
        let links = reply["links"].as_array().unwrap();
        assert_eq!(links.len(), 2, "{links:?}");
        assert_eq!(
            links[0]["location"],
            json!({"paths": ["/work/app/main.py"], "line": 12})
        );
        assert_eq!(links[0]["start"], 2);
        assert_eq!(links[1]["line"], 1);
        assert_eq!(links[1]["start"], 2);
        assert_eq!(
            links[1]["location"]["paths"],
            json!(["/work/app/pkg/util.py"])
        );
        assert_eq!(links[1]["matcherID"], "python-frame");
    }

    #[test]
    fn backend_resolved_matches_carry_groups_and_replies_decode() {
        let reply = match_lines(json!({
            "scope": "test",
            "platform": "linux",
            "workspaceRoots": ["/work"],
            "sources": [{"pluginID": "example.go", "matchers": [
                {"id": "go-symbol", "pattern": r"(?P<package>[\w/]+)\.(?P<symbol>\w+)\(",
                 "resolve": {"function": "links.resolve"}}
            ]}],
            "lines": ["main.handler(0x1)"]
        }))
        .unwrap();
        assert_eq!(
            reply["links"][0]["resolve"],
            json!({"function": "links.resolve", "groups": {"package": "main", "symbol": "handler"}})
        );
        assert_eq!(
            decode_resolution(json!({"reply": {"uri": "file:///work/main%20app.go",
                "range": {"start": {"line": 9, "character": 0}}}}))
            .unwrap(),
            json!({"path": "/work/main app.go", "line": 10, "column": 1})
        );
        assert_eq!(
            decode_resolution(json!({"reply": null})).unwrap(),
            Value::Null
        );
        assert!(decode_resolution(json!({"reply": {"uri": "https://example.com/a.go"}})).is_err());
        assert!(decode_resolution(json!({"reply": {"uri": "file:///a.go", "extra": 1}})).is_err());
    }

    #[test]
    fn requests_are_bounded() {
        let lines = vec![Value::from("x"); MAX_LINES + 1];
        assert!(match_lines(
            json!({"scope": "run", "platform": "macos", "workspaceRoots": [],
            "sources": [], "lines": lines})
        )
        .is_err());
        let long = format!(
            "{}File \"/w/a.py\", line 1",
            "x".repeat(MAX_SCANNED_LINE_BYTES)
        );
        let reply = match_lines(
            json!({"scope": "run", "platform": "macos", "workspaceRoots": ["/w"],
            "sources": [{"pluginID": "p", "matchers": [{"id": "f", "pattern": PYTHON_FRAME}]}],
            "lines": [long]}),
        )
        .unwrap();
        assert_eq!(reply["links"], json!([]));
    }
}
