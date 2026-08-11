use super::*;
use serde_json::{json, Value};
use std::fs;
use std::path::PathBuf;
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
    let swift = catalog
        .providers
        .iter()
        .find(|provider| provider.id == "swift")
        .expect("swift provider should exist");
    let swift_launch = swift
        .language_server_launch
        .as_ref()
        .expect("swift launch descriptor should exist");
    assert_eq!(
        swift_launch.executable_names,
        vec!["sourcekit-lsp".to_string()]
    );
    let go = catalog
        .providers
        .iter()
        .find(|provider| provider.id == "go")
        .expect("go provider should exist");
    let go_installation = go
        .language_server_installation
        .as_ref()
        .expect("go installation descriptor should exist");
    assert_eq!(go_installation.homebrew_formula.as_deref(), Some("gopls"));
    assert_eq!(
        go_installation.official_download_url.as_deref(),
        Some("https://go.dev/gopls/")
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
                  "fileExtensions": ["swift", "swiftinterface"],
                  "languageServerLaunch": {
                    "executableNames": ["custom-sourcekit-lsp"],
                    "arguments": ["--stdio"],
                    "environment": {
                      "SOURCEKIT_TOOLCHAIN": "custom"
                    },
                    "initializationOptions": {
                      "indexing": true
                    }
                  },
                  "languageServerInstallation": {
                    "homebrewFormula": "custom-sourcekit-lsp",
                    "officialDownloadURL": "https://example.com/sourcekit-lsp"
                  }
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
    let swift_launch = swift
        .language_server_launch
        .as_ref()
        .expect("swift launch descriptor should be overridden");
    assert_eq!(
        swift_launch.executable_names,
        vec!["custom-sourcekit-lsp".to_string()]
    );
    assert_eq!(swift_launch.arguments, vec!["--stdio".to_string()]);
    assert_eq!(
        swift_launch.environment.get("SOURCEKIT_TOOLCHAIN"),
        Some(&"custom".to_string())
    );
    assert_eq!(
        swift_launch.initialization_options,
        Some(json!({ "indexing": true }))
    );
    let swift_installation = swift
        .language_server_installation
        .as_ref()
        .expect("swift installation descriptor should be overridden");
    assert_eq!(
        swift_installation.homebrew_formula.as_deref(),
        Some("custom-sourcekit-lsp")
    );
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
    assert_eq!(value["version"], 2);
    assert!(value["providers"].as_array().unwrap().len() > 10);
    assert!(value.get("ok").is_none());
    assert!(value.get("command").is_none());
}

#[test]
fn project_catalog_reports_unknown_configuration_fields() {
    let root = temporary_root("project-config-unknown-field");
    fs::create_dir_all(root.join(".lithe/lsp")).unwrap();
    fs::write(
        root.join(".lithe/lsp/language-providers.json"),
        r#"{
              "version": 2,
              "providers": [{ "id": "go", "languageServerLanch": {} }]
            }"#,
    )
    .unwrap();

    let catalog = provider_catalog(Some(&root));
    assert_eq!(catalog.diagnostics.len(), 1);
    assert!(catalog.diagnostics[0].message.contains("unknown field"));
    assert!(catalog.providers.iter().any(|provider| provider.id == "go"));

    fs::remove_dir_all(root).unwrap();
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

#[test]
fn builtin_completion_returns_current_file_identifiers_for_prefix() {
    let response = builtin_completions(BuiltinRequest {
        file_path: "/tmp/main.swift".to_string(),
        text: "struct RocketShip {}\nlet rocketSpeed = Roc\n".to_string(),
        position: LspPosition {
            line: 1,
            utf16_column: 19,
        },
    })
    .unwrap();

    assert!(response.items.iter().any(|item| item.label == "RocketShip"));
    let item = response
        .items
        .iter()
        .find(|item| item.label == "RocketShip")
        .unwrap();
    assert_eq!(item.text_edit.range.start.utf16_column, 18);
    assert_eq!(item.text_edit.new_text, "RocketShip");
}

#[test]
fn builtin_hover_returns_current_identifier_range() {
    let response = builtin_hover(BuiltinRequest {
        file_path: "/tmp/main.rs".to_string(),
        text: "fn launch() {}\n".to_string(),
        position: LspPosition {
            line: 0,
            utf16_column: 4,
        },
    })
    .unwrap();

    let hover = response.hover.unwrap();
    assert_eq!(hover.contents, "`launch`");
    assert_eq!(hover.range.start.utf16_column, 3);
    assert_eq!(hover.range.end.utf16_column, 9);
}

#[test]
fn builtin_navigation_prefers_declarations_and_finds_references() {
    let text = "let service = 1\nprint(service)\n";
    let definitions = builtin_navigation(BuiltinNavigationRequest {
        file_path: "/tmp/main.swift".to_string(),
        text: text.to_string(),
        position: LspPosition {
            line: 1,
            utf16_column: 8,
        },
        method: "textDocument/definition".to_string(),
    })
    .unwrap();
    assert_eq!(definitions.locations.len(), 1);
    assert_eq!(definitions.locations[0].range.start.line, 0);
    assert_eq!(definitions.locations[0].range.start.utf16_column, 4);

    let references = builtin_navigation(BuiltinNavigationRequest {
        file_path: "/tmp/main.swift".to_string(),
        text: text.to_string(),
        position: LspPosition {
            line: 1,
            utf16_column: 8,
        },
        method: "textDocument/references".to_string(),
    })
    .unwrap();
    assert_eq!(references.locations.len(), 2);
}

#[test]
fn file_uri_paths_decode_spaces_and_utf8_characters() {
    assert_eq!(
        file_path_from_uri("file:///tmp/go%20project/%E4%B8%AD%E6%96%87/main.go"),
        "/tmp/go project/中文/main.go"
    );
}

#[test]
fn client_core_initializes_and_applies_server_capabilities() {
    let initialized = client_initialize(ClientInitializeRequest {
        state: LspClientState::default(),
        root_uri: "file:///tmp/project".to_string(),
        process_id: Some(42),
        initialization_options: Some(json!({
            "ui.semanticTokens": true
        })),
    })
    .unwrap();
    assert_eq!(
        initialized.state.pending_requests.get("1").unwrap(),
        "initialize"
    );
    let initialize_message: Value =
        serde_json::from_str(&initialized.messages[0]).expect("initialize JSON");
    assert_eq!(initialize_message["method"], "initialize");
    assert_eq!(
        initialize_message["params"]["rootUri"],
        "file:///tmp/project"
    );
    let client_capabilities = &initialize_message["params"]["capabilities"];
    assert_eq!(client_capabilities["workspace"]["configuration"], true);
    assert_eq!(
        client_capabilities["textDocument"]["completion"]["completionItem"]["snippetSupport"],
        false
    );
    assert_eq!(
        initialize_message["params"]["initializationOptions"]["ui.semanticTokens"],
        true
    );
    assert!(client_capabilities["workspace"].get("applyEdit").is_none());
    assert!(client_capabilities["textDocument"]["synchronization"]
        .get("didSave")
        .is_none());
    assert_eq!(client_capabilities["window"]["workDoneProgress"], true);

    let applied = client_apply_server_message(ClientApplyServerMessageRequest {
        state: initialized.state,
        message: r#"{
                "jsonrpc": "2.0",
                "id": "1",
                "result": {
                    "capabilities": {
                        "definitionProvider": true,
                        "hoverProvider": true,
                        "completionProvider": { "resolveProvider": true },
                        "codeActionProvider": { "resolveProvider": true }
                    }
                }
            }"#
        .to_string(),
    })
    .unwrap();

    assert!(applied.state.initialized);
    assert!(applied.state.pending_requests.is_empty());
    assert!(applied
        .state
        .server_capabilities
        .contains(&"definition".to_string()));
    assert!(applied
        .state
        .server_capabilities
        .contains(&"completionResolve".to_string()));
    assert_eq!(applied.messages.len(), 1);
    let initialized_notification: Value =
        serde_json::from_str(&applied.messages[0]).expect("initialized JSON");
    assert_eq!(initialized_notification["method"], "initialized");
}

#[test]
fn client_core_tracks_documents_and_feature_requests() {
    let opened = client_open_document(ClientOpenDocumentRequest {
        state: LspClientState::default(),
        uri: "file:///tmp/project/main.rs".to_string(),
        language_id: "rust".to_string(),
        text: "fn main() {}\n".to_string(),
    })
    .unwrap();
    assert_eq!(
        opened
            .state
            .open_documents
            .get("file:///tmp/project/main.rs")
            .unwrap()
            .version,
        1
    );
    let did_open: Value = serde_json::from_str(&opened.messages[0]).unwrap();
    assert_eq!(did_open["method"], "textDocument/didOpen");

    let changed = client_change_document(ClientChangeDocumentRequest {
        state: opened.state,
        uri: "file:///tmp/project/main.rs".to_string(),
        text: "fn main() { launch(); }\n".to_string(),
    })
    .unwrap();
    assert_eq!(
        changed
            .state
            .open_documents
            .get("file:///tmp/project/main.rs")
            .unwrap()
            .version,
        2
    );
    let did_change: Value = serde_json::from_str(&changed.messages[0]).unwrap();
    assert_eq!(did_change["method"], "textDocument/didChange");

    let requested = client_feature_request(ClientFeatureRequest {
        state: changed.state,
        uri: "file:///tmp/project/main.rs".to_string(),
        method: "textDocument/definition".to_string(),
        position: Some(LspPosition {
            line: 0,
            utf16_column: 12,
        }),
        new_name: None,
        range: None,
        diagnostics: Vec::new(),
        completion_item: None,
        code_action: None,
        command: None,
    })
    .unwrap();
    assert_eq!(
        requested.state.pending_requests.get("1").unwrap(),
        "textDocument/definition"
    );
    let request_message: Value = serde_json::from_str(&requested.messages[0]).unwrap();
    assert_eq!(request_message["method"], "textDocument/definition");
    assert_eq!(request_message["params"]["position"]["character"], 12);
}

#[test]
fn client_core_closes_open_documents() {
    let uri = "file:///tmp/project/main.go";
    let opened = client_open_document(ClientOpenDocumentRequest {
        state: LspClientState::default(),
        uri: uri.to_string(),
        language_id: "go".to_string(),
        text: "package main\n".to_string(),
    })
    .unwrap();

    let closed = client_close_document(ClientCloseDocumentRequest {
        state: opened.state,
        uri: uri.to_string(),
    })
    .unwrap();

    assert!(!closed.state.open_documents.contains_key(uri));
    assert_eq!(closed.messages.len(), 1);
    let did_close: Value = serde_json::from_str(&closed.messages[0]).unwrap();
    assert_eq!(
        did_close,
        json!({
            "jsonrpc": "2.0",
            "method": "textDocument/didClose",
            "params": {
                "textDocument": {
                    "uri": uri
                }
            }
        })
    );

    let error = client_close_document(ClientCloseDocumentRequest {
        state: closed.state,
        uri: uri.to_string(),
    })
    .unwrap_err();
    assert_eq!(serde_json::to_value(error.code).unwrap(), "invalid_request");
}

#[test]
fn client_core_waits_for_shutdown_response_before_exiting() {
    let mut state = LspClientState {
        initialized: true,
        ..LspClientState::default()
    };
    state.server_capabilities.push("completion".to_string());
    state.open_documents.insert(
        "file:///tmp/project/main.go".to_string(),
        LspClientDocument {
            uri: "file:///tmp/project/main.go".to_string(),
            language_id: "go".to_string(),
            version: 1,
            text: "package main\n".to_string(),
        },
    );

    let shutting_down = client_shutdown(ClientShutdownRequest { state }).unwrap();
    assert!(shutting_down.state.shutdown_requested);
    assert_eq!(
        shutting_down.state.pending_requests.get("1"),
        Some(&"shutdown".to_string())
    );
    let shutdown: Value = serde_json::from_str(&shutting_down.messages[0]).unwrap();
    assert_eq!(
        shutdown,
        json!({
            "jsonrpc": "2.0",
            "id": "1",
            "method": "shutdown"
        })
    );

    let exited = client_apply_server_message(ClientApplyServerMessageRequest {
        state: shutting_down.state,
        message: json!({
            "jsonrpc": "2.0",
            "id": "1",
            "result": null
        })
        .to_string(),
    })
    .unwrap();

    assert!(!exited.state.initialized);
    assert!(!exited.state.shutdown_requested);
    assert!(exited.state.pending_requests.is_empty());
    assert!(exited.state.server_capabilities.is_empty());
    assert!(exited.state.open_documents.is_empty());
    assert_eq!(exited.messages.len(), 1);
    let exit: Value = serde_json::from_str(&exited.messages[0]).unwrap();
    assert_eq!(
        exit,
        json!({
            "jsonrpc": "2.0",
            "method": "exit"
        })
    );
    assert_eq!(exited.events.len(), 1);
    assert_eq!(exited.events[0].method.as_deref(), Some("shutdown"));
}

#[test]
fn client_core_rejects_duplicate_shutdown_requests() {
    let shutting_down = client_shutdown(ClientShutdownRequest {
        state: LspClientState::default(),
    })
    .unwrap();

    let error = client_shutdown(ClientShutdownRequest {
        state: shutting_down.state,
    })
    .unwrap_err();
    assert_eq!(serde_json::to_value(error.code).unwrap(), "invalid_request");
}

#[test]
fn frame_message_uses_lsp_content_length_bytes() {
    let message = r#"{"jsonrpc":"2.0","method":"window/logMessage","params":{"message":"你好"}}"#;
    let framed = frame_message(FrameMessageRequest {
        message: message.to_string(),
    })
    .unwrap();
    assert!(framed
        .frame
        .starts_with(&format!("Content-Length: {}\r\n\r\n", message.len())));
    assert!(framed.frame.ends_with(message));
}

#[test]
fn parse_server_messages_returns_complete_messages_and_remaining_buffer() {
    let first = r#"{"jsonrpc":"2.0","id":1,"result":null}"#;
    let second = r#"{"jsonrpc":"2.0","method":"window/logMessage","params":{"message":"ok"}}"#;
    let first_frame = frame_message(FrameMessageRequest {
        message: first.to_string(),
    })
    .unwrap()
    .frame;
    let second_frame = frame_message(FrameMessageRequest {
        message: second.to_string(),
    })
    .unwrap()
    .frame;
    let split_at = first_frame.len() - 3;
    let partial = parse_server_messages(ParseServerMessagesRequest {
        buffer: Vec::new(),
        chunk: first_frame.as_bytes()[..split_at].to_vec(),
    })
    .unwrap();
    assert!(partial.messages.is_empty());
    assert_eq!(partial.buffer, first_frame.as_bytes()[..split_at]);

    let mut next_chunk = first_frame.as_bytes()[split_at..].to_vec();
    next_chunk.extend(second_frame.as_bytes());
    let parsed = parse_server_messages(ParseServerMessagesRequest {
        buffer: partial.buffer,
        chunk: next_chunk,
    })
    .unwrap();
    assert_eq!(parsed.messages, vec![first.to_string(), second.to_string()]);
    assert!(parsed.buffer.is_empty());
}

#[test]
fn client_core_shapes_feature_responses_for_swift_models() {
    let opened = client_open_document(ClientOpenDocumentRequest {
        state: LspClientState::default(),
        uri: "file:///tmp/project/main.rs".to_string(),
        language_id: "rust".to_string(),
        text: "fn main() { la }\n".to_string(),
    })
    .unwrap();
    let requested = client_feature_request(ClientFeatureRequest {
        state: opened.state,
        uri: "file:///tmp/project/main.rs".to_string(),
        method: "textDocument/completion".to_string(),
        position: Some(LspPosition {
            line: 0,
            utf16_column: 14,
        }),
        new_name: None,
        range: None,
        diagnostics: Vec::new(),
        completion_item: None,
        code_action: None,
        command: None,
    })
    .unwrap();
    let completed = client_apply_server_message(ClientApplyServerMessageRequest {
        state: requested.state,
        message: r#"{
                "jsonrpc": "2.0",
                "id": "1",
                "result": {
                    "items": [{
                        "label": "launch",
                        "kind": 3,
                        "detail": "fn()",
                        "textEdit": {
                            "range": {
                                "start": { "line": 0, "character": 12 },
                                "end": { "line": 0, "character": 14 }
                            },
                            "newText": "launch"
                        }
                    }]
                }
            }"#
        .to_string(),
    })
    .unwrap();

    let result = completed.events[0].result.as_ref().unwrap();
    assert_eq!(result["items"][0]["label"], "launch");
    assert_eq!(
        result["items"][0]["textEdit"]["range"]["start"]["utf16Column"],
        12
    );

    let rename = client_feature_request(ClientFeatureRequest {
        state: completed.state,
        uri: "file:///tmp/project/main.rs".to_string(),
        method: "textDocument/rename".to_string(),
        position: Some(LspPosition {
            line: 0,
            utf16_column: 12,
        }),
        new_name: Some("start".to_string()),
        range: None,
        diagnostics: Vec::new(),
        completion_item: None,
        code_action: None,
        command: None,
    })
    .unwrap();
    let renamed = client_apply_server_message(ClientApplyServerMessageRequest {
        state: rename.state,
        message: r#"{
                "jsonrpc": "2.0",
                "id": "2",
                "result": {
                    "changes": {
                        "file:///tmp/project/main.rs": [{
                            "range": {
                                "start": { "line": 0, "character": 12 },
                                "end": { "line": 0, "character": 18 }
                            },
                            "newText": "start"
                        }]
                    }
                }
            }"#
        .to_string(),
    })
    .unwrap();
    let rename_result = renamed.events[0].result.as_ref().unwrap();
    assert_eq!(
        rename_result["changes"]["/tmp/project/main.rs"][0]["newText"],
        "start"
    );

    let formatting = client_feature_request(ClientFeatureRequest {
        state: renamed.state,
        uri: "file:///tmp/project/main.rs".to_string(),
        method: "textDocument/formatting".to_string(),
        position: None,
        new_name: None,
        range: None,
        diagnostics: Vec::new(),
        completion_item: None,
        code_action: None,
        command: None,
    })
    .unwrap();
    let formatted = client_apply_server_message(ClientApplyServerMessageRequest {
        state: formatting.state,
        message: r#"{
                "jsonrpc": "2.0",
                "id": "3",
                "result": [{
                    "range": {
                        "start": { "line": 0, "character": 2 },
                        "end": { "line": 0, "character": 2 }
                    },
                    "newText": " "
                }]
            }"#
        .to_string(),
    })
    .unwrap();
    let format_result = formatted.events[0].result.as_ref().unwrap();
    assert_eq!(
        format_result["edits"][0]["range"]["start"]["utf16Column"],
        2
    );

    let code_actions = client_feature_request(ClientFeatureRequest {
        state: formatted.state,
        uri: "file:///tmp/project/main.rs".to_string(),
        method: "textDocument/codeAction".to_string(),
        position: None,
        new_name: None,
        range: Some(LspRange {
            start: LspPosition {
                line: 0,
                utf16_column: 0,
            },
            end: LspPosition {
                line: 0,
                utf16_column: 0,
            },
        }),
        diagnostics: vec![LspClientDiagnostic {
            range: LspRangeResponse {
                start: LspPositionResponse {
                    line: 0,
                    utf16_column: 12,
                },
                end: LspPositionResponse {
                    line: 0,
                    utf16_column: 18,
                },
            },
            severity: Some(2),
            message: "rename suggestion".to_string(),
            source: Some("rust-analyzer".to_string()),
            code: None,
        }],
        completion_item: None,
        code_action: None,
        command: None,
    })
    .unwrap();
    let code_action_request: Value = serde_json::from_str(&code_actions.messages[0]).unwrap();
    assert_eq!(code_action_request["method"], "textDocument/codeAction");
    assert_eq!(
        code_action_request["params"]["context"]["diagnostics"][0]["range"]["start"]["character"],
        12
    );
    let code_actioned = client_apply_server_message(ClientApplyServerMessageRequest {
        state: code_actions.state,
        message: r#"{
                "jsonrpc": "2.0",
                "id": "4",
                "result": [{
                    "title": "Apply rename",
                    "kind": "quickfix",
                    "isPreferred": true,
                    "edit": {
                        "changes": {
                            "file:///tmp/project/main.rs": [{
                                "range": {
                                    "start": { "line": 0, "character": 12 },
                                    "end": { "line": 0, "character": 18 }
                                },
                                "newText": "start"
                            }]
                        }
                    },
                    "command": {
                        "title": "Apply",
                        "command": "rust-analyzer.applySourceChange",
                        "arguments": [{ "label": "rename" }]
                    },
                    "data": { "id": "action-1" }
                }]
            }"#
        .to_string(),
    })
    .unwrap();
    let action_result = code_actioned.events[0].result.as_ref().unwrap();
    assert_eq!(action_result["actions"][0]["title"], "Apply rename");
    assert_eq!(
        action_result["actions"][0]["edit"]["changes"]["/tmp/project/main.rs"][0]["newText"],
        "start"
    );
    assert_eq!(
        action_result["actions"][0]["command"]["command"],
        "rust-analyzer.applySourceChange"
    );

    let code_action_resolve = client_feature_request(ClientFeatureRequest {
        state: code_actioned.state,
        uri: "file:///tmp/project/main.rs".to_string(),
        method: "codeAction/resolve".to_string(),
        position: None,
        new_name: None,
        range: None,
        diagnostics: Vec::new(),
        completion_item: None,
        code_action: Some(json!({
            "title": "Apply rename",
            "kind": "quickfix",
            "isPreferred": true,
            "data": { "id": "action-1" }
        })),
        command: None,
    })
    .unwrap();
    let code_action_resolve_request: Value =
        serde_json::from_str(&code_action_resolve.messages[0]).unwrap();
    assert_eq!(code_action_resolve_request["method"], "codeAction/resolve");
    assert_eq!(
        code_action_resolve_request["params"]["title"],
        "Apply rename"
    );
    let code_action_resolved = client_apply_server_message(ClientApplyServerMessageRequest {
        state: code_action_resolve.state,
        message: r#"{
                "jsonrpc": "2.0",
                "id": "5",
                "result": {
                    "title": "Apply rename",
                    "kind": "quickfix",
                    "edit": {
                        "changes": {
                            "file:///tmp/project/main.rs": [{
                                "range": {
                                    "start": { "line": 0, "character": 12 },
                                    "end": { "line": 0, "character": 18 }
                                },
                                "newText": "start"
                            }]
                        }
                    },
                    "data": { "id": "action-1" }
                }
            }"#
        .to_string(),
    })
    .unwrap();
    let code_action_resolve_result = code_action_resolved.events[0].result.as_ref().unwrap();
    assert_eq!(
        code_action_resolve_result["action"]["edit"]["changes"]["/tmp/project/main.rs"][0]
            ["newText"],
        "start"
    );

    let completion_resolve = client_feature_request(ClientFeatureRequest {
        state: code_action_resolved.state,
        uri: "file:///tmp/project/main.rs".to_string(),
        method: "completionItem/resolve".to_string(),
        position: None,
        new_name: None,
        range: None,
        diagnostics: Vec::new(),
        completion_item: Some(json!({
            "label": "launch",
            "insertText": "launch",
            "kind": 3,
            "textEdit": {
                "range": {
                    "start": { "line": 0, "utf16Column": 12 },
                    "end": { "line": 0, "utf16Column": 14 }
                },
                "newText": "launch"
            },
            "data": { "id": "completion-1" }
        })),
        code_action: None,
        command: None,
    })
    .unwrap();
    let completion_resolve_request: Value =
        serde_json::from_str(&completion_resolve.messages[0]).unwrap();
    assert_eq!(
        completion_resolve_request["method"],
        "completionItem/resolve"
    );
    assert_eq!(
        completion_resolve_request["params"]["textEdit"]["range"]["start"]["character"],
        12
    );
    let completion_resolved = client_apply_server_message(ClientApplyServerMessageRequest {
        state: completion_resolve.state,
        message: r#"{
                "jsonrpc": "2.0",
                "id": "6",
                "result": {
                    "label": "launch",
                    "kind": 3,
                    "detail": "fn launch()",
                    "documentation": { "kind": "markdown", "value": "Launches the app." },
                    "insertText": "launch",
                    "data": { "id": "completion-1" }
                }
            }"#
        .to_string(),
    })
    .unwrap();
    let completion_resolve_result = completion_resolved.events[0].result.as_ref().unwrap();
    assert_eq!(
        completion_resolve_result["item"]["documentation"],
        "Launches the app."
    );

    let execute_command = client_feature_request(ClientFeatureRequest {
        state: completion_resolved.state,
        uri: "file:///tmp/project/main.rs".to_string(),
        method: "workspace/executeCommand".to_string(),
        position: None,
        new_name: None,
        range: None,
        diagnostics: Vec::new(),
        completion_item: None,
        code_action: None,
        command: Some(json!({
            "title": "Apply",
            "command": "rust-analyzer.applySourceChange",
            "arguments": [{ "label": "rename" }]
        })),
    })
    .unwrap();
    let execute_request: Value = serde_json::from_str(&execute_command.messages[0]).unwrap();
    assert_eq!(execute_request["method"], "workspace/executeCommand");
    assert_eq!(
        execute_request["params"]["command"],
        "rust-analyzer.applySourceChange"
    );
    let executed = client_apply_server_message(ClientApplyServerMessageRequest {
        state: execute_command.state,
        message: r#"{
                "jsonrpc": "2.0",
                "id": "7",
                "result": null
            }"#
        .to_string(),
    })
    .unwrap();
    assert_eq!(executed.events[0].result.as_ref().unwrap()["ok"], true);
}

#[test]
fn client_core_applies_diagnostics_and_dynamic_registrations() {
    let state = LspClientState::default();
    let diagnostics = client_apply_server_message(ClientApplyServerMessageRequest {
        state,
        message: r#"{
                "jsonrpc": "2.0",
                "method": "textDocument/publishDiagnostics",
                "params": {
                    "uri": "file:///tmp/project/main.py",
                    "diagnostics": [{
                        "range": {
                            "start": { "line": 2, "character": 4 },
                            "end": { "line": 2, "character": 9 }
                        },
                        "severity": 1,
                        "source": "pyright",
                        "code": "reportGeneralTypeIssues",
                        "message": "Example diagnostic"
                    }]
                }
            }"#
        .to_string(),
    })
    .unwrap();
    let stored = diagnostics
        .state
        .diagnostics
        .get("file:///tmp/project/main.py")
        .unwrap();
    assert_eq!(stored[0].message, "Example diagnostic");
    assert_eq!(stored[0].range.start.utf16_column, 4);
    assert_eq!(diagnostics.events[0].kind, "diagnostics");

    let registered = client_apply_server_message(ClientApplyServerMessageRequest {
        state: diagnostics.state,
        message: r#"{
                "jsonrpc": "2.0",
                "id": 77,
                "method": "client/registerCapability",
                "params": {
                    "registrations": [{
                        "id": "formatting",
                        "method": "textDocument/formatting",
                        "registerOptions": {}
                    }]
                }
            }"#
        .to_string(),
    })
    .unwrap();
    assert!(registered
        .state
        .server_capabilities
        .contains(&"formatting".to_string()));
    let response: Value = serde_json::from_str(&registered.messages[0]).unwrap();
    assert_eq!(
        response,
        json!({ "jsonrpc": "2.0", "id": 77, "result": null })
    );

    let unregistered = client_apply_server_message(ClientApplyServerMessageRequest {
        state: registered.state,
        message: r#"{
                "jsonrpc": "2.0",
                "id": "unregister-1",
                "method": "client/unregisterCapability",
                "params": {
                    "unregisterations": [{
                        "id": "formatting",
                        "method": "textDocument/formatting"
                    }]
                }
            }"#
        .to_string(),
    })
    .unwrap();
    assert!(!unregistered
        .state
        .server_capabilities
        .contains(&"formatting".to_string()));
    let response: Value = serde_json::from_str(&unregistered.messages[0]).unwrap();
    assert_eq!(
        response,
        json!({ "jsonrpc": "2.0", "id": "unregister-1", "result": null })
    );
}

#[test]
fn client_core_answers_workspace_configuration_requests_by_item() {
    let response = client_apply_server_message(ClientApplyServerMessageRequest {
        state: LspClientState::default(),
        message: r#"{
                "jsonrpc": "2.0",
                "id": "configuration-1",
                "method": "workspace/configuration",
                "params": {
                    "items": [
                        { "section": "gopls" },
                        { "scopeUri": "file:///tmp/project", "section": "gopls.ui" }
                    ]
                }
            }"#
        .to_string(),
    })
    .unwrap();

    assert!(response.events.is_empty());
    assert_eq!(response.messages.len(), 1);
    let message: Value = serde_json::from_str(&response.messages[0]).unwrap();
    assert_eq!(
        message,
        json!({
            "jsonrpc": "2.0",
            "id": "configuration-1",
            "result": [null, null]
        })
    );
}

#[test]
fn client_core_answers_workspace_folder_and_progress_requests() {
    for (method, id) in [
        ("workspace/workspaceFolders", json!(42)),
        ("window/workDoneProgress/create", json!("progress-1")),
    ] {
        let response = client_apply_server_message(ClientApplyServerMessageRequest {
            state: LspClientState::default(),
            message: json!({
                "jsonrpc": "2.0",
                "id": id,
                "method": method,
                "params": {}
            })
            .to_string(),
        })
        .unwrap();

        assert!(response.events.is_empty());
        assert_eq!(response.messages.len(), 1);
        let message: Value = serde_json::from_str(&response.messages[0]).unwrap();
        assert_eq!(
            message,
            json!({ "jsonrpc": "2.0", "id": id, "result": null })
        );
    }
}

#[test]
fn client_core_rejects_unknown_server_requests_with_method_not_found() {
    let response = client_apply_server_message(ClientApplyServerMessageRequest {
        state: LspClientState::default(),
        message: r#"{
                "jsonrpc": "2.0",
                "id": 91,
                "method": "experimental/notSupported",
                "params": { "value": true }
            }"#
        .to_string(),
    })
    .unwrap();

    assert!(response.events.is_empty());
    assert_eq!(response.messages.len(), 1);
    let message: Value = serde_json::from_str(&response.messages[0]).unwrap();
    assert_eq!(
        message,
        json!({
            "jsonrpc": "2.0",
            "id": 91,
            "error": {
                "code": -32601,
                "message": "Method not found"
            }
        })
    );
}
