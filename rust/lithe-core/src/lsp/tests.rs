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
    let rust = catalog
        .providers
        .iter()
        .find(|provider| provider.id == "rust")
        .expect("rust provider should exist");
    assert_eq!(
        rust.language_server_launch
            .as_ref()
            .expect("rust launch descriptor should exist")
            .validation_arguments,
        vec!["--version".to_string()]
    );
}

#[test]
fn project_config_extends_and_overrides_builtin_catalog() {
    let root = temporary_root("project-config");
    fs::create_dir_all(root.join(".lithe").join("lsp")).unwrap();
    fs::write(
        root.join(".lithe")
            .join("lsp")
            .join("language-providers.json"),
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
    assert_eq!(catalog.origin, LspProviderCatalogOrigin::WorkspaceOverride);
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
    assert_eq!(value["origin"], "builtin");
    assert!(value["providers"].as_array().unwrap().len() > 10);
    assert!(value.get("ok").is_none());
    assert!(value.get("command").is_none());
}

#[test]
fn project_catalog_reports_unknown_configuration_fields() {
    let root = temporary_root("project-config-unknown-field");
    fs::create_dir_all(root.join(".lithe").join("lsp")).unwrap();
    fs::write(
        root.join(".lithe")
            .join("lsp")
            .join("language-providers.json"),
        r#"{
              "version": 2,
              "providers": [{ "id": "go", "languageServerLanch": {} }]
            }"#,
    )
    .unwrap();

    let catalog = provider_catalog(Some(&root));
    assert_eq!(catalog.origin, LspProviderCatalogOrigin::Builtin);
    assert_eq!(catalog.diagnostics.len(), 1);
    assert!(catalog.diagnostics[0].message.contains("unknown field"));
    assert!(catalog.providers.iter().any(|provider| provider.id == "go"));

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn malformed_project_catalog_is_rejected_with_a_visible_diagnostic() {
    let root = temporary_root("project-config-malformed");
    let config_path = root
        .join(".lithe")
        .join("lsp")
        .join("language-providers.json");
    fs::create_dir_all(config_path.parent().unwrap()).unwrap();
    fs::write(&config_path, r#"{"version":2,"providers":["#).unwrap();

    let catalog = provider_catalog(Some(&root));

    assert_eq!(catalog.origin, LspProviderCatalogOrigin::Builtin);
    assert!(catalog.providers.iter().any(|provider| provider.id == "go"));
    assert_eq!(catalog.diagnostics.len(), 1);
    assert_eq!(
        catalog.diagnostics[0].path,
        config_path.display().to_string()
    );
    assert!(catalog.diagnostics[0].message.contains("EOF"));

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
    assert_eq!(
        file_path_from_uri("file://server/share/Main.java"),
        "//server/share/Main.java"
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
    assert_eq!(initialize_message["params"]["clientInfo"]["name"], "Lithe");
    assert_eq!(
        initialize_message["params"]["clientInfo"]["version"],
        env!("CARGO_PKG_VERSION")
    );
    assert_eq!(
        initialize_message["params"]["workspaceFolders"],
        json!([{
            "uri": "file:///tmp/project",
            "name": "project"
        }])
    );
    let client_capabilities = &initialize_message["params"]["capabilities"];
    assert_eq!(client_capabilities["workspace"]["configuration"], true);
    assert_eq!(client_capabilities["workspace"]["applyEdit"], true);
    assert_eq!(client_capabilities["workspace"]["workspaceFolders"], true);
    assert_eq!(
        client_capabilities["workspace"]["symbol"]["dynamicRegistration"],
        true
    );
    assert_eq!(
        client_capabilities["textDocument"]["completion"]["completionItem"]["snippetSupport"],
        true
    );
    assert_eq!(
        client_capabilities["textDocument"]["completion"]["completionItem"]["resolveSupport"]
            ["properties"],
        json!(["detail", "documentation", "textEdit", "additionalTextEdits"])
    );
    assert_eq!(
        initialize_message["params"]["initializationOptions"]["ui.semanticTokens"],
        true
    );
    assert_eq!(
        client_capabilities["textDocument"]["inlayHint"]["dynamicRegistration"],
        true
    );
    assert_eq!(
        client_capabilities["textDocument"]["foldingRange"]["dynamicRegistration"],
        true
    );
    assert_eq!(
        client_capabilities["textDocument"]["codeLens"]["dynamicRegistration"],
        true
    );
    assert!(client_capabilities["textDocument"]["synchronization"]
        .get("didSave")
        .is_none());
    assert_eq!(
        client_capabilities["textDocument"]["publishDiagnostics"]["relatedInformation"],
        true
    );
    assert_eq!(
        client_capabilities["textDocument"]["publishDiagnostics"]["versionSupport"],
        true
    );
    assert_eq!(
        client_capabilities["textDocument"]["publishDiagnostics"]["tagSupport"]["valueSet"],
        json!([1, 2])
    );
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
                        "codeActionProvider": { "resolveProvider": true },
                        "inlayHintProvider": true,
                        "foldingRangeProvider": {},
                        "codeLensProvider": { "resolveProvider": false },
                        "workspaceSymbolProvider": true
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
    for feature in [
        "inlayHints",
        "foldingRanges",
        "codeLens",
        "workspaceSymbols",
    ] {
        assert!(applied
            .state
            .server_capabilities
            .contains(&feature.to_string()));
    }
    assert_eq!(applied.messages.len(), 1);
    let initialized_notification: Value =
        serde_json::from_str(&applied.messages[0]).expect("initialized JSON");
    assert_eq!(initialized_notification["method"], "initialized");
}

#[test]
fn client_core_does_not_initialize_without_valid_capabilities() {
    for message in [
        r#"{"jsonrpc":"2.0","id":"1","result":null}"#,
        r#"{"jsonrpc":"2.0","id":"1","result":{}}"#,
        r#"{"jsonrpc":"2.0","id":"1","error":{"code":-32603,"message":"rejected"}}"#,
    ] {
        let initialized = client_initialize(ClientInitializeRequest {
            state: LspClientState::default(),
            root_uri: "file:///tmp/project".to_string(),
            process_id: None,
            initialization_options: None,
        })
        .unwrap();
        let applied = client_apply_server_message(ClientApplyServerMessageRequest {
            state: initialized.state,
            message: message.to_string(),
        })
        .unwrap();

        assert!(!applied.state.initialized);
        assert!(applied.messages.is_empty());
        assert!(applied.state.server_capabilities.is_empty());
    }
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
        content_changes: Vec::new(),
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
fn client_change_document_emits_incremental_ranges_when_the_server_supports_them() {
    let opened = client_open_document(ClientOpenDocumentRequest {
        state: LspClientState::default(),
        uri: "file:///tmp/project/main.rs".to_string(),
        language_id: "rust".to_string(),
        text: "fn main() {}\n".to_string(),
    })
    .unwrap();
    let mut state = opened.state;
    state.text_document_sync = LspTextDocumentSyncKind::Incremental;
    let changed = client_change_document(ClientChangeDocumentRequest {
        state,
        uri: "file:///tmp/project/main.rs".to_string(),
        text: String::new(),
        content_changes: vec![LspDocumentContentChange {
            range: Some(LspRange {
                start: LspPosition {
                    line: 0,
                    utf16_column: 8,
                },
                end: LspPosition {
                    line: 0,
                    utf16_column: 8,
                },
            }),
            text: "launch".to_string(),
        }],
    })
    .unwrap();
    assert_eq!(
        changed
            .state
            .open_documents
            .get("file:///tmp/project/main.rs")
            .unwrap()
            .text,
        "fn main(launch) {}\n"
    );
    let did_change: Value = serde_json::from_str(&changed.messages[0]).unwrap();
    assert_eq!(did_change["method"], "textDocument/didChange");
    assert_eq!(did_change["params"]["contentChanges"][0]["text"], "launch");
    assert_eq!(
        did_change["params"]["contentChanges"][0]["range"]["start"]["character"],
        8
    );
}

#[test]
fn client_change_document_replays_multi_change_batches_end_to_start() {
    // Pre-event document. Both Monaco ranges are relative to this text:
    // insert "X" at column 1, and insert a newline at column 3 (between "c" and "d").
    // Sequential LSP apply in original left-to-right order would shift the
    // second range and diverge; end-to-start order keeps Core and wire aligned.
    let opened = client_open_document(ClientOpenDocumentRequest {
        state: LspClientState::default(),
        uri: "file:///tmp/project/multi.rs".to_string(),
        language_id: "rust".to_string(),
        text: "abcd".to_string(),
    })
    .unwrap();
    let mut state = opened.state;
    state.text_document_sync = LspTextDocumentSyncKind::Incremental;
    let changed = client_change_document(ClientChangeDocumentRequest {
        state,
        uri: "file:///tmp/project/multi.rs".to_string(),
        text: String::new(),
        content_changes: vec![
            LspDocumentContentChange {
                range: Some(LspRange {
                    start: LspPosition {
                        line: 0,
                        utf16_column: 1,
                    },
                    end: LspPosition {
                        line: 0,
                        utf16_column: 1,
                    },
                }),
                text: "X".to_string(),
            },
            LspDocumentContentChange {
                range: Some(LspRange {
                    start: LspPosition {
                        line: 0,
                        utf16_column: 3,
                    },
                    end: LspPosition {
                        line: 0,
                        utf16_column: 3,
                    },
                }),
                text: "\n".to_string(),
            },
        ],
    })
    .unwrap();

    let document = changed
        .state
        .open_documents
        .get("file:///tmp/project/multi.rs")
        .unwrap();
    assert_eq!(document.text, "aXbc\nd");

    let did_change: Value = serde_json::from_str(&changed.messages[0]).unwrap();
    let content_changes = did_change["params"]["contentChanges"].as_array().unwrap();
    assert_eq!(content_changes.len(), 2);
    // Wire order must be end-to-start so sequential replay matches document.text.
    assert_eq!(content_changes[0]["text"], "\n");
    assert_eq!(content_changes[0]["range"]["start"]["character"], 3);
    assert_eq!(content_changes[1]["text"], "X");
    assert_eq!(content_changes[1]["range"]["start"]["character"], 1);

    let replayed = apply_content_changes_sequential(
        "abcd",
        &[
            LspDocumentContentChange {
                range: Some(LspRange {
                    start: LspPosition {
                        line: 0,
                        utf16_column: 3,
                    },
                    end: LspPosition {
                        line: 0,
                        utf16_column: 3,
                    },
                }),
                text: "\n".to_string(),
            },
            LspDocumentContentChange {
                range: Some(LspRange {
                    start: LspPosition {
                        line: 0,
                        utf16_column: 1,
                    },
                    end: LspPosition {
                        line: 0,
                        utf16_column: 1,
                    },
                }),
                text: "X".to_string(),
            },
        ],
    )
    .unwrap();
    assert_eq!(replayed, document.text);

    // Left-to-right sequential apply of the original Monaco order diverges,
    // which is exactly the bug the end-to-start wire order prevents.
    let diverged = apply_content_changes_sequential(
        "abcd",
        &[
            LspDocumentContentChange {
                range: Some(LspRange {
                    start: LspPosition {
                        line: 0,
                        utf16_column: 1,
                    },
                    end: LspPosition {
                        line: 0,
                        utf16_column: 1,
                    },
                }),
                text: "X".to_string(),
            },
            LspDocumentContentChange {
                range: Some(LspRange {
                    start: LspPosition {
                        line: 0,
                        utf16_column: 3,
                    },
                    end: LspPosition {
                        line: 0,
                        utf16_column: 3,
                    },
                }),
                text: "\n".to_string(),
            },
        ],
    )
    .unwrap();
    assert_ne!(diverged, document.text);
}

#[test]
fn client_change_document_falls_back_to_full_sync_for_overlapping_ranges() {
    let opened = client_open_document(ClientOpenDocumentRequest {
        state: LspClientState::default(),
        uri: "file:///tmp/project/overlap.rs".to_string(),
        language_id: "rust".to_string(),
        text: "abcdef".to_string(),
    })
    .unwrap();
    let mut state = opened.state;
    state.text_document_sync = LspTextDocumentSyncKind::Incremental;
    let changed = client_change_document(ClientChangeDocumentRequest {
        state,
        uri: "file:///tmp/project/overlap.rs".to_string(),
        text: "Z".to_string(),
        content_changes: vec![
            LspDocumentContentChange {
                range: Some(LspRange {
                    start: LspPosition {
                        line: 0,
                        utf16_column: 0,
                    },
                    end: LspPosition {
                        line: 0,
                        utf16_column: 3,
                    },
                }),
                text: "AA".to_string(),
            },
            LspDocumentContentChange {
                range: Some(LspRange {
                    start: LspPosition {
                        line: 0,
                        utf16_column: 2,
                    },
                    end: LspPosition {
                        line: 0,
                        utf16_column: 5,
                    },
                }),
                text: "BB".to_string(),
            },
        ],
    })
    .unwrap();

    assert_eq!(
        changed
            .state
            .open_documents
            .get("file:///tmp/project/overlap.rs")
            .unwrap()
            .text,
        "Z"
    );
    let did_change: Value = serde_json::from_str(&changed.messages[0]).unwrap();
    assert_eq!(
        did_change["params"]["contentChanges"],
        json!([{ "text": "Z" }])
    );
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
    let diagnosed = client_apply_server_message(ClientApplyServerMessageRequest {
        state: opened.state,
        message: json!({
            "jsonrpc": "2.0",
            "method": "textDocument/publishDiagnostics",
            "params": {
                "uri": uri,
                "version": 1,
                "diagnostics": [{
                    "range": {
                        "start": { "line": 0, "character": 0 },
                        "end": { "line": 0, "character": 7 }
                    },
                    "message": "Example diagnostic"
                }]
            }
        })
        .to_string(),
    })
    .unwrap();
    assert!(diagnosed.state.diagnostics.contains_key(uri));
    assert_eq!(diagnosed.state.diagnostic_versions.get(uri), Some(&1));

    let closed = client_close_document(ClientCloseDocumentRequest {
        state: diagnosed.state,
        uri: uri.to_string(),
    })
    .unwrap();

    assert!(!closed.state.open_documents.contains_key(uri));
    assert!(!closed.state.diagnostics.contains_key(uri));
    assert!(!closed.state.diagnostic_versions.contains_key(uri));
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
fn client_core_ignores_diagnostics_for_unopened_or_stale_document_versions() {
    let uri = "file:///tmp/project/main.rs";
    let unopened = client_apply_server_message(ClientApplyServerMessageRequest {
        state: LspClientState::default(),
        message: json!({
            "jsonrpc": "2.0",
            "method": "textDocument/publishDiagnostics",
            "params": {
                "uri": uri,
                "version": 1,
                "diagnostics": []
            }
        })
        .to_string(),
    })
    .unwrap();
    assert!(unopened.events.is_empty());
    assert!(!unopened.state.diagnostics.contains_key(uri));

    let opened = client_open_document(ClientOpenDocumentRequest {
        state: unopened.state,
        uri: uri.to_string(),
        language_id: "rust".to_string(),
        text: "fn main() {}\n".to_string(),
    })
    .unwrap();
    let changed = client_change_document(ClientChangeDocumentRequest {
        state: opened.state,
        uri: uri.to_string(),
        text: "fn main() { launch(); }\n".to_string(),
        content_changes: Vec::new(),
    })
    .unwrap();

    for stale_version in [1, 3] {
        let stale = client_apply_server_message(ClientApplyServerMessageRequest {
            state: changed.state.clone(),
            message: json!({
                "jsonrpc": "2.0",
                "method": "textDocument/publishDiagnostics",
                "params": {
                    "uri": uri,
                    "version": stale_version,
                    "diagnostics": [{
                        "range": {
                            "start": { "line": 0, "character": 0 },
                            "end": { "line": 0, "character": 2 }
                        },
                        "message": "Stale diagnostic"
                    }]
                }
            })
            .to_string(),
        })
        .unwrap();
        assert!(stale.events.is_empty());
        assert!(!stale.state.diagnostics.contains_key(uri));
    }

    let current = client_apply_server_message(ClientApplyServerMessageRequest {
        state: changed.state,
        message: json!({
            "jsonrpc": "2.0",
            "method": "textDocument/publishDiagnostics",
            "params": {
                "uri": uri,
                "version": 2,
                "diagnostics": [{
                    "range": {
                        "start": { "line": 0, "character": 0 },
                        "end": { "line": 0, "character": 2 }
                    },
                    "message": "Current diagnostic"
                }]
            }
        })
        .to_string(),
    })
    .unwrap();
    assert_eq!(current.events.len(), 1);
    assert_eq!(current.events[0].version, Some(2));
    assert_eq!(current.state.diagnostic_versions.get(uri), Some(&2));

    let stale_after_current = client_apply_server_message(ClientApplyServerMessageRequest {
        state: current.state,
        message: json!({
            "jsonrpc": "2.0",
            "method": "textDocument/publishDiagnostics",
            "params": {
                "uri": uri,
                "version": 1,
                "diagnostics": []
            }
        })
        .to_string(),
    })
    .unwrap();
    assert!(stale_after_current.events.is_empty());
    assert_eq!(
        stale_after_current.state.diagnostics[uri][0].message,
        "Current diagnostic"
    );
    assert_eq!(
        stale_after_current.state.diagnostic_versions.get(uri),
        Some(&2)
    );

    let unversioned = client_apply_server_message(ClientApplyServerMessageRequest {
        state: stale_after_current.state,
        message: json!({
            "jsonrpc": "2.0",
            "method": "textDocument/publishDiagnostics",
            "params": {
                "uri": uri,
                "diagnostics": []
            }
        })
        .to_string(),
    })
    .unwrap();
    assert_eq!(unversioned.events.len(), 1);
    assert_eq!(unversioned.events[0].version, None);
    assert!(!unversioned.state.diagnostic_versions.contains_key(uri));
    assert!(serde_json::to_value(&unversioned.events[0])
        .unwrap()
        .get("version")
        .is_none());
}

#[test]
fn client_state_keeps_legacy_diagnostics_shape_compatible() {
    let uri = "file:///tmp/project/main.rs";
    let state: LspClientState = serde_json::from_value(json!({
        "diagnostics": {
            uri: []
        }
    }))
    .unwrap();

    assert!(state.diagnostics.contains_key(uri));
    assert!(state.diagnostic_versions.is_empty());
    let serialized = serde_json::to_value(state).unwrap();
    assert!(serialized["diagnostics"][uri].is_array());
    assert!(serialized.get("diagnosticVersions").is_none());
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
            tags: vec![1, 99],
            related_information: vec![LspClientDiagnosticRelatedInformation {
                location: LspClientDiagnosticLocation {
                    uri: "file:///tmp/project/lib.rs".to_string(),
                    range: LspRangeResponse {
                        start: LspPositionResponse {
                            line: 3,
                            utf16_column: 4,
                        },
                        end: LspPositionResponse {
                            line: 3,
                            utf16_column: 8,
                        },
                    },
                },
                message: "declared here".to_string(),
            }],
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
    assert_eq!(
        code_action_request["params"]["context"]["diagnostics"][0]["tags"],
        json!([1, 99])
    );
    assert_eq!(
        code_action_request["params"]["context"]["diagnostics"][0]["relatedInformation"][0]
            ["location"]["uri"],
        "file:///tmp/project/lib.rs"
    );
    assert_eq!(
        code_action_request["params"]["context"]["diagnostics"][0]["relatedInformation"][0]
            ["location"]["range"]["start"]["character"],
        4
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
fn client_core_requests_and_shapes_inlay_hints_folding_ranges_and_code_lenses() {
    let uri = "file:///tmp/project/Main.java";
    let opened = client_open_document(ClientOpenDocumentRequest {
        state: LspClientState::default(),
        uri: uri.to_string(),
        language_id: "java".to_string(),
        text: "class Main {}\n".to_string(),
    })
    .unwrap();

    let inlay_request = client_feature_request(ClientFeatureRequest {
        state: opened.state,
        uri: uri.to_string(),
        method: "textDocument/inlayHint".to_string(),
        position: None,
        new_name: None,
        range: Some(LspRange {
            start: LspPosition {
                line: 0,
                utf16_column: 0,
            },
            end: LspPosition {
                line: 20,
                utf16_column: 0,
            },
        }),
        diagnostics: Vec::new(),
        completion_item: None,
        code_action: None,
        command: None,
    })
    .unwrap();
    let request_json: Value = serde_json::from_str(&inlay_request.messages[0]).unwrap();
    assert_eq!(request_json["method"], "textDocument/inlayHint");
    assert_eq!(request_json["params"]["range"]["end"]["line"], 20);

    let inlay_response = client_apply_server_message(ClientApplyServerMessageRequest {
        state: inlay_request.state,
        message: json!({
            "jsonrpc": "2.0",
            "id": "1",
            "result": [{
                "position": { "line": 4, "character": 12 },
                "label": [{ "value": "parameter" }, { "value": ":" }],
                "kind": 2,
                "tooltip": { "kind": "markdown", "value": "Parameter name" },
                "paddingLeft": true,
                "paddingRight": false,
                "textEdits": [{
                    "range": {
                        "start": { "line": 4, "character": 12 },
                        "end": { "line": 4, "character": 12 }
                    },
                    "newText": "parameter: "
                }],
                "data": { "id": "hint-1" }
            }]
        })
        .to_string(),
    })
    .unwrap();
    let hint = &inlay_response.events[0].result.as_ref().unwrap()["hints"][0];
    assert_eq!(hint["position"]["utf16Column"], 12);
    assert_eq!(hint["label"], "parameter:");
    assert_eq!(hint["kind"], 2);
    assert_eq!(hint["tooltip"], "Parameter name");
    assert_eq!(hint["paddingLeft"], true);
    assert_eq!(hint["textEdits"][0]["range"]["start"]["utf16Column"], 12);
    assert_eq!(hint["data"]["id"], "hint-1");

    let folding_request = client_feature_request(ClientFeatureRequest {
        state: inlay_response.state,
        uri: uri.to_string(),
        method: "textDocument/foldingRange".to_string(),
        position: None,
        new_name: None,
        range: None,
        diagnostics: Vec::new(),
        completion_item: None,
        code_action: None,
        command: None,
    })
    .unwrap();
    let request_json: Value = serde_json::from_str(&folding_request.messages[0]).unwrap();
    assert_eq!(request_json["method"], "textDocument/foldingRange");
    assert_eq!(request_json["params"]["textDocument"]["uri"], uri);
    let folding_response = client_apply_server_message(ClientApplyServerMessageRequest {
        state: folding_request.state,
        message: json!({
            "jsonrpc": "2.0",
            "id": "2",
            "result": [{
                "startLine": 2,
                "startCharacter": 4,
                "endLine": 8,
                "endCharacter": 1,
                "kind": "region",
                "collapsedText": "methods"
            }]
        })
        .to_string(),
    })
    .unwrap();
    let range = &folding_response.events[0].result.as_ref().unwrap()["ranges"][0];
    assert_eq!(range["startLine"], 2);
    assert_eq!(range["startUtf16Column"], 4);
    assert_eq!(range["endLine"], 8);
    assert_eq!(range["endUtf16Column"], 1);
    assert_eq!(range["kind"], "region");
    assert_eq!(range["collapsedText"], "methods");

    let code_lens_request = client_feature_request(ClientFeatureRequest {
        state: folding_response.state,
        uri: uri.to_string(),
        method: "textDocument/codeLens".to_string(),
        position: None,
        new_name: None,
        range: None,
        diagnostics: Vec::new(),
        completion_item: None,
        code_action: None,
        command: None,
    })
    .unwrap();
    let code_lens_response = client_apply_server_message(ClientApplyServerMessageRequest {
        state: code_lens_request.state,
        message: json!({
            "jsonrpc": "2.0",
            "id": "3",
            "result": [{
                "range": {
                    "start": { "line": 3, "character": 2 },
                    "end": { "line": 3, "character": 7 }
                },
                "command": {
                    "title": "Run test",
                    "command": "java.test.run",
                    "arguments": [{ "test": "MainTest" }]
                },
                "data": { "id": "lens-1" }
            }]
        })
        .to_string(),
    })
    .unwrap();
    let lens = &code_lens_response.events[0].result.as_ref().unwrap()["lenses"][0];
    assert_eq!(lens["range"]["start"]["utf16Column"], 2);
    assert_eq!(lens["command"]["command"], "java.test.run");
    assert_eq!(lens["command"]["arguments"][0]["test"], "MainTest");
    assert_eq!(lens["data"]["id"], "lens-1");
}

#[test]
fn navigation_locations_preserve_uris_without_fabricating_virtual_file_paths() {
    let uri = "file:///tmp/project/Main.java";
    let opened = client_open_document(ClientOpenDocumentRequest {
        state: LspClientState::default(),
        uri: uri.to_string(),
        language_id: "java".to_string(),
        text: "class Main {}\n".to_string(),
    })
    .unwrap();
    let requested = client_feature_request(ClientFeatureRequest {
        state: opened.state,
        uri: uri.to_string(),
        method: "textDocument/definition".to_string(),
        position: Some(LspPosition {
            line: 0,
            utf16_column: 6,
        }),
        new_name: None,
        range: None,
        diagnostics: Vec::new(),
        completion_item: None,
        code_action: None,
        command: None,
    })
    .unwrap();
    let response = client_apply_server_message(ClientApplyServerMessageRequest {
        state: requested.state,
        message: json!({
            "jsonrpc": "2.0",
            "id": "1",
            "result": [{
                "uri": "file:///tmp/project/Main%20File.java",
                "range": {
                    "start": { "line": 1, "character": 2 },
                    "end": { "line": 1, "character": 6 }
                }
            }, {
                "uri": "jdt://contents/java.base/java/lang/String.class",
                "range": {
                    "start": { "line": 10, "character": 4 },
                    "end": { "line": 10, "character": 10 }
                }
            }]
        })
        .to_string(),
    })
    .unwrap();
    let locations = &response.events[0].result.as_ref().unwrap()["locations"];

    assert_eq!(locations[0]["uri"], "file:///tmp/project/Main%20File.java");
    assert_eq!(locations[0]["filePath"], "/tmp/project/Main File.java");
    assert_eq!(locations[0]["isReadOnly"], false);
    assert_eq!(
        locations[1]["uri"],
        "jdt://contents/java.base/java/lang/String.class"
    );
    assert!(locations[1]["filePath"].is_null());
    assert_eq!(locations[1]["isReadOnly"], true);
    assert!(locations[1]["displayPath"].is_null());
}

#[test]
fn client_core_applies_diagnostics_and_dynamic_registrations() {
    let opened = client_open_document(ClientOpenDocumentRequest {
        state: LspClientState::default(),
        uri: "file:///tmp/project/main.py".to_string(),
        language_id: "python".to_string(),
        text: "example = value\n".to_string(),
    })
    .unwrap();
    let diagnostics = client_apply_server_message(ClientApplyServerMessageRequest {
        state: opened.state,
        message: r#"{
                "jsonrpc": "2.0",
                "method": "textDocument/publishDiagnostics",
                "params": {
                    "uri": "file:///tmp/project/main.py",
                    "version": 1,
                    "diagnostics": [{
                        "range": {
                            "start": { "line": 2, "character": 4 },
                            "end": { "line": 2, "character": 9 }
                        },
                        "source": "pyright",
                        "code": "reportGeneralTypeIssues",
                        "message": "Example diagnostic",
                        "tags": [1, 2, 99],
                        "relatedInformation": [{
                            "location": {
                                "uri": "file:///tmp/project/types.py",
                                "range": {
                                    "start": { "line": 8, "character": 2 },
                                    "end": { "line": 8, "character": 7 }
                                }
                            },
                            "message": "Type declared here"
                        }]
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
    assert_eq!(stored[0].severity, None);
    assert_eq!(stored[0].tags, vec![1, 2, 99]);
    assert_eq!(stored[0].related_information.len(), 1);
    assert_eq!(
        stored[0].related_information[0].location.uri,
        "file:///tmp/project/types.py"
    );
    assert_eq!(
        stored[0].related_information[0]
            .location
            .range
            .start
            .utf16_column,
        2
    );
    assert_eq!(
        stored[0].related_information[0].message,
        "Type declared here"
    );
    assert_eq!(diagnostics.events[0].kind, "diagnostics");
    assert_eq!(diagnostics.events[0].version, Some(1));
    assert_eq!(
        diagnostics
            .state
            .diagnostic_versions
            .get("file:///tmp/project/main.py"),
        Some(&1)
    );
    let event_json = serde_json::to_value(&diagnostics.events[0]).unwrap();
    assert_eq!(event_json["version"], 1);
    assert_eq!(event_json["diagnostics"][0]["tags"], json!([1, 2, 99]));
    assert_eq!(
        event_json["diagnostics"][0]["relatedInformation"][0]["location"]["range"]["start"]
            ["utf16Column"],
        2
    );

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
                    }, {
                        "id": "inlay-hints",
                        "method": "textDocument/inlayHint",
                        "registerOptions": {}
                    }, {
                        "id": "folding-ranges",
                        "method": "textDocument/foldingRange",
                        "registerOptions": {}
                    }, {
                        "id": "code-lens",
                        "method": "textDocument/codeLens",
                        "registerOptions": {}
                    }, {
                        "id": "workspace-symbols",
                        "method": "workspace/symbol",
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
    for feature in [
        "inlayHints",
        "foldingRanges",
        "codeLens",
        "workspaceSymbols",
    ] {
        assert!(registered
            .state
            .server_capabilities
            .contains(&feature.to_string()));
    }
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
                    }, {
                        "id": "inlay-hints",
                        "method": "textDocument/inlayHint"
                    }, {
                        "id": "folding-ranges",
                        "method": "textDocument/foldingRange"
                    }, {
                        "id": "code-lens",
                        "method": "textDocument/codeLens"
                    }, {
                        "id": "workspace-symbols",
                        "method": "workspace/symbol"
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
    for feature in [
        "inlayHints",
        "foldingRanges",
        "codeLens",
        "workspaceSymbols",
    ] {
        assert!(!unregistered
            .state
            .server_capabilities
            .contains(&feature.to_string()));
    }
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
