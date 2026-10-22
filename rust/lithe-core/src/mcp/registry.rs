//! Normalize public MCP Registry metadata without fetching or executing servers.

use super::model::{McpServer, McpTransport};
use crate::protocol::{CoreError, ErrorCode};
use serde_json::{json, Value};

/// Returns the release-owned catalog without reading files or using the network.
/// Entries pass through the same draft validation as public Registry responses.
pub fn featured_registry() -> Result<Value, CoreError> {
    let content = include_str!("featured.json");
    let catalog: Value = serde_json::from_str(content)
        .map_err(|_| CoreError::new(ErrorCode::InvalidRequest, "Invalid featured MCP catalog"))?;
    let mut page = parse_registry(json!({"content": content}))?;
    if let Some(entries) = page.get_mut("entries").and_then(Value::as_array_mut) {
        for entry in entries {
            entry["source"] = json!("featured");
            // Only the release-owned catalog may declare an incomplete template.
            // Public Registry input must still contain a complete launch recipe.
            let setup = catalog["servers"]
                .as_array()
                .and_then(|servers| {
                    servers
                        .iter()
                        .find(|item| item["server"]["name"] == entry["id"])
                })
                .and_then(|item| item.get("setup"))
                .and_then(Value::as_str);
            if let Some(setup) = setup {
                if !matches!(setup, "bearer-token" | "allowed-directories")
                    || entry["draft"].is_null()
                {
                    return Err(CoreError::new(
                        ErrorCode::InvalidRequest,
                        "Invalid featured MCP setup",
                    ));
                }
                entry["setup"] = json!(setup);
            }
        }
    }
    Ok(page)
}

/// Reads one bounded v0.1 registry page. Only simple, fully specified launch
/// recipes become drafts; complex inputs remain documentation-only entries.
pub fn parse_registry(payload: Value) -> Result<Value, CoreError> {
    let content = payload.get("content").and_then(Value::as_str).unwrap_or("");
    let invalid = || CoreError::new(ErrorCode::InvalidRequest, "Invalid MCP registry response");
    if content.len() > 1024 * 1024 {
        return Err(invalid());
    }
    let page: Value = serde_json::from_str(content).map_err(|_| invalid())?;
    let servers = page
        .get("servers")
        .and_then(Value::as_array)
        .ok_or_else(invalid)?;
    if servers.len() > 100 {
        return Err(invalid());
    }
    let mut entries = Vec::new();
    for item in servers {
        let status = item
            .pointer("/_meta/io.modelcontextprotocol.registry~1official/status")
            .and_then(Value::as_str);
        if status.is_some_and(|s| s != "active") {
            continue;
        }
        let Some(server) = item.get("server").filter(|s| s.is_object()) else {
            continue;
        };
        let Some(name) = server
            .get("name")
            .and_then(Value::as_str)
            .filter(|s| !s.is_empty() && s.len() < 256)
        else {
            continue;
        };
        let title = server.get("title").and_then(Value::as_str).unwrap_or(name);
        let mut draft_name: String = name
            .rsplit('/')
            .next()
            .unwrap_or(name)
            .chars()
            .map(|c| {
                if c.is_ascii_alphanumeric() || "._-".contains(c) {
                    c
                } else {
                    '-'
                }
            })
            .collect();
        if !draft_name.starts_with(|c: char| c.is_ascii_alphanumeric()) {
            draft_name.insert_str(0, "mcp-");
        }
        let mut draft = None;
        if let Some(remotes) = server.get("remotes").and_then(Value::as_array) {
            for remote in remotes {
                let transport = match remote.get("type").and_then(Value::as_str) {
                    Some("streamable-http") => McpTransport::Http,
                    Some("sse") => McpTransport::Sse,
                    _ => continue,
                };
                // Dynamic URLs, headers and authentication require the publisher's
                // setup instructions; never turn unresolved placeholders into a config.
                if !empty_array(remote, "headers")
                    || remote
                        .get("variables")
                        .is_some_and(|v| v.as_object().is_none_or(|o| !o.is_empty()))
                {
                    continue;
                }
                if let Some(url) = safe_url(remote.get("url")) {
                    draft = Some(McpServer::new(
                        draft_name.clone(),
                        transport,
                        None,
                        vec![],
                        vec![],
                        Some(url),
                        vec![],
                    ));
                    break;
                }
            }
        }
        if draft.is_none() {
            if let Some(packages) = server.get("packages").and_then(Value::as_array) {
                for package in packages {
                    if package.pointer("/transport/type").and_then(Value::as_str) != Some("stdio")
                        || [
                            "runtimeArguments",
                            "packageArguments",
                            "environmentVariables",
                        ]
                        .iter()
                        .any(|key| !empty_array(package, key))
                    {
                        continue;
                    }
                    let Some(id) = package.get("identifier").and_then(Value::as_str) else {
                        continue;
                    };
                    let Some(version) = package.get("version").and_then(Value::as_str) else {
                        continue;
                    };
                    // Dist-tags such as "latest" are mutable and cannot be pinned.
                    if !safe_package(id)
                        || !safe_package(version)
                        || !version.starts_with(|c: char| c.is_ascii_digit())
                    {
                        continue;
                    }
                    let (command, args, base) =
                        match package.get("registryType").and_then(Value::as_str) {
                            Some("npm") if exact_npm_version(version) => (
                                "npx",
                                vec!["-y".into(), format!("{id}@{version}")],
                                "https://registry.npmjs.org",
                            ),
                            Some("pypi") => {
                                ("uvx", vec![format!("{id}=={version}")], "https://pypi.org")
                            }
                            _ => continue,
                        };
                    // A package on another registry must not be resolved from the
                    // public default merely because its identifier looks familiar.
                    if package.get("registryBaseUrl").is_some_and(|url| {
                        safe_url(Some(url)).is_none_or(|url| url.trim_end_matches('/') != base)
                    }) {
                        continue;
                    }
                    if package
                        .get("runtimeHint")
                        .is_some_and(|hint| hint.as_str() != Some(command))
                    {
                        continue;
                    }
                    draft = Some(McpServer::new(
                        draft_name.clone(),
                        McpTransport::Stdio,
                        Some(command.into()),
                        args,
                        vec![],
                        None,
                        vec![],
                    ));
                    break;
                }
            }
        }
        entries.push(json!({"id": name, "title": title, "summary": server.get("description").and_then(Value::as_str).unwrap_or(""),
            "publisher": server.get("publisher").and_then(Value::as_str), "source": "registry",
            "version": server.get("version").and_then(Value::as_str).unwrap_or(""),
            "website": safe_url(server.get("websiteUrl")).or_else(|| safe_url(server.pointer("/repository/url"))), "draft": draft}));
    }
    let cursor = page
        .pointer("/metadata/nextCursor")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty() && s.len() <= 2048);
    Ok(json!({"entries": entries, "nextCursor": cursor}))
}

fn empty_array(value: &Value, key: &str) -> bool {
    value
        .get(key)
        .is_none_or(|v| v.as_array().is_some_and(Vec::is_empty))
}

fn safe_package(value: &str) -> bool {
    !value.is_empty()
        && value.len() < 256
        && !value.starts_with('-')
        && value
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || b"@/._-+".contains(&c))
}

fn exact_npm_version(version: &str) -> bool {
    let components: Vec<_> = version
        .split(['-', '+'])
        .next()
        .unwrap_or("")
        .split('.')
        .collect();
    components.len() == 3
        && components
            .iter()
            .all(|part| !part.is_empty() && part.bytes().all(|b| b.is_ascii_digit()))
        && version
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b".-+".contains(&b))
}

fn safe_url(value: Option<&Value>) -> Option<String> {
    let raw = value?.as_str()?;
    if raw.contains(['{', '}']) {
        return None;
    }
    let url = url::Url::parse(raw).ok()?;
    (url.scheme() == "https"
        && url.host_str().is_some()
        && url.username().is_empty()
        && url.password().is_none())
    .then(|| url.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn featured_catalog_is_available_offline_with_pinned_reviewable_drafts() {
        let page = featured_registry().unwrap();
        let entries = page["entries"].as_array().unwrap();
        assert_eq!(entries.len(), 10);
        assert!(page["nextCursor"].is_null());
        assert!(entries
            .iter()
            .all(|e| e["source"] == "featured" && e["draft"].is_object()));
        assert_eq!(entries[0]["publisher"], "Upstash");
        assert_eq!(
            entries[1]["draft"]["args"],
            json!(["-y", "@playwright/mcp@0.0.83"])
        );
        assert_eq!(
            entries[2]["draft"]["args"],
            json!(["-y", "chrome-devtools-mcp@1.11.0"])
        );
        let find = |name: &str| entries.iter().find(|e| e["draft"]["name"] == name).unwrap();
        assert_eq!(find("github")["setup"], "bearer-token");
        assert_eq!(
            find("github")["draft"]["url"],
            "https://api.githubcopilot.com/mcp/"
        );
        assert_eq!(
            find("deepwiki")["draft"]["url"],
            "https://mcp.deepwiki.com/mcp"
        );
        assert_eq!(find("exa")["draft"]["url"], "https://mcp.exa.ai/mcp");
        assert_eq!(find("filesystem")["setup"], "allowed-directories");
        assert_eq!(
            find("filesystem")["draft"]["args"],
            json!(["-y", "@modelcontextprotocol/server-filesystem@2.0.0"])
        );
        assert_eq!(
            find("memory")["draft"]["args"],
            json!(["-y", "@modelcontextprotocol/server-memory@2.0.0"])
        );
        assert_eq!(
            find("fetch")["draft"]["args"],
            json!(["mcp-server-fetch==2026.10.19"])
        );
    }

    #[test]
    fn public_registry_cannot_declare_trusted_featured_setup() {
        let page = parse_registry(json!({"content": json!({"servers": [{
            "setup": "bearer-token", "server": {"name": "lithe.featured/github",
                "setup": "bearer-token", "remotes": [{"type": "streamable-http", "url": "https://example.invalid/mcp"}]}
        }]}).to_string()})).unwrap();
        assert_eq!(page["entries"][0]["source"], "registry");
        assert!(page["entries"][0].get("setup").is_none());
    }

    #[test]
    fn registry_page_keeps_versions_cursor_and_only_complete_drafts() {
        let content = include_str!("../../../../shared/contracts/mcp-registry-page.json");
        let page = parse_registry(json!({"content": content})).unwrap();
        assert_eq!(page["entries"].as_array().unwrap().len(), 3);
        assert_eq!(page["nextCursor"], "opaque/+ cursor?");
        assert_eq!(page["entries"][0]["draft"]["transport"], "http");
        assert_eq!(
            page["entries"][1]["draft"]["args"],
            json!(["-y", "@example/browser@2.0.0"])
        );
        assert!(page["entries"][2]["draft"].is_null());
    }

    #[test]
    fn untrusted_links_dynamic_urls_and_package_options_are_not_launch_recipes() {
        for url in [
            "javascript:alert(1)",
            "https://user:secret@example.invalid/mcp",
            "https://example.invalid/{tenant}",
        ] {
            let page = parse_registry(json!({"content": json!({"servers": [{"server": {
                "name": "io.example/untrusted", "websiteUrl": url,
                "remotes": [{"type": "streamable-http", "url": url}],
                "packages": [{"registryType":"npm", "identifier":"--eval", "version":"1", "transport":{"type":"stdio"}}]
            }}]}).to_string()})).unwrap();
            assert!(page["entries"][0]["draft"].is_null());
            assert!(page["entries"][0]["website"].is_null());
        }
        for (version, hint, base) in [
            ("latest", "npx", "https://registry.npmjs.org"),
            ("1", "npx", "https://registry.npmjs.org"),
            ("1.0.0", "node", "https://registry.npmjs.org"),
            ("1.0.0", "npx", "https://example.invalid/npm"),
        ] {
            let page = parse_registry(json!({"content": json!({"servers": [{"server": {
                "name": "io.example/needs-setup",
                "packages": [{"registryType":"npm", "identifier":"example", "version":version,
                    "runtimeHint":hint, "registryBaseUrl":base, "transport":{"type":"stdio"}}]
            }}]}).to_string()}))
            .unwrap();
            assert!(page["entries"][0]["draft"].is_null());
        }
    }

    #[test]
    fn malformed_and_oversized_pages_fail_without_echoing_contents() {
        for content in [
            "secret invalid json".to_string(),
            "x".repeat(1024 * 1024 + 1),
            "{}".to_string(),
        ] {
            let error = parse_registry(json!({"content": content})).unwrap_err();
            assert!(!error.message.contains("secret"));
        }
    }
}
