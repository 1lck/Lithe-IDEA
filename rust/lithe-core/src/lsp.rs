use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use crate::error::{CoreError, ErrorCode};

const BUILTIN_LANGUAGE_PROVIDERS: &str = include_str!("../resources/lsp/language-providers.json");

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LspProviderCatalog {
    pub version: u32,
    pub providers: Vec<LspProviderDescriptor>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub diagnostics: Vec<LspProviderConfigDiagnostic>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LspProviderConfigDiagnostic {
    pub path: String,
    pub message: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LspProviderDescriptor {
    pub id: String,
    pub display_name: String,
    pub file_extensions: Vec<String>,
    pub file_names: Vec<String>,
    pub file_name_prefixes: Vec<String>,
    pub capabilities: Vec<LspProviderCapability>,
    pub activation_policy: LspActivationPolicy,
    pub language_id: Option<String>,
    pub language_ids_by_extension: BTreeMap<String, String>,
    pub language_ids_by_file_name: BTreeMap<String, String>,
}

#[derive(Debug, Clone, Copy, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum LspProviderCapability {
    Run,
    LanguageServer,
    DebugAdapter,
    Formatting,
    Testing,
}

#[derive(Debug, Clone, Copy, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum LspActivationPolicy {
    OnDemand,
    Always,
}

impl Default for LspActivationPolicy {
    fn default() -> Self {
        Self::OnDemand
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct LspProviderConfigDocument {
    #[serde(default = "default_config_version")]
    version: u32,
    #[serde(default)]
    providers: Vec<LspProviderPatch>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct LspProviderPatch {
    id: String,
    #[serde(default)]
    display_name: Option<String>,
    #[serde(default)]
    file_extensions: Option<Vec<String>>,
    #[serde(default)]
    file_names: Option<Vec<String>>,
    #[serde(default)]
    file_name_prefixes: Option<Vec<String>>,
    #[serde(default)]
    capabilities: Option<Vec<LspProviderCapability>>,
    #[serde(default)]
    activation_policy: Option<LspActivationPolicy>,
    #[serde(default)]
    language_id: Option<String>,
    #[serde(default)]
    language_ids_by_extension: Option<BTreeMap<String, String>>,
    #[serde(default)]
    language_ids_by_file_name: Option<BTreeMap<String, String>>,
    #[serde(default)]
    disabled: bool,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ApplyTextEditsRequest {
    pub text: String,
    #[serde(default)]
    pub edits: Vec<LspTextEdit>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LspTextEdit {
    pub range: LspRange,
    pub new_text: String,
}

#[derive(Debug, Clone, Copy, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LspRange {
    pub start: LspPosition,
    pub end: LspPosition,
}

#[derive(Debug, Clone, Copy, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LspPosition {
    pub line: i64,
    pub utf16_column: i64,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TextResponse {
    pub text: String,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PlainSnippetRequest {
    pub value: String,
}

pub fn provider_catalog_json(workspace_root: Option<&Path>) -> String {
    let catalog = provider_catalog(workspace_root);
    serde_json::to_string(&catalog)
        .unwrap_or_else(|_| "{\"version\":1,\"providers\":[]}".to_string())
}

pub fn apply_text_edits(request: ApplyTextEditsRequest) -> Result<TextResponse, CoreError> {
    let mut replacements = Vec::new();
    for edit in request.edits {
        let start = utf16_position_to_byte_offset(&request.text, edit.range.start)?;
        let end = utf16_position_to_byte_offset(&request.text, edit.range.end)?;
        if end < start {
            return Err(CoreError::new(
                ErrorCode::InvalidRequest,
                "Language server returned an invalid text range.",
            )
            .with_details("invalidRange"));
        }
        replacements.push((start, end, edit.new_text));
    }
    replacements.sort_by_key(|(start, _, _)| *start);
    for pair in replacements.windows(2) {
        if pair[0].1 > pair[1].0 {
            return Err(CoreError::new(
                ErrorCode::InvalidRequest,
                "Language server returned overlapping text edits.",
            )
            .with_details("overlappingEdits"));
        }
    }

    let mut text = request.text;
    for (start, end, replacement) in replacements.into_iter().rev() {
        text.replace_range(start..end, &replacement);
    }
    Ok(TextResponse { text })
}

pub fn plain_snippet(request: PlainSnippetRequest) -> TextResponse {
    TextResponse {
        text: snippet_plain_text(&request.value),
    }
}

pub fn provider_catalog(workspace_root: Option<&Path>) -> LspProviderCatalog {
    let mut diagnostics = Vec::new();
    let mut document = match parse_document(BUILTIN_LANGUAGE_PROVIDERS, "builtin:lsp") {
        Ok(document) => document,
        Err(message) => {
            diagnostics.push(LspProviderConfigDiagnostic {
                path: "builtin:lsp".to_string(),
                message,
            });
            LspProviderConfigDocument {
                version: 1,
                providers: Vec::new(),
            }
        }
    };

    if let Some(root) = workspace_root {
        let path = project_config_path(root);
        if path.is_file() {
            match std::fs::read_to_string(&path) {
                Ok(raw) => match parse_document(&raw, &path.display().to_string()) {
                    Ok(project_document) => {
                        document = merge_documents(document, project_document);
                    }
                    Err(message) => diagnostics.push(LspProviderConfigDiagnostic {
                        path: path.display().to_string(),
                        message,
                    }),
                },
                Err(error) => diagnostics.push(LspProviderConfigDiagnostic {
                    path: path.display().to_string(),
                    message: error.to_string(),
                }),
            }
        }
    }

    let mut providers = Vec::new();
    for patch in document.providers {
        if patch.disabled {
            continue;
        }
        providers.push(LspProviderDescriptor::from_patch(patch));
    }
    LspProviderCatalog {
        version: document.version,
        providers,
        diagnostics,
    }
}

fn parse_document(raw: &str, source: &str) -> Result<LspProviderConfigDocument, String> {
    serde_json::from_str(raw).map_err(|error| format!("{source}: {error}"))
}

fn merge_documents(
    mut base: LspProviderConfigDocument,
    project: LspProviderConfigDocument,
) -> LspProviderConfigDocument {
    base.version = project.version.max(base.version);
    for patch in project.providers {
        if let Some(existing) = base
            .providers
            .iter_mut()
            .find(|provider| provider.id == patch.id)
        {
            existing.apply(patch);
        } else {
            base.providers.push(patch);
        }
    }
    base
}

fn project_config_path(root: &Path) -> PathBuf {
    root.join(".lithe")
        .join("lsp")
        .join("language-providers.json")
}

fn default_config_version() -> u32 {
    1
}

impl LspProviderPatch {
    fn apply(&mut self, patch: LspProviderPatch) {
        if patch.display_name.is_some() {
            self.display_name = patch.display_name;
        }
        if patch.file_extensions.is_some() {
            self.file_extensions = patch.file_extensions;
        }
        if patch.file_names.is_some() {
            self.file_names = patch.file_names;
        }
        if patch.file_name_prefixes.is_some() {
            self.file_name_prefixes = patch.file_name_prefixes;
        }
        if patch.capabilities.is_some() {
            self.capabilities = patch.capabilities;
        }
        if patch.activation_policy.is_some() {
            self.activation_policy = patch.activation_policy;
        }
        if patch.language_id.is_some() {
            self.language_id = patch.language_id;
        }
        if patch.language_ids_by_extension.is_some() {
            self.language_ids_by_extension = patch.language_ids_by_extension;
        }
        if patch.language_ids_by_file_name.is_some() {
            self.language_ids_by_file_name = patch.language_ids_by_file_name;
        }
        self.disabled = patch.disabled;
    }
}

impl LspProviderDescriptor {
    fn from_patch(patch: LspProviderPatch) -> Self {
        let id = normalized_id(&patch.id);
        let display_name = patch
            .display_name
            .filter(|value| !value.trim().is_empty())
            .unwrap_or_else(|| id.clone());
        let capabilities = patch.capabilities.unwrap_or_else(|| {
            vec![
                LspProviderCapability::LanguageServer,
                LspProviderCapability::Formatting,
            ]
        });
        Self {
            id: id.clone(),
            display_name,
            file_extensions: normalized_values(patch.file_extensions.unwrap_or_default(), true),
            file_names: normalized_values(patch.file_names.unwrap_or_default(), false),
            file_name_prefixes: normalized_values(
                patch.file_name_prefixes.unwrap_or_default(),
                false,
            ),
            capabilities,
            activation_policy: patch.activation_policy.unwrap_or_default(),
            language_id: patch.language_id.filter(|value| !value.trim().is_empty()),
            language_ids_by_extension: normalized_map(
                patch.language_ids_by_extension.unwrap_or_default(),
                true,
            ),
            language_ids_by_file_name: normalized_map(
                patch.language_ids_by_file_name.unwrap_or_default(),
                false,
            ),
        }
    }
}

fn normalized_id(value: &str) -> String {
    value.trim().to_ascii_lowercase()
}

fn normalized_values(values: Vec<String>, trim_dot: bool) -> Vec<String> {
    let mut result = Vec::new();
    for value in values {
        let normalized = normalized_key(&value, trim_dot);
        if !normalized.is_empty() && !result.contains(&normalized) {
            result.push(normalized);
        }
    }
    result
}

fn normalized_map(values: BTreeMap<String, String>, trim_dot: bool) -> BTreeMap<String, String> {
    values
        .into_iter()
        .filter_map(|(key, value)| {
            let key = normalized_key(&key, trim_dot);
            if key.is_empty() || value.trim().is_empty() {
                None
            } else {
                Some((key, value))
            }
        })
        .collect()
}

fn normalized_key(value: &str, trim_dot: bool) -> String {
    let mut value = value.trim().to_ascii_lowercase();
    if trim_dot {
        value = value.trim_start_matches('.').to_string();
    }
    value
}

fn utf16_position_to_byte_offset(text: &str, position: LspPosition) -> Result<usize, CoreError> {
    if position.line < 0 || position.utf16_column < 0 {
        return Err(invalid_range_error());
    }
    let line = usize::try_from(position.line).map_err(|_| invalid_range_error())?;
    let column = usize::try_from(position.utf16_column).map_err(|_| invalid_range_error())?;
    let Some((start, contents_end)) = line_bounds(text, line) else {
        return Err(invalid_range_error());
    };
    Ok(byte_offset_for_utf16_column(
        text,
        start,
        contents_end,
        column,
    ))
}

fn invalid_range_error() -> CoreError {
    CoreError::new(
        ErrorCode::InvalidRequest,
        "Language server returned an invalid text range.",
    )
    .with_details("invalidRange")
}

fn line_bounds(text: &str, target_line: usize) -> Option<(usize, usize)> {
    let bytes = text.as_bytes();
    let mut line = 0;
    let mut start = 0;
    for (index, byte) in bytes.iter().enumerate() {
        if *byte == b'\n' {
            if line == target_line {
                let contents_end = if index > start && bytes[index - 1] == b'\r' {
                    index - 1
                } else {
                    index
                };
                return Some((start, contents_end));
            }
            line += 1;
            start = index + 1;
        }
    }
    if line == target_line {
        Some((start, text.len()))
    } else {
        None
    }
}

fn byte_offset_for_utf16_column(
    text: &str,
    start: usize,
    contents_end: usize,
    column: usize,
) -> usize {
    let mut units = 0;
    for (relative, character) in text[start..contents_end].char_indices() {
        let next_units = units + character.len_utf16();
        if next_units > column {
            return start + relative;
        }
        units = next_units;
        if units == column {
            return start + relative + character.len_utf8();
        }
    }
    contents_end
}

fn snippet_plain_text(value: &str) -> String {
    let mut output = String::new();
    let mut chars = value.chars().peekable();
    while let Some(character) = chars.next() {
        if character != '$' {
            output.push(character);
            continue;
        }
        match chars.peek().copied() {
            Some('{') => {
                chars.next();
                if !consume_digits(&mut chars) {
                    output.push_str("${");
                    continue;
                }
                match chars.peek().copied() {
                    Some(':') => {
                        chars.next();
                        output.push_str(&consume_until_placeholder_end(&mut chars));
                    }
                    Some('}') => {
                        chars.next();
                    }
                    _ => output.push('$'),
                }
            }
            Some(next) if next.is_ascii_digit() => {
                consume_digits(&mut chars);
            }
            _ => output.push('$'),
        }
    }
    output
}

fn consume_digits<I>(chars: &mut std::iter::Peekable<I>) -> bool
where
    I: Iterator<Item = char>,
{
    let mut consumed = false;
    while chars
        .peek()
        .is_some_and(|character| character.is_ascii_digit())
    {
        chars.next();
        consumed = true;
    }
    consumed
}

fn consume_until_placeholder_end<I>(chars: &mut std::iter::Peekable<I>) -> String
where
    I: Iterator<Item = char>,
{
    let mut value = String::new();
    for character in chars.by_ref() {
        if character == '}' {
            break;
        }
        value.push(character);
    }
    value
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;
    use std::fs;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn temporary_root(label: &str) -> PathBuf {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system clock should be valid")
            .as_nanos();
        std::env::temp_dir().join(format!("lithe-lsp-{label}-{}-{nonce}", std::process::id()))
    }

    #[test]
    fn builtin_catalog_describes_market_lsp_providers() {
        let catalog = provider_catalog(None);
        let ids: Vec<_> = catalog
            .providers
            .iter()
            .map(|provider| provider.id.as_str())
            .collect();
        assert!(ids.starts_with(&["java", "go", "python", "node", "rust"]));
        assert!(ids.contains(&"swift"));
        assert!(ids.contains(&"clangd"));
        assert!(ids.contains(&"dockerfile"));
        assert!(ids.contains(&"graphql"));
        let clangd = catalog
            .providers
            .iter()
            .find(|provider| provider.id == "clangd")
            .expect("clangd provider should exist");
        assert_eq!(
            clangd.language_ids_by_extension.get("m"),
            Some(&"objective-c".to_string())
        );
    }

    #[test]
    fn project_config_extends_and_overrides_builtin_catalog() {
        let root = temporary_root("project-config");
        fs::create_dir_all(root.join(".lithe/lsp")).unwrap();
        fs::write(
            root.join(".lithe/lsp/language-providers.json"),
            r#"{
              "version": 1,
              "providers": [
                {
                  "id": "roc",
                  "displayName": "Roc",
                  "fileExtensions": ["roc"],
                  "capabilities": ["languageServer", "formatting"],
                  "activationPolicy": "onDemand",
                  "languageId": "roc"
                },
                {
                  "id": "swift",
                  "fileExtensions": ["swift", "swiftinterface"]
                },
                {
                  "id": "perl",
                  "disabled": true
                }
              ]
            }"#,
        )
        .unwrap();

        let catalog = provider_catalog(Some(&root));
        assert!(catalog
            .providers
            .iter()
            .any(|provider| provider.id == "roc"));
        let swift = catalog
            .providers
            .iter()
            .find(|provider| provider.id == "swift")
            .expect("swift provider should still exist");
        assert!(swift
            .file_extensions
            .contains(&"swiftinterface".to_string()));
        assert!(!catalog
            .providers
            .iter()
            .any(|provider| provider.id == "perl"));

        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn ffi_json_is_a_standalone_catalog_document() {
        let raw = provider_catalog_json(None);
        let value: Value = serde_json::from_str(&raw).expect("catalog should be JSON");
        assert_eq!(value["version"], 1);
        assert!(value["providers"].as_array().unwrap().len() > 10);
        assert!(value.get("ok").is_none());
        assert!(value.get("command").is_none());
    }

    #[test]
    fn text_edits_use_lsp_utf16_positions() {
        let response = apply_text_edits(ApplyTextEditsRequest {
            text: "one 😀\ntwo three\n".to_string(),
            edits: vec![
                LspTextEdit {
                    range: LspRange {
                        start: LspPosition {
                            line: 0,
                            utf16_column: 4,
                        },
                        end: LspPosition {
                            line: 0,
                            utf16_column: 6,
                        },
                    },
                    new_text: "rocket".to_string(),
                },
                LspTextEdit {
                    range: LspRange {
                        start: LspPosition {
                            line: 1,
                            utf16_column: 4,
                        },
                        end: LspPosition {
                            line: 1,
                            utf16_column: 9,
                        },
                    },
                    new_text: "four".to_string(),
                },
            ],
        })
        .unwrap();

        assert_eq!(response.text, "one rocket\ntwo four\n");
    }

    #[test]
    fn text_edits_reject_invalid_and_overlapping_ranges() {
        let invalid = apply_text_edits(ApplyTextEditsRequest {
            text: "one line".to_string(),
            edits: vec![LspTextEdit {
                range: LspRange {
                    start: LspPosition {
                        line: 9,
                        utf16_column: 0,
                    },
                    end: LspPosition {
                        line: 9,
                        utf16_column: 1,
                    },
                },
                new_text: "x".to_string(),
            }],
        })
        .unwrap_err();
        assert_eq!(invalid.details.as_deref(), Some("invalidRange"));

        let overlapping = apply_text_edits(ApplyTextEditsRequest {
            text: "one line".to_string(),
            edits: vec![
                LspTextEdit {
                    range: LspRange {
                        start: LspPosition {
                            line: 0,
                            utf16_column: 0,
                        },
                        end: LspPosition {
                            line: 0,
                            utf16_column: 4,
                        },
                    },
                    new_text: "a".to_string(),
                },
                LspTextEdit {
                    range: LspRange {
                        start: LspPosition {
                            line: 0,
                            utf16_column: 2,
                        },
                        end: LspPosition {
                            line: 0,
                            utf16_column: 6,
                        },
                    },
                    new_text: "b".to_string(),
                },
            ],
        })
        .unwrap_err();
        assert_eq!(overlapping.details.as_deref(), Some("overlappingEdits"));
    }

    #[test]
    fn snippet_plain_text_removes_tab_stops_and_keeps_defaults() {
        assert_eq!(snippet_plain_text("print(${1:value})$0"), "print(value)");
        assert_eq!(snippet_plain_text("${1:let} ${2:name} = $3"), "let name = ");
    }
}
